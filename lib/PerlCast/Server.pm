package PerlCast::Server;
use strict;
use HTTP::ServerEvent;
use JSON::XS qw(encode_json decode_json);
use Plack::Request;

use vars qw($VERSION);
$VERSION= '0.01';

sub new {
    my( $class, %options )= @_;
    $options{ client_html }||= 'html/mediaclient.html';
    $options{ clients }||= [];
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
          
            warn "Appended writer";
            push @{ $self->{clients}}, $writer;
        };
    }
}

sub send_data {
    my( $self, $payload )= @_;
    use Data::Dumper;
    warn $payload;
    warn Dumper $payload;
    my $json= encode_json( $payload );
    my $data= HTTP::ServerEvent->as_string(
        event => 'dlna',
        data => $json,
    );
    for( @{$self->{clients}}) {
        #warn "Wrote to client:";
        #warn $data;
        eval {
            # Guard against disconnected sockets
            $_->write( $data );
        };
    };
};

1