#!perl -w
use strict;
use Carp qw(croak);
use Data::Dumper;

use AnyEvent;
use AnyEvent::DLNAServer::MediaServer;
use DLNA::Device;
use JWZ::YouTubeDown;
#use Video::FindStream;
use File::Spec;
use Getopt::Long;

GetOptions(
    'referrer|r:s' => \my $referrer,
    'device|d:s' => \my $device_name,
);
$device_name||= $ENV{DLNA_VIDEO_RENDERER} || 'TV-46C6700';

my $media= AnyEvent::DLNAServer::MediaServer->new();
my $info;
#my $info= $media->add_file('//aliens/media/movies/Tim.Burtons.Vincent.avi');
#$info= $media->add_file(File::Spec->rel2abs('Calvin Harris - Feel So Close (2011).mp4'));

if( @ARGV ) {
    my $resource= $ARGV[0];
    
    if( -f $resource) {
        $info= $media->add_file($resource, expires => 180);
    } elsif ( $resource =~ /vimeo|youtu/ ) {
        # jwz got this
        my $yt_info= JWZ::YouTubeDown::fetch_url_info($resource);
        $info= $media->add_url($yt_info->{url}, expires => 180,
            stream_info => Media::Info::AnyEvent::YouTube->new( url => $resource ),
        );
    } else {
        # must be a real stream url
        #my $vid_info= Video::FindStream::fetch_url_info($resource) || { url => $resource };
        my $vid_info= { url => $resource };
        $info= $media->add_url($vid_info->{ url }, expires => 180, referrer => $referrer);
    };
} else {
    $info= $media->add_file(File::Spec->rel2abs('Calvin Harris - Feel So Close (2011).mp4'));
};

my $url= $info->{dlna_url};


my $cache_file= 'known_devices.db';
DLNA::Device::device_cache( $cache_file );

my $device= DLNA::Device::find_device( $device_name )
    or die "No UPnP device found for '$device_name'";

print sprintf "Playback of %s using %s\n", $url, $device->getfriendlyname;

#system(sprintf q(start perl -Ilib -w dlna-play-url.pl -d %s "%s"), $device->getfriendlyname, $url);

my $renderer = Net::UPnP::AV::MediaRenderer->new();
#use Data::Dumper;
#warn Dumper $device->getservicebyname($Net::UPnP::AV::MediaRenderer::AVTRNSPORT_SERVICE_TYPE);
$renderer->setdevice($device);
$renderer->stop();

$renderer->setAVTransportURI(CurrentURI => $url);
$renderer->play(); 

print "Waiting for things to happen\n";
AnyEvent->condvar->recv;