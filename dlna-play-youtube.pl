#!perl -w
use strict;
use Carp qw(croak);
use Data::Dumper;

use DB_File;
use Net::UPnP::AV::MediaRenderer;
use Net::UPnP::ControlPoint;
use Net::UPnP::HTTP;
use URI;
use JWZ::YouTubeDown;

use Getopt::Long;
GetOptions(
    'device|d:s' => \my $device_name,
);
 
my $obj = Net::UPnP::ControlPoint->new();

tie my %devices, 'DB_File', 'known_devices.db';

sub find_media_renderers {
    my @dev_list;
    my $retry_cnt;
    while (@dev_list <= 0 || $retry_cnt > 5) {
            @dev_list = $obj->search(st =>'upnp:rootdevice', mx => 3);
            $retry_cnt++;
    } 
    
    my @res;
    foreach my $dev (@dev_list) {
        my $device_type = $dev->getdevicetype();
        #warn $device_type;
        if  ($device_type ne 'urn:schemas-upnp-org:device:MediaRenderer:1') {
            next;
        }
        my $friendlyname = $dev->getfriendlyname(); 
        #print "[$devNum] : " . $friendlyname . "\n";

        # Cache the device information
        $devices{ $friendlyname }= $dev->getssdp;
        push @res, $dev;
    }
    
    @res
};

sub device_from_cache {
    my( $friendlyname )= @_;
    my $ssdp= $devices{ $friendlyname }
        or return;

    (my $location)= ($ssdp =~ m/LOCATION[ :]+(.*)\r/i)
        or return;
    my $uri= URI->new( $location );
    my $http_req= Net::UPnP::HTTP->new();
    my $post_res = $http_req->post($uri->host, $uri->port, "GET", $uri->path, "", "");
    return
        unless $post_res;
    my $post_content = $post_res->getcontent();
    my $dev = Net::UPnP::Device->new();
    $dev->setssdp($ssdp);
    $dev->setdescription($post_content);
    $dev
};

my $device;
if( ! defined $device_name ) {
    $device_name= $devices{__last_used};
    $device= device_from_cache($device_name);
    if( ! defined $device ) {
        print "Using first available media renderer\n";
        ($device)= find_media_renderers;
        $device_name= $device->getfriendlyname;
        print "Found $device_name\n";
    } else {
        print "Using last used media renderer $device_name\n";
    };
} else {
    $device= $devices{ $device_name };
    if( ! $device ) {
        ($device)= grep { $_->getfriendlyname =~ /\Q$device_name/ } find_media_renderers($device_name);
    };
};

die "No UPnP device found for '$device_name'"
    unless $device;

print "Using " . $device->getfriendlyname;

my $renderer = Net::UPnP::AV::MediaRenderer->new();
$renderer->setdevice($device);

$devices{ __last_used }= $device_name;

$renderer->stop();

my $url= $ARGV[0];

my $info= JWZ::YouTubeDown::fetch_url_info($url);
print Dumper $info;
$renderer->setAVTransportURI(CurrentURI => $info->{url});
use Data::Dumper;
print Dumper $renderer->play(); 
