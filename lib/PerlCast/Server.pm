package PerlCast::Server;
use strict;
use HTTP::ServerEvent;
use JSON::XS qw(encode_json decode_json);
use Plack::Request;
use Storable 'dclone';

use vars qw($VERSION);
$VERSION= '0.01';

sub new {
    my( $class, %options )= @_;
    $options{ client_html }||= 'html/mediaclient.html';
    # The clients should be per-channel
    $options{ clients }||= [];
    # current item
    # next item(s)
    my $self= bless \%options, $class;
};

sub as_psgi {
    my( $self )= @_;
    return sub {
        my($env)= @_;
        if( $env->{PATH_INFO} =~ m!^/?$! ) {
            open my $fh, '<', $self->{ client_html }
                or die "Couldn't read '$self->{ client_html }': $!";
            binmode $fh;
            return [
                200,
                ['Content-Type', 'text/html'],
                $fh
            ]
        };

        if( $env->{PATH_INFO} =~ m!^/command$! ) {
            my( $req )= Plack::Request->new( $env );
            my $payload= $req->param('command');
            if( $payload ) {
                my $cmd= decode_json( $payload );
                if( 'ARRAY' ne ref $cmd ) {
                    $cmd= [$cmd];
                };
                $self->set_current_item( $cmd );
                for my $val (@$cmd) {
                    $self->send_data( $val )
                };
            };
            return [
                200,
                ['Content-Type', 'text/html'],
                ['<html><body><form action="/command" enctype="multipart/form-data" method="POST"><textarea style="width:100%; height:95%" name="command"></textarea><input type=submit></form></html>'],
            ]
        };

        if( ! $env->{"psgi.streaming"}) {
            my $err= "Server does not support streaming responses";
            warn $err;
            return [ 500, ['Content-Type', 'text/plain'], [$err] ]
        };

        # immediately starts the response and stream the content
        return sub {
            my $responder = shift;
            my $writer = $responder->(
                [ 200, [ 'Content-Type', 'text/event-stream' ]]);
            
            $self->send_current_item($writer);
          
            warn "Appended writer";
            push @{ $self->{clients}}, $writer;
        };
    }
}

sub encode_data {
    my( $self, $payload )= @_;
    use Data::Dumper;
    #warn $payload;
    #warn Dumper $payload;
    my $json= encode_json( $payload );
    my $data= HTTP::ServerEvent->as_string(
        event => 'dlna',
        data => $json,
    );
    $data
}

sub send_data {
    my( $self, $payload )= @_;
    my $data= $self->encode_data( $payload );
    
    warn sprintf "Sending to %d clients", 0+@{ $self->{clients}};
    
    @{$self->{clients}}= grep {
        my $ok= eval {
            # Guard against disconnected sockets
            $_->write( $data );
            1;
        };
        
        if( ! $ok ) {
            eval { $_->close; };
        };
        
        $ok
    } @{ $self->{ clients }};
};

sub set_current_item {
    my( $self, $item, $ts )= @_;
    $ts ||= time;
    $self->{ current_item }= {
        ts => $ts,
        item => $item,
    };
};

sub send_current_item {
    my( $self, $writer )= @_;
    my $item= $self->{current_item};
    my $offset= time - $item->{ts};
    if( $offset > 10 ) {
        my $custom= dclone $item;
        # Let's just assume that the first element is the media element
        # Adjust for the late-coming client
        # This should come _after_ the client has fetched the video duration...
        # in the onmetadataloaded callback...
        splice @{$custom}, 1, 0, {"element" => "video", "property" =>  {"currentTime", $offset}}; 
        my $data= $self->encode_data( $custom );
        $writer->write($data);
    };
};

1