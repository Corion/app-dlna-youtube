package AnyEvent::DLNAServer::MediaServer;
use strict;
#use AnyEvent;
# Will serve media over HTTP to anyone who asks
use Plack;
use Plack::Request; # we do raw PSGI here :-/
use Twiggy::Server;

use Digest::SHA qw(sha256_hex);
use WebService::GData::YouTube; # Still uses LWP instead of AnyEvent...
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
    my $yt= WebService::GData::YouTube->new();
    (my $id)= $url=~m!([^/]+)$!;
    croak "No YouTube id found in '$url'" unless $id;
    return $yt->get_video_by_id($id);
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

sub fetch_video_info {
    my( $self, $url )= @_;
    # XXX This should be asynchronous
    my $v= $self->fetch_info( $url );
    $self->add_stream_info({
        # max_size
        max_size => { x => undef, y => undef },
        duration => $v->duration,
        # Well, we should find out:
        file_size => undef,
        method => "stream",
    });
};

sub add_stream_info {
    my( $self, $info )= @_;
    
    # Canonicalize URL

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
        #$response_header{"MediaInfo.sec"}= "SEC_Duration=" . $info->{duration} . ";";
        $response_header{"MediaInfo.sec"}= "SEC_Duration=2667000;";
        
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
    
    my $method= $req->method;

    my $header_response= sub {
        my( $write_header )= @_;
        warn "Starting to respond to $method";
        #warn "Fetching YT";
        my $body_writer;
        my $get_guard;
        # We shouldn't necessarily launch more than one HEAD request at the remote site...
        $get_guard= http_request $method => $info->{url},
            headers => \%request_headers,
            on_header => sub {
                my($remote_headers)= @_;
                warn "URL: $method response: " . Dumper $remote_headers;
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
                if(! $continue ) {
                    $body_writer->close;
                };
                return $continue
            },
            # Cleanup
            sub { 
                my( $body, $headers )= @_;
                #warn "Final response: " . $headers->{Status};
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
            ct => 'video/mp4',
        },
        output_format => {
            # 37  MP4 h.264 3653 Kbps 1920x1080 29.970 fps  AAC 128 Kbps  2ch 44.10 KHz
            ct => 'video/mp4',
        },
    },
}

1;

package AnyEvent::TimedFileStreamer;

package HTTP::Response::DLNA;
use strict;

# Will return something akin to an appropriate response
# including the appropriate headers

1;