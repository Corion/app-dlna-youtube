package
    Net::UPnP::HTTP;
use strict;
BEGIN { $INC{ 'Net/UPnP/HTTP.pm' } = __FILE__ };
use Net::UPnP::HTTPResponse;
use AnyEvent::HTTP qw(http_request);

use vars qw($STATUS_CODE $STATUS $HEADER $CONTENT $POST $GET);

$POST = 'POST';
$GET = 'GET';

$STATUS_CODE = 'status_code';
$STATUS = 'status';
$HEADER = 'header';
$CONTENT = 'content';

sub new {
	my($class) = shift;
	my($this) = {};
	bless $this, $class;
}

sub post {
	my($this) = shift;
	if (@_ <  6) {
		return "";
	}
	my ($post_addr, $post_port, $method, $path, $add_header, $req_content) = @_;
	my (
		$post_sockaddr,
		$req_content_len,
		$add_header_name,
		$add_header_value,
		$req_header,
		$res_status,
		$res_header_cnt,
		$res_header,
		$res_content_len,
		$res_content,
		$res,
		);

    my $done= AnyEvent->condvar;
    #warn "$method http://$post_addr:$post_port$path";
    http_request $method, "http://$post_addr:$post_port$path",
        headers => $add_header,
        body => $req_content,
        sub {
            my( $res_content, $headers )= @_;
            my( $res_status )= $headers->{Status};
            my( $res_header )= join "\r\n", map { "$_: $headers->{$_}" } keys %$headers;
            $res = Net::UPnP::HTTPResponse->new();
            $res->setstatus($res_status);
            $res->setheader($res_header);
            $res->setcontent($res_content);
            #warn $res_content;
            
            $done->send($res)
        };

    return $done->recv;
}

sub postsoap {
	my($this) = shift;
	my ($post_addr, $post_port, $path, $action_name, $action_content) = @_;
	my (
		%soap_header,
		$name,
		$value
	);
	
	%soap_header = (
		'Content-Type' => "text/xml; charset=\"utf-8\"",
		'SOAPACTION' => $action_name,
	);
	
	$this->post($post_addr, $post_port, $Net::UPnP::HTTP::POST, $path, \%soap_header, $action_content);
}

sub xmldecode {
	my (
		$str
	);
	if (ref $_[0]) {
		$str = $_[1];
	}
	else {
		$str = $_[0];
	}
	$str =~ s/\&gt;/>/g;
	$str =~ s/\&lt;/</g;
	$str =~ s/\&quot;/\"/g;
	$str =~ s/\&amp;/\&/g;
	$str;
}

package Net::UPnP::HTTP::AnyEvent;
use strict;
use AnyEvent::HTTP;
use AnyEvent::Handle::UDP;
use Net::UPnP;
use Net::UPnP::Device;

=head1 NAME

Net::UPnP::HTTP::AnyEvent - shim to make Net::UPnP AnyEvent aware

=head1 SYNOPSIS

  use Net::UPnP::HTTP::AnyEvent; # must be loaded before Net::UPnP
  use Net::UPnP::ControlPoint;
  ...

=cut

sub install {
    $INC{"Net/UPnP/HTTP.pm"}= __FILE__; # We replace it with our AnyEvent implementation below
    require Net::UPnP::ControlPoint;
    *Net::UPnP::ControlPoint::search= \&upnp_controlpoint_search;
};

sub upnp_controlpoint_query {
    my( $location, $ssdp_res_msg, $cb )= @_;
    
    http_get $location, sub {
        my( $post_content, $headers )= @_;
        my $dev = Net::UPnP::Device->new();
        $dev->setssdp($ssdp_res_msg);
        $dev->setdescription($post_content);
        $cb->( $dev );
    };
}

sub upnp_controlpoint_search {
	my($this) = shift;
	my %args = (
		st => 'upnp:rootdevice',	
		mx => 3,
		cb => undef
		@_,
	);
	my(
		@dev_list,
		$ssdp_header,
		$ssdp_mcast,
		$rin,
		$rout,
		$ssdp_res_msg,
		$dev_location,
		$dev_addr,
		$dev_port,
		$dev_path,
		$http_req,
		$post_res,
		$post_content,
		$key,
		$dev,
		);
		
$ssdp_header = <<"SSDP_SEARCH_MSG";
M-SEARCH * HTTP/1.1
Host: $Net::UPnP::SSDP_ADDR:$Net::UPnP::SSDP_PORT
Man: "ssdp:discover"
ST: $args{st}
MX: $args{mx}

SSDP_SEARCH_MSG

	$ssdp_header =~ s/\r//g;
	$ssdp_header =~ s/\n/\r\n/g;
	
	my $queried= AnyEvent->condvar;
	$queried->begin(sub {
	    $args{ cb }->(@dev_list)
	        if $args{ cb };
	});

	my $ssdp_socket= AnyEvent::Handle::UDP->new(
	    on_recv => sub {
	        my( $ssdp_res_msg )= @_;
	        # We found some service
            unless ($ssdp_res_msg =~ m/LOCATION[ :]+(.*)\r/i) {
                next;
            }		
            my $dev_location = $1;
            unless ($dev_location =~ m/http:\/\/([0-9a-z.]+)[:]*([0-9]*)\/(.*)/i) {
                next;
            }
            
            # Now, ask who it is
            $queried->begin();
            upnp_controlpoint_query( $dev_location, $ssdp_res_msg, sub {
                push @dev_list, $_[0];
                $queried->end;
            });
	    },
	);

	my $timeout_w; 
	$queried->begin();
	my $timeout= AnyEvent->condvar;
	$timeout->cb( sub { undef $timeout_w; $queried->end });
	
	$timeout_w= AnyEvent->timer( after => $args{mx}*2, cb => $timeout );
	my $sent= $ssdp_socket->push_send( $ssdp_header, to => [$Net::UPnP::SSDP_PORT, $Net::UPnP::SSDP_ADDR] );
	$queried->begin;
	$sent->cb( sub { $queried->end });
	
	if(! $args{ cb }) {
        $queried->recv;
        return @dev_list
    };
}


1;
