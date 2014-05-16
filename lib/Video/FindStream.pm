package Video::FindStream;
use strict;
use LWP::Simple; # well, actually, AnyEvent::HTTP::Synchronized, later

sub fetch_url_info {
    my( $url, %options)= @_;
    my $info
    if( $url =~ /blip.tv/ ) {
        return fetch_url_info_blip( $url );
    };
    return $info;
}

# http://blip.tv/post/episode-%s?skin=rss maybe for better info?
# Maybe see XBMC?
# Also http://hoyois.github.io/safariextensions/clicktoplugin/killers.xhtml ?
sub fetch_url_info_blip {
    # They offer an HTML player, so maybe this should just look for <video> elements?!
    my $content= get 'http://blip.tv/play/AYOh%2BRcA.s?p=1&embed_params=brandlink%3Dhttp%3A%2F%2Fwww.penny-arcade.com%26brandname%3DPA&template=replay';
    
    # config.id = "6847539";
	# config.video.autoplay = false;
	# config.video.thumbnail = "//6.i.blip.tv/g?src=Penny_Arcade-Cliffhanger4thPanelEpisode10PennyArcadeTheSeriesSeason150-945.jpg&w=THUMB_WIDTH&h=THUMB_HEIGHT&fmt=jpg";
	# config.video.title = "Cliffhanger (4th Panel) - Episode 10, Penny Arcade: The Series, Season 4";
	# config.video.mediaLength = "627";
	# config.video.permalinkUrl = "http://blip.tv/penny-arcade/cliffhanger-4th-panel-episode-10-penny-arcade-the-series-season-4-6847539";
	# config.video.verticalURL = "";
	# config.video.roles = {
	#   blipsd : "Penny_Arcade-Cliffhanger4thPanelEpisode10PennyArcadeTheSeriesSeason858.m4v",
    #   blipld : "Penny_Arcade-Cliffhanger4thPanelEpisode10PennyArcadeTheSeriesSeason379.mp4",
    #   bliphd720 : "Penny_Arcade-Cliffhanger4thPanelEpisode10PennyArcadeTheSeriesSeason818.m4v"
	};
};

1;