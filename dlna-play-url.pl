#!perl -w
use strict;
use Carp qw(croak);
use Data::Dumper;

use DB_File;
use DLNA::Device;
use Net::UPnP::AV::MediaRenderer;
use Net::UPnP::ControlPoint;
use URI;

use Getopt::Long;
GetOptions(
    'device|d:s' => \my $device_name,
);
$device_name||= $ENV{DLNA_VIDEO_RENDERER} || 'TV-46C6700';
 
my $cache_file= 'known_devices.db';
DLNA::Device::device_cache( $cache_file );

my $device= DLNA::Device::find_device( $device_name )
    or die "No UPnP device found for '$device_name'";

print "Using " . $device->getfriendlyname;

my $renderer = Net::UPnP::AV::MediaRenderer->new();
$renderer->setdevice($device);
$renderer->stop();

my $url= $ARGV[0];
#warn "Playing $url";
$renderer->setAVTransportURI(CurrentURI => $url);
use Data::Dumper;
print Dumper $renderer->play(); 
