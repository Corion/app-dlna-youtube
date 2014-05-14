package JWZ::YouTubeDown;
use Carp qw( croak );

=head1 NAME

JWZ::YouTubeDown - download from YouTube

=head1 DESCRIPTION

Package that reappropriates code from jwz's C<youtubedown>
at L<http://www.jwz.org/hacks/youtubedown>
and makes it available through a module

=cut

sub decipher_selftest {
    JWZ::YouTubeDown::jwz_youtubedown::decipher_selftest();
};

sub download_video_url {
    my( $url, $target, $format )= @_;
    JWZ::YouTubeDown::jwz_youtubedown::download_video_url(
        #($url, $title, undef, $size_p, $progress_p, 0, $fmt);
        $url, undef, undef, undef, undef, 0, $format
    );
};

=head1 HOW IT WORKS

The module includes a copy of the C<youtubedown>
script and loads that script into the package JWZ::YoutTubeDown.
That's all.

=cut

sub import {
    my( $file )= $INC{ "JWZ/YouTubeDown.pm" };
    $file =~ s!YouTubeDown.pm!youtubedown.pl!;
    
    load_youtubedown( file => $file );
    
    print "$file loaded";
    1
}

sub load_youtubedown {
    my( %options )= @_;
    my $file= $options{ file }
        or croak "No 'file' given to load youtubedown from";
    #my $target_package= $options{ target }
    #    or croak "No 'target' package given to install youtubedown code into";

    # Now, redefine some things that otherwise break loading
    # the script as a module:
    package JWZ::YouTubeDown::jwz_youtubedown;

    # defang calls to exit()
    no strict 'refs';
    use subs 'exit';
    *{'exit'} = sub {};
    
    # The program wants to load locale (ugh!) and set the locale to en_US (double-ugh, yeah!)
    # We prevent that and leave that handling to user-facing parts (which will reimplement what jwz
    # wrote, undoubitably, but that has no place in the library to fetch/download videos)
    local %INC= %INC;
    $INC{ "locale.pm" }= 'Yeah, loaded';
    $INC{ "POSIX.pm" }= 'Yeah, loaded';
    local *LC_ALL = sub () {0};
    local *setlocale = sub {};

    # Make the program think it is run from the console    
    local $ENV{REQUEST_URI};
    
    # The program wants to reopen/binmode STDOUT and prints to STDERR
    local *STDERR;
    local *STDOUT;
    open( STDERR, '>', \my $stderr );
    open( STDOUT, '>', \my $stdout );
    
    local $@;
    local *ARGV= ['-v+++++'];
    
    open my $fh, '<', $file
        or Carp::croak "Couldn't open '$file': $!";
    binmode $fh;
    my $code= do { local $/; <$fh> };
    eval "package JWZ::YouTubeDown::jwz_youtubedown; $code";
    if( ! defined $res ) {
        die $@ if $@; # eval error
        die $! if $!; # file error
    };
    
    # Youtubedown brings its own HTTP implementation. We force our own down its throat instead:
    no warnings 'redefine';
    # Maybe only do that if we detect that AnyEvent is loaded?!
    # Or via some import parameter, 
    #*get_url= ($;$$$$$$$) { do_http_request, synchronously }
}

1;