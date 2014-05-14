#!perl -w
use strict;
use Carp qw(croak);
use Data::Dumper;

use AnyEvent;
use AnyEvent::DLNAServer::MediaServer;
#use AnyEvent::HTTP;
use File::Spec;

my $media= AnyEvent::DLNAServer::MediaServer->new();
#my $info= $media->add_file('//aliens/media/movies/Tim.Burtons.Vincent.avi');
my $info= $media->add_file(File::Spec->rel2abs('Calvin Harris - Feel So Close (2011).mp4'));

warn Dumper $info;

my $url= $info->{dlna_url};
warn "Playing $url";
system("start perl -w dlna-play-url.pl $url");
#system(qq{start "Test" "$url"});

warn "Waiting for things to happen";
my $done= AnyEvent->condvar;
my $timeout= AnyEvent->timer( after => 120, cb => $done );
$done->recv;