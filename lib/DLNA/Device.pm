package DLNA::Device;
use strict;

# Cache, ping and re-find DLNA devices

use DB_File;
use Net::UPnP::HTTP::AnyEvent; # overrides Net::UPnP::HTTP
use Net::UPnP::AV::MediaRenderer;
use Net::UPnP::ControlPoint;
use URI;

use vars qw(%cached_devices $cache_file);

sub device_cache {
    my( $filename )= @_;
    tie %cached_devices, 'DB_File', $filename;
};

sub find_device {
    my( $name, %options )= @_;
    $options{ device_cache } ||= \%cached_devices;
    $options{ mx } ||= 3;
    $options{ st } ||= 'upnp:rootdevice';
    $options{ device_type } ||= '';
    
    my $device= device_from_cache( $options{ device_cache }, $name );
    if( ! $device ) {
        my @devices= Net::UPnP::ControlPoint->new->search(st => $options{ st }, mx => $options{ mx });
        for my $dev ( @devices ) {
            # Cache the device information
            $options{ device_cache }->{ $dev->getfriendlyname }= $dev->getssdp;
        };
        ($device)= grep { $_->getfriendlyname =~ /\Q$name/ } @devices
    };

    $device
};
 
sub device_from_cache {
    my( $devices, $friendlyname )= @_;
    my $ssdp= $devices->{ $friendlyname }
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

sub find_media_renderers {
    my $obj = Net::UPnP::ControlPoint->new();

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
        push @res, $dev;
    }
    
    @res
};

1;