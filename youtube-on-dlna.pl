#!perl -w
use strict;
#use Net::UPnP;
use  Net::UPnP::AV::MediaRenderer;

use Net::UPnP::ControlPoint;
 
my $obj = Net::UPnP::ControlPoint->new();
 
my @dev_list;;
my $retry_cnt;
while (@dev_list <= 0 || $retry_cnt > 5) {
        @dev_list = $obj->search(st =>'upnp:rootdevice', mx => 3);
        $retry_cnt++;
} 

sub Net::UPnP::AV::MediaRenderer::protocolInfo {
	my($this) = shift;
	my %args = (
		InstanceID => 0,	
		@_,
	);
	
	my (
		$dev,
		$avtrans_service,
		%req_arg,
	);
	
	$dev = $this->getdevice();
	$avtrans_service = $dev->getservicebyname($Net::UPnP::AV::MediaRenderer::AVTRNSPORT_SERVICE_TYPE);
	
	%req_arg = (
			'InstanceID' => $args{InstanceID},
			'NextURI' => $args{NextURI},
			'NextURIMetaData' => $args{NextURIMetaData},
		);
	
	$avtrans_service->postaction("SetNextAVTransportURI", \%req_arg);
};
my $devNum= 0;
foreach my $dev (@dev_list) {
        my $device_type = $dev->getdevicetype();
        #warn $device_type;
        if  ($device_type ne 'urn:schemas-upnp-org:device:MediaRenderer:1') {
            next;
        }
        my $friendlyname = $dev->getfriendlyname(); 
        print "[$devNum] : " . $friendlyname . "\n";
        my $renderer = Net::UPnP::AV::MediaRenderer->new();
        $renderer->setdevice($dev);
        
        # Now, ask the TV what it wants/supports:
        #print $renderer->protocolInfo();
        # We need to get at the AVTransport + control
        

#curl -H ‘Content-Type: text/xml; charset=utf-8′ -H ‘SOAPAction: “urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI”‘ -d ‘<?xml version=”1.0″ encoding=”utf-8″?><s:Envelope s:encodingStyle=”http://schemas.xmlsoap.org/soap/encoding/” xmlns:s=”http://schemas.xmlsoap.org/soap/envelope/”><s:Body><u:SetAVTransportURI xmlns:u=”urn:schemas-upnp-org:service:AVTransport:1″><InstanceID>0</InstanceID><CurrentURI><![CDATA[http://my.site.com/path/to/my/content.mp4]]></CurrentURI><CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>’ ‘http://192.168.1.101:59772/AVTransport/21fc4817-b8f7-ee43-1461-68a55e55fce0/control.xml‘
#curl -H ‘Content-Type: text/xml; charset=utf-8′ -H ‘SOAPAction: “urn:schemas-upnp-org:service:AVTransport:1#Play”‘ -d ‘<?xml version=”1.0″ encoding=”utf-8″?><s:Envelope s:encodingStyle=”http://schemas.xmlsoap.org/soap/encoding/” xmlns:s=”http://schemas.xmlsoap.org/soap/envelope/”><s:Body><u:Play xmlns:u=”urn:schemas-upnp-org:service:AVTransport:1″><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>’ ‘http://192.168.1.101:59772/AVTransport/21fc4817-b8f7-ee43-1461-68a55e55fce0/control.xml‘

        $renderer->stop();
        my $url= 'http://192.168.1.102:8080/Tim.Burtons.Vincent.avi';
        warn "Playing $url";
        #$renderer->setAVTransportURI(CurrentURI => 'http://aliens.maischein.home:8080/Tim.Burtons.Vincent.avi');
        $renderer->setAVTransportURI(CurrentURI => $url);
        use Data::Dumper;
        print Dumper $renderer->play(); 
        $devNum++;
}