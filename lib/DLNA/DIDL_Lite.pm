package DLNA::DIDL_Lite;
use strict;
use HTML::Entities qw(encode_entities);

=head1 NAME

DLNA::DIDL_Lite - producer for DIDL-Lite media description XML

=cut

# Consume AudioFile::Info

use vars (qw( %tagnames $xmlheader ));

$xmlheader= join '',
    '<?xml version="1.0"?>',
    '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
    ;

# Hrrm - some res@ should go into different <res> tags...
%tagnames=(
    id => '@id',
    artist   => 'dc:creator',
    album    => 'upnp:album',
    albumArtUri => 'upnp:albumArtURI', # <upnp:albumArtURI dlna:profileID="JPEG_TN">
    protocolInfo => 'res@protocolInfo',
    resource => 'res',
    size     => 'res@size',
    duration => 'res@duration',
    bitrate => 'res@bitrate',
    resolution => 'res@resolution',
    genre    => 'upnp:genre',
    channelName => 'upnp:channelName',
    channelNr   => 'upnp:channelNr',
    class    => 'upnp:class',
);

sub opening_tag {
    my( $self, $tagname, %attributes )= @_;
    $attributes= join " ",
        map { sprintf '%s="%s"', encode_entities($_), encode_entities($attributes{$_}) } keys %attributes;
    $attributes= " $attributes"
        if $attributes;
    "<$tagname$attributes>",
}

sub render {
    my( $self, $tagName )= @_;
    # Find what tags we have

    join "",
        $self->opening_tag( $tagName, { id => $self->{'@id'} ),
        (
            map  { $self->render_tag( $_ )  }
            grep { $tagnames{ $_ } !~ /\@/ };
            grep {/^[^_]/} keys %$self
        ),
        "</$tagName>";
}

sub render_tag {
    my( $self, $tagname )= @_;
    my %attributes= 
        map { $tagnames{ $_ } =~ /$tagname\@(.*)/ && defined $self->{ $_ } ? ($1 => $self->{$_}) : () } keys %tagnames;
    join "",
        $self->opening_tag( $tagname )
        encode_entities($self->{ $tagValue }),
        "</$tagname>",
    
}

sub new {
    my( $class, %options )= @_;
    bless \%options, $class
}

package DLNA::DIDL_Lite::AudioItem;
use strict;

sub render {
    my( $self )= @_;
    sprintf '<dc:creator>%s</dc:creator>'
        map {} @{ $self }{qw( artist )}
}
#dc:creator, upnp:album, upnp:genre,res@duration, res@size

package DLNA::DIDL_Lite::MusicAlbum;
use strict;

#dc:creator, upnp:genre, @childCount

package DLNA::DIDL_Lite::AudioBroadcast;
use strict;

# upnp:genre, upnp:channelName, upnp:channelNr (Applicability of upnp:channelNr depends on region)

package DLNA::DIDL_Lite::ImageItem;
use strict;

# dc:date, res@resolution, res@size

package DLNA::DIDL_Lite::VideoItem;
use strict;

# dc:date, upnp:genre, res@duration, res@size

package DLNA::DIDL_Lite::VideoBroadcast;
use strict;

# upnp:genre, upnp:channelName, upnp:channelNr (Applicability of upnp:channelNr depends on region)

1;