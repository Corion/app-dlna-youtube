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
    'device-filter|d:s' => \my $device_filter,
    'timeout|t:s' => \my $mx,
);
$device_filter ||= '';
$mx ||= 3;
 
for my $device (DLNA::Device::find_media_renderers( mx => $mx )) {
    next unless $device->getfriendlyname =~ /$device_filter/;

    print join "\t",
        $device->getfriendlyname, $device->getmanufacturer;
    print "\n";
};

