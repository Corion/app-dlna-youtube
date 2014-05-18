package AnyEvent::DLNAServer::MediaServer;
use strict;
#use AnyEvent;
# Will serve media over HTTP to anyone who asks
use Plack;
use Plack::Request; # we do raw PSGI here :-/
use Twiggy::Server;

use Digest::SHA qw(sha256_hex);
# Also, that API is deprecated. Will have to switch to a scraper then...
use Carp qw(croak);
use Data::Dumper;
use URI;
use URI::file;
use AnyEvent::HTTP;

use vars '$stream_from_disk_rate';
$stream_from_disk_rate= 1024*1024*10; # stream 10 MB/s per stream from disk

sub fetch_info {
    my( $class, $url )= @_;
    #my $yt= WebService::GData::YouTube->new();
    #(my $id)= $url=~m!([^/]+)$!;
    #croak "No YouTube id found in '$url'" unless $id;
    #return $yt->get_video_by_id($id);
    return {}
};

sub new {
    my( $class, %options )= @_;
    my $self = {
        %options
    };
    $self->{ proxy_urls }||= {};
    
    my $self_c= $self;
    $self->{httpd} ||= Twiggy::Server->new(
        server_ready => sub {
            my( $args )= @_;
            warn "Server ready at http://$args->{host}:$args->{port}/";
            $self_c->{$_} = $args->{ $_ }
                for qw(host port);
            undef $self_c;
        },
    );

    bless $self => $class;
    
    $self->httpd->register_service( $self->as_psgi );

    $self
};

sub httpd { $_[0]->{httpd} };
sub as_psgi {
    my( $self )= @_;
    sub {
        my $env = shift; # PSGI env
        my $req = Plack::Request->new($env);
        
        die "Can't stream: " . Dumper $env
            unless $env->{'psgi.streaming'};
        $self->handle_request( $req );
    };
};

sub handle_request {
    my( $self, $req )= @_;
    my $path= $req->path_info;
    
    warn sprintf "Request for '%s'", $req->uri;
    if( $path =~ m!/media\b! ) {
        return $self->serve_media( $req );
    };
    return
        [ 500, [], ["Internal Server Error" ]];
};

sub add_file {
    my( $self, $file )= @_;
    my $info = {
            file_size => -s $file,
            url => $file,
            max_size => { x => undef, y => undef, },
            duration => 3600, # fake it till you make it!
            ct => 'video/mp4v',
            # Hrmm - can we open uglified file URIs? :-/
            method => "local",
        };
    return $self->add_stream_info( $info );
};

sub add_url {
    my( $self, $url, %options )= @_;
    # XXX This should be asynchronous
    # Also, there is pre-existing information that should be cached/passed in here!
    my $v= $self->fetch_info( $url );
    $self->add_stream_info({
        url => $url,
        # max_size
        max_size => { x => undef, y => undef },
        # Well, we should find out:
        file_size => undef,
        method => "stream",
        additional_headers => {
            referer => $options{ referrer }, # no typo here
        },
        stream_info => $options{ stream_info },
    });
};

sub add_stream_info {
    my( $self, $info )= @_;
    
    # Canonicalize URL, so that identical URLs get the same (internal) hash

    # Use bas36 or something more compact later
    my $id= sha256_hex($info->{url});
    
    $self->{ proxy_urls }->{ $id }= {
        id => $id,
        dlna_url => sprintf( 'http://192.168.1.92:%d/media?video=%s', $self->{port}, $id ),
        %$info,
    };
}

sub proxied_info {
    my( $self, $id )= @_;
    $self->{ proxy_urls }->{ $id };
}

# Recognize Samsung devices via
# User-Agent =~ /SEC_HHP_.*/
# Add transcoding list from http://www.mattsbits.co.uk/item-105.html
sub serve_media {
    my( $self, $req )= @_;
    
    my $url= $req->uri;
    my $id= $req->parameters->as_hashref->{video};
    my $info= $self->proxied_info( $id )
        or die "Invalid/unknown URL '$id'";
    
    my %response_header;
    
    warn Dumper $req->headers;
    if( $req->headers->{'getcontentfeatures.dlna.org'} ) {
        # Also see http://libdlna.sourcearchive.com/documentation/0.2.3/dlna_8h-source.html
        $response_header{"contentFeatures.dlna.org"} = 'DLNA.ORG_PN=MPEG4_P2_MP4_SP_AAC;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';
    };
    # Respect the Range for easy streaming
    # $response->header(Content_Range => "bytes $startrange-$endrange/$size");
    $response_header{"TransferMode.DLNA.ORG"}= 'Streaming';

    # TimeSeekRange.dlna.org: npt=0-;
    # If we know the time, we can do:

    # getCaptionInfo.sec ?
    # Subtitles via SubtitleHttpHeader.sec

    if( $req->headers->{'getmediainfo.sec'} ) {
        #$response_header{"MediaInfo.sec"}= "SEC_Duration=" . $info->{duration} . ";";+
        my $d;
        if( $info->{stream_info} ) {
            $d= $info->{stream_info}->duration*1000
        } else {
            $d= 2667000; # magic number that was used in the first video I tested
        };
        $response_header{"MediaInfo.sec"}= "SEC_Duration=10000;";
        
    };

    #my($w,$h,$s)= 
    my $status= 200;
    $response_header{ "content-length" }= $info->{file_size}
        if $info->{file_size};
    $response_header{ "content-type" }= $info->{ct};
    
    if( "local" eq $info->{method}) {
        return $self->serve_media_file( $info, $status, \%response_header, $req );
    } else {
        return $self->serve_media_stream( $info, $status, \%response_header, $req );
    };
};

sub serve_media_file {
    my( $self, $info, $status, $headers, $req )= @_;
    # Simply serve a local file first:
    my $local_file= $info->{url};
    my $size= $info->{file_size}; # Save us one stat call :)
    
    my $method= $req->method;
    my $fh;
    if( 'GET' eq $method ) {
        open $fh, $local_file
            or die "Couldn't read '$local_file': $!";
        binmode $fh;
    };

    warn "File: $method";

    my ($startrange, $endrange) = (0,$size-1);
    if( $req->headers->{range}
            and $req->headers->{range} =~ /bytes\s*=\s*(\d+)-(\d+)?/) {
        ($startrange,$endrange) = ($1, ($2 || $endrange));
        $status= 206;
        $headers->{ "content-range" }= "bytes $startrange-$endrange/$size";
        $headers->{ "content-type" }= "video/mp4v"; # faake, and bad if we serve an .avi :)

        warn "Seeking to $startrange";
        if( $fh ) {
            seek $fh, $startrange,0
              or warn "Couldn't seek in $info->{url} : $!";
          };
        my $left= $endrange - $startrange;
        $headers->{"content-length"}= $left;
        warn "Serving $left bytes";
    };

    my $header_response= sub {
        my( $write_header )= @_;
        
        warn "File: $method response: " . Dumper $headers;
        my $body_writer= $write_header->([ $status, [ %$headers ]]);

        if( 'HEAD' eq $method ) {
            $body_writer->close;
            return;
        };
        my $timer; $timer= AnyEvent->timer( after => 0, interval => 1, cb => sub {
            $|++;
            print ".";
            
            my $shutdown;
            if(read $fh, my $buffer, $stream_from_disk_rate) {
                local $@;
                my $lived= eval {
                    $body_writer->write($buffer);
                    1;
                };
                $shutdown= ! $lived;
                warn $@ if ! $lived;
            } else {
                $shutdown= 1;
            };
            if( $shutdown ) {
                print "done.\n";
                $body_writer->close;
                undef $timer;
            };
        });
    };

    return $header_response;
};

sub serve_media_stream {
    my( $self, $info, $status, $response_headers, $req )= @_;

    my %request_headers;
    # Copy some choice headers across to Google
    for (qw(range)) {
        $request_headers{ $_ }= $req->headers->header( $_ );
    };
    
    if( $info->{ additional_headers }) {
        %request_headers= (%request_headers, %{ $info->{ additional_headers }});
        # http://a75.video2.blip.tv/15300012735231/Penny_Arcade-TheRabbitHole4thPanelEpisode11PennyArcadeTheSeriesSe344.m4v?ri=31407&rs=1626
        $request_headers{ "user-agent" }= "User-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64; rv:28.0) Gecko/20100101 Firefox/28.0";
    };
    
    my $method= $req->method;

    my $header_response= sub {
        my( $write_header )= @_;
        warn "Starting to respond to $method";
        #warn "Fetching YT";
        my $body_writer;
        my $get_guard;
        # We shouldn't necessarily launch more than one HEAD request at the remote site...
RETRY:
        $get_guard= http_request $method => $info->{url},
            headers => \%request_headers,
            handle_params => {
                max_read_size => 1024*1024, # 1 MB buffer per client connection
            },
            on_header => sub {
                my($remote_headers)= @_;

                warn "URL: $method response: " . Dumper $remote_headers;

                if( 302 eq $remote_headers->{Status} ) {
                    $info->{url}= $remote_headers->{location};
                    return 0;
                };
                
                # If we find that we don't need to proxy an URL
                # (based on content-type and client)
                # just redirect the client to the real source
                for (qw( content-type content-length content-range )) {
                    $response_headers->{ $_ }= $remote_headers->{ $_ }
                        if defined $remote_headers->{ $_ };
                };
                $response_headers->{ "content-type" } =~ s!/mp4$!/mp4v!;
                #$response_headers->{ "content-type" }= 'video/avi';
                $status= $remote_headers->{Status}; # Pass through errors and Range replies
                warn Dumper [%$response_headers];
                $body_writer= $write_header->( [$status, [ %$response_headers ] ]);
                #warn "Wrote header, have body part $body_writer, waiting for body";
                
                if('HEAD' eq $method) {
                    undef $get_guard;
                    $body_writer->write('');
                    $body_writer->close;
                    return 0; # we're done
                };
                
                return 1; # continue
            },
            on_body => sub {
                my( $partial_body, $headers )= @_;
                #warn "Body response: " . $headers->{Status};
                $|++;
                print ".";
                my $continue;
                if( length $partial_body ) {
                    eval {
                        $body_writer->write( $partial_body );
                        $continue= 1;
                    };
                    warn "(caught) $@" if not $continue;
                } else {
                    $continue= 0
                };
                return $continue
            },
            # Cleanup
            sub { 
                my( $body, $headers )= @_;
                #warn "Final response: " . $headers->{Status};
                print "done\n";
                $body_writer->close;
                undef $get_guard;
            };
    };
    return $header_response;
};

# Map MIME info and an UA to an appropriate transcoder
# Currently always returns "identity"
# MimeTypesChanges=audio/wav=audio/L16|video/x-matroska=video/avi|video/x-flv=video/mp4|audio/mp3=audio/L16|video/mp4=video/mpeg
sub find_target_transcoder {
    # First, only do youtuba!
    return {
        # Identity transcoder
        transcoder => undef,
    
        input_format => {
            # 37  MP4 h.264 3653 Kbps 1920x1080 29.970 fps  AAC 128 Kbps  2ch 44.10 KHz
            ct => 'video/mp4v',
        },
        output_format => {
            # 37  MP4 h.264 3653 Kbps 1920x1080 29.970 fps  AAC 128 Kbps  2ch 44.10 KHz
            ct => 'video/mp4v',
        },
    },
}

1;

package AnyEvent::TimedFileStreamer;

package Media::Info::AnyEvent;
use strict;

# Promise-style media information

sub new {
    my $class= shift;
    my( %self )= @_;
    my $self= bless \%self, $class;
    # Trampoline into fetching the information
    # Rate limiting is the duty of the caller
    $self{ cb }||= AnyEvent->condvar;
    my $t; $t= AnyEvent->timer( after => 0, cb => sub { $self->fetch_info; undef $t } );
    $self
}

sub set_info {
    my( $self, %info )= @_;
    @{$self}{ keys %info }= values %info;
    $_[0]->{cb}->send( $self );
};

sub get_info {
    my $info= $_[0]->{cb}->recv;
    warn Dumper $info;
    #$_[0]->{cb}->recv;
    $info
};

sub content_type { $_[0]->get_info->{ct} }
sub duration { $_[0]->get_info->{duration} }
sub url { $_[0]->{url} }

package Media::Info::AnyEvent::YouTube;
use strict;
use Carp qw( croak );
use Data::Dumper;
use parent '-norequire', 'Media::Info::AnyEvent';
use URI::Escape 'uri_unescape';
use WebService::GData::YouTube; # Still uses LWP instead of AnyEvent...

# Code taken from JWZ's youtubedown

sub canonical_video_info {
    my( $self, $url )= @_;
    my $org_url= $url;

    # Rewrite youtu.be URL shortener.
    $url =~ s@^https?://([a-z]+\.)?youtu\.be/@http://youtube.com/v/@si;

    $url =~ s@^https:@http:@s;	# No https.

    my ($id, $site, $playlist_p);

    # Youtube /view_play_list?p= or /p/ URLs. 
    if ($url =~ m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/
                (?: view_play_list\?p= |
                    p/ |
                    embed/p/ |
                    playlist\?list=(?:PL)? |
                    embed/videoseries\?list=(?:PL)?
                )
                ([^<>?&,]+) ($|&) @sx) {
      ($site, $id) = ($1, $2);
      $url = "http://www.$site.com/view_play_list?p=$id";
      $playlist_p = 1;

    # Youtube /watch/??v= or /watch#!v= or /v/ URLs. 
    } elsif ($url =~ m@^https?:// (?:[a-z]+\.)?
                     (youtube) (?:-nocookie)? (?:\.googleapis)? \.com/+
                     (?: (?: watch/? )? (?: \? | \#! ) v= |
                         v/ |
                         embed/ |
                         .*? &v= |
                         [^/\#?&]+ \#p(?: /[a-zA-Z\d] )* /
                     )
                     ([^<>?&,\'\"]+) ($|[?&]) @sx) {
      ($site, $id) = ($1, $2);
      $url = "http://www.$site.com/watch?v=$id";

    # Youtube "/verify_age" URLs.
    } elsif ($url =~ 
           m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/+
	     .* next_url=([^&]+)@sx ||
           $url =~ m@^https?://(?:[a-z]+\.)?google\.com/
                     .* service = (youtube)
                     .* continue = ( http%3A [^?&]+)@sx ||
           $url =~ m@^https?://(?:[a-z]+\.)?google\.com/
                     .* service = (youtube)
                     .* next = ( [^?&]+)@sx
          ) {
      $site = $1;
      $url = uri_unescape($2);
      if ($url =~ m@&next=([^&]+)@s) {
        $url = uri_unescape($1);
        $url =~ s@&.*$@@s;
      }
  };
    
    die "No ID found in $org_url ($url)"
        unless $id;
    return {
        url => $url,
        site => $site,
        id => $id,
        is_playlist => $playlist_p,
    }
}

sub fetch_info {
    my( $self )= @_;
    my $headers= $self->{ headers } || {};
    
    my $info= $self->canonical_video_info( $self->{url} );
    #http_head $self->{url},
    #    headers => $headers,
    #    sub {
    #        my( $body, $headers )= @_;
    #        my %info;
    #        $info{ ct }= $headers->{ content_type };
    #        
    #        $self->set_info(
    #    };
warn "Fetching info for $info->{id}";
    my $yt = new WebService::GData::YouTube();
    my $video= $yt->get_video_by_id($info->{id});
warn "Got " . Dumper $video;
warn sprintf "%d s", $video->duration;
    
    for (qw( duration title )) {
        $info->{$_}= $video->$_;
    };
    $self->set_info($info);
};

package HTTP::Response::DLNA;
use strict;

# Will return something akin to an appropriate response
# including the appropriate headers

1;