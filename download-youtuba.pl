#!perl -w
use strict;
use JWZ::YouTubeDown;
use Data::Dumper;

warn Dumper JWZ::YouTubeDown::fetch_url_info('http://www.youtube.com/watch?v=dGghkjpNCQ8');