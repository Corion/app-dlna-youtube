#!/usr/bin/perl -w
# Copyright © 2007-2013 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
# Given a YouTube or Vimeo URL, downloads the corresponding MP4 file.
# The name of the file will be derived from the title of the video.
#
#  --title "STRING"  Use this as the title instead.
#  --progress        Show a textual progress bar for downloads.
#  --suffix          Append the video ID to each written file name.
#  --size            Instead of downloading it all, print video dimensions.
#		     This requires "mplayer" and/or "ffmpeg".
#
# For playlists, it will download each video to its own file.
#
# You can also use this as a bookmarklet: put it somewhere on your web server
# as a .cgi, then bookmark this URL:
#
#   javascript:location='http://YOUR_SITE/youtubedown.cgi?url='+location
#
# or, the same thing but using a small popup window,
#
#   javascript:window.open('http://YOUR_SITE/youtubedown.cgi?url='+location.toString().replace(/%26/g,'%2526').replace(/%23/g,'%2523'),'youtubedown','width=400,height=50,top=0,left='+((screen.width-400)/2))
#
#
# When you click on that bookmarklet in your toolbar, it will give you
# a link on which you can do "Save Link As..." and be offered a sensible
# file name by default.
#
# Make sure you host that script on your *local machine*, because the entire
# video content will be proxied through the server hosting the CGI, and you
# don't want to effectively download everything twice.
#
# Created: 25-Apr-2007.

require 5;
use diagnostics;
use strict;
use Socket;

my $progname0 = $0;
my $progname = $0; $progname =~ s@.*/@@g;
my ($version) = ('$Revision: 1.315 $' =~ m/\s(\d[.\d]+)\s/s);

# Without this, [:alnum:] doesn't work on non-ASCII.
use locale;
use POSIX qw(locale_h);
setlocale(LC_ALL, "en_US");

my $verbose = 1;
my $append_suffix_p = 0;

my $http_proxy = undef;

$ENV{PATH} = "/opt/local/bin:$ENV{PATH}";   # for macports mplayer

my @video_extensions = ("mp4", "flv", "webm");


my $html_head =
  ("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\"\n" .
   "	  \"http://www.w3.org/TR/html4/loose.dtd\">\n" .
   "<HTML>\n" .
   " <HEAD>\n" .
   "  <TITLE></TITLE>\n" .
   " <STYLE TYPE=\"text/css\">\n" .
   "  body { font-family: Arial,Helvetica,sans-serif; font-size: 12pt;\n" .
   "         color: #000; background: #FF0; }\n" .
   "  a { font-weight: bold; }\n" .
   "  .err { font-weight: bold; color: #F00; }\n" .
   " </STYLE>\n" .
   " </HEAD>\n" .
   " <BODY>\n");
my $html_tail = " </BODY>\n</HTML>\n";
     


my $noerror = 0;

sub error($) {
  my ($err) = @_;

  if (defined ($ENV{HTTP_HOST})) {
    $err =~ s/&/&amp;/gs;
    $err =~ s/</&lt;/gs;
    $err =~ s/>/&gt;/gs;

    # $error_whiteboard kludge
    $err =~ s/^\t//gm;
    $err =~ s@\n\n(.*)\n\n@<PRE STYLE="font-size:9pt">$1</PRE>@gs;
    # $err =~ s/\n/<BR>/gs;

    $err = $html_head . '<P><SPAN CLASS="err">ERROR:</SPAN> ' . $err .
           $html_tail;
    $err =~ s@(<TITLE>)[^<>]*@$1$progname: Error@gsi;

    print STDOUT ("Content-Type: text/html\n" .
                  "Status: 500\n" .
                  "\n" .
                  $err);
    die "$err\n" if ($verbose > 2);  # For debugging CGI.
    exit 1;
  } elsif ($noerror) {
    die "$err\n";
  } else {
    print STDERR "$progname: $err\n";
    exit 1;
  }
}


# For internal errors.
my $errorI = ("\n" .
              "\n\tPlease report this URL to jwz\@jwz.org!" .
              "\n\tBut make sure you have the latest version first:" .
              "\n\thttp://www.jwz.org/hacks/#youtubedown" .
              "\n");
my $error_whiteboard = '';	# for signature diagnostics

sub errorI($) {
  my ($err) = @_;
  if ($error_whiteboard) {
    $error_whiteboard =~ s/^/\t/gm;
    $err .= "\n\n" . $error_whiteboard;
  }
  $err .= $errorI;
  error ($err);
}


sub de_entify($) {
  my ($text) = @_;
  $text =~ s/&([a-zA-Z])(uml|acute|grave|tilde|cedil|circ|slash);/$1/g;
  $text =~ s/&lt;/</g;
  $text =~ s/&gt;/>/g;
  $text =~ s/&amp;/&/g;
  $text =~ s/&(quot|ldquo|rdquo);/"/g;
  $text =~ s/&(rsquo|apos);/'/g;
  return $text;
}


sub url_quote($) {
  my ($u) = @_;
  $u =~ s|([^-a-zA-Z0-9.\@/_\r\n])|sprintf("%%%02X", ord($1))|ge;
  return $u;
}

sub url_unquote($) {
  my ($u) = @_;
  $u =~ s/[+]/ /g;
  $u =~ s/%([a-z0-9]{2})/chr(hex($1))/ige;
  return $u;
}

sub html_quote($) {
  my ($u) = @_;
  $u =~ s/&/&amp;/g;
  $u =~ s/</&lt;/g;
  $u =~ s/>/&gt;/g;
  $u =~ s/\"/&quot;/g;
  return $u;
}


my $progress_ticks = 0;
my $progress_time = 0;

sub draw_progress($) {
  my ($ratio) = @_;

  my $now = time();
  my $eof = ($ratio == -1);
  $ratio = 1 if $eof;

  return if ($progress_time == $now && !$eof);

  my $cols = 72;
  my $ticks = int($cols * $ratio);

  if ($ticks > $progress_ticks) {
    my $pct = sprintf("%3d%%", 100 * $ratio);
    $pct =~ s/^  /. /s;
    print STDERR "\b" x length($pct)			# erase previous pct
      if ($progress_ticks > 0);
    while ($ticks > $progress_ticks) {
      print STDERR ".";
      $progress_ticks++;
    }
    print STDERR $pct;
  }
  print STDERR "\r" . (' ' x ($cols + 4)) . "\r" if ($eof);	# erase line
  $progress_time = $now;
}



# Loads the given URL, returns: $http, $head, $body.
#
sub get_url_1($;$$$$$$) {
  my ($url, $referer, $extra_headers, $head_p, $to_file, $max_bytes,
      $expect_bytes) = @_;
  
  my $progress_p = ($expect_bytes && $expect_bytes > 0);
  $expect_bytes = -$expect_bytes if ($expect_bytes && $expect_bytes < 0);

  error ("can't do HEAD and write to a file") if ($head_p && $to_file);

  error ("not an HTTP URL, try rtmpdump: $url") if ($url =~ m@^rtmp@i);
  error ("not an HTTP URL: $url") unless ($url =~ m@^(http|feed)://@i);

  my ($url_proto, $dummy, $serverstring, $path) = split(/\//, $url, 4);
  $path = "" unless $path;

  my ($them,$port) = split(/:/, $serverstring);
  $port = 80 unless $port;

  my $them2 = $them;
  my $port2 = $port;
  if ($http_proxy) {
    $serverstring = $http_proxy if $http_proxy;
    $serverstring =~ s@^[a-z]+://@@;
    ($them2,$port2) = split(/:/, $serverstring);
    $port2 = 80 unless $port2;
  }

  my ($remote, $iaddr, $paddr, $proto, $line);
  $remote = $them2;
  if ($port2 =~ /\D/) { $port2 = getservbyname($port2, 'tcp') }
  if (!$port2) {
    error ("unrecognised port in $url");
  }

  $iaddr = inet_aton($remote);
  error ("host not found: $remote") unless ($iaddr);

  $paddr   = sockaddr_in($port2, $iaddr);


  my $head = "";
  my $body = "";

  $proto   = getprotobyname('tcp');
  if (!socket(S, PF_INET, SOCK_STREAM, $proto)) {
    error ("socket: $!");
  }
  if (!connect(S, $paddr)) {
    error ("connect: $serverstring: $!");
  }

  select(S); $| = 1; select(STDOUT);

  my $user_agent = "$progname/$version";

  my $hdrs = (($head_p ? "HEAD " : "GET ") .
              ($http_proxy ? $url : "/$path") . " HTTP/1.0\r\n" .
              "Host: $them\r\n" .
              "User-Agent: $user_agent\r\n");

  $extra_headers = '' unless defined ($extra_headers);
  $extra_headers .= "\nReferer: $referer" if ($referer);
  if ($extra_headers) {
    $extra_headers =~ s/\r\n/\n/gs;
    $extra_headers =~ s/\r/\n/gs;
    foreach (split (/\n/, $extra_headers)) {
      $hdrs .= "$_\r\n" if $_;
    }
  }

  $hdrs .= "\r\n";

  if ($verbose > 3) {
    foreach (split('\r?\n', $hdrs)) {
      print STDERR "  ==> $_\n";
    }
  }
  print S $hdrs;
  my $http = <S> || "";

  $_  = $http;
  s/[\r\n]+$//s;
  print STDERR "  <== $_\n" if ($verbose > 3);

  # If the URL isn't there, don't write to the file.
  $to_file = undef unless ($http =~ m@^HTTP/[0-9.]+ 20\d@si);

  while (<S>) {
    $head .= $_;
    s/[\r\n]+$//s;
    last if m@^$@;
    print STDERR "  <== $_\n" if ($verbose > 3);
  }

  print STDERR "  <== \n" if ($verbose > 4);

  my $out;

  if ($to_file) {
    # Must be 2-arg open for ">-" when $outfile is '-'.
    open ($out, ">$to_file") || error ("$to_file: $!");
    binmode ($out);
  }

  # If we're proxying a download, also copy the document's headers.
  #
  if ($to_file && $to_file eq '-') {

    # Maybe if we nuke the Content-Type, that will stop Safari from
    # opening the file by default.  Answer: nope.
    #  $head =~ s@^(Content-Type:)[^\r\n]+@$1 application/octet-stream@gmi;
    # Ok, maybe if we mark it as an attachment?  Answer: still nope.
    #  $head = "Content-Disposition: attachment\r\n" . $head;

    print $out $head;
  }

  # Don't line-buffer binary bodies.
  # No, this breaks --progress. Probably doesn't improve performance either.
  #
  #  local $/ = $/;
  #  $/ = undef if ($to_file);

  my $lines = 0;
  my $bytes = 0;
  while (<S>) {
    if ($to_file) {
      print $out $_;
      $bytes += length($_);
    } else {
      s/\r\n/\n/gs;
      $_ .= "\n" unless ($_ =~ m/\n$/s);
      print STDERR "  <== $_" if ($verbose > 4);
      $body .= $_;
      $bytes += length($_);
      $lines++;
    }
    draw_progress ($bytes / $expect_bytes) if ($progress_p);
    last if ($max_bytes && $bytes >= $max_bytes);
  }
  draw_progress (-1) if ($progress_p);

  if ($to_file) {
    close $out || error ("$to_file: $!");
    print STDERR "  <== [ body ]: $bytes bytes to file \"$to_file\"\n"
      if ($verbose > 3);
  } else {
    print STDERR "  <== [ body ]: $lines lines, " . length($body) . " bytes\n"
      if ($verbose == 4);
  }

  close S;

  if (!$http) {
    error ("null response: $url");
  }

  # Check to see if a network failure truncated the file.
  # Maybe we should delete the file too?
  #
  if ($to_file && $expect_bytes && $bytes != $expect_bytes) {
    my $pct = int (100 * $bytes / $expect_bytes);
    $pct = sprintf ("%.2f", 100 * $bytes / $expect_bytes) if ($pct == 100);
    print STDERR "$progname: WARNING: got only $pct%" .
      " ($bytes instead of $expect_bytes) of \"$to_file\"\n";
  }

  return ($http, $head, $body);
}


# Loads the given URL, processes redirects.
# Returns: $http, $head, $body, $final_redirected_url.
#
sub get_url($;$$$$$$$) {
  my ($url, $referer, $headers, $head_p, $to_file, $max_bytes, $retry_p,
      $expect_bytes) = @_;

  print STDERR "$progname: " . ($head_p ? "HEAD" : "GET") . " $url\n"
    if ($verbose > 2);

  my $orig_url = $url;
  my $redirect_count = 0;
  my $max_redirects  = 10;
  my $error_count    = 0;
  my $max_errors     = ($retry_p ? 10 : 0);
  my $error_delay    = 1;

  do {
    my ($http, $head, $body) = 
      get_url_1 ($url, $referer, $headers, $head_p, $to_file, $max_bytes,
                 $expect_bytes);

    $http =~ s/[\r\n]+$//s;

    if ( $http =~ m@^HTTP/[0-9.]+ 30[123]@ ) {
      $_ = $head;

      my ( $location ) = m@^location:[ \t]*(.*)$@im;
      if ( $location ) {
        $location =~ s/[\r\n]$//;

        print STDERR "$progname: redirect from $url to $location\n"
          if ($verbose > 3);

        $referer = $url;
        $url = $location;

        if ($url =~ m@^/@) {
          $referer =~ m@^(https?://[^/]+)@i;
          $url = $1 . $url;
        } elsif (! ($url =~ m@^[a-z]+:@i)) {
          $_ = $referer;
          s@[^/]+$@@g if m@^https?://[^/]+/@i;
          $_ .= "/" if m@^https?://[^/]+$@i;
          $url = $_ . $url;
        }

      } else {
        error ("no Location with \"$http\"");
      }

      if ($redirect_count++ > $max_redirects) {
        error ("too many redirects ($max_redirects) from $orig_url");
      }

    } elsif ( $http =~ m@^HTTP/[0-9.]+ 404@ &&	# Fucking Vimeo...
              ++$error_count <= $max_errors) {
      my $s = int ($error_delay);
      print STDERR "$progname: ignoring 404 and retrying $url in $s...\n"
        if ($verbose > 1);
      sleep ($s);
      $error_delay = ($error_delay + 1) * 1.2;

    } else {
      return ($http, $head, $body, $url);
    }
  } while (1);
}


sub check_http_status($$$) {
  my ($url, $http, $err_p) = @_;
  return 1 if ($http =~ m@^HTTP/[0-9.]+ 20\d@si);
  errorI ("$http: $url") if ($err_p > 1 && $verbose);
  error  ("$http: $url") if ($err_p);
  return 0;
}


# Runs mplayer and/or ffmpeg to determine dimensions of the given video file.
# (We only do this if the metadata didn't include width and height).
#
sub video_file_size($) {
  my ($file) = @_;

  # Sometimes mplayer gets stuck in a loop.  
  # Don't let it run for more than N CPU-seconds.
  my $limit = "ulimit -t 10";

   my $size = (stat($file))[7];

  $file =~ s/(["`\$])/\\$1/gs;
  my $cmd = "mplayer -identify -frames 0 -vc null -vo null -ao null \"$file\"";

  $cmd = "$limit; $cmd";
  $cmd .= ' </dev/null';
  if ($verbose > 3) {
    $cmd .= ' 2>&1';
  } else {
    $cmd .= ' 2>/dev/null';
  }

  print STDERR "\n$progname: exec: $cmd\n" if ($verbose > 2);
  my $result = `$cmd`;
  print STDERR "\n$result\n" if ($verbose > 3);

  my ($w, $h) = (0, 0);
  if ($result =~ m/^VO:.*=> (\d+)x(\d+) /m) {
    ($w, $h) = ($1, $2);
  }


  # If mplayer failed to determine the video dimensions, try ffmpeg.
  #
  if (!$w) {
    $cmd = "ffmpeg -i \"$file\" -vframes 0 -f null /dev/null </dev/null 2>&1";
    print STDERR "\n$progname: mplayer failed to find dimensions." .
		 "\n$progname: exec: $cmd\n" if ($verbose > 2);
    $cmd = "$limit; $cmd";
    my $result = `$cmd`;
    print STDERR "\n$result\n" if ($verbose > 3);

    if ($result =~ m/^\s*Stream #.* Video:.* (\d+)x(\d+),? /m) {
      ($w, $h) = ($1, $2);
    }
  }

  return ($w, $h, $size);
}


# Downloads the first 200 KB of the URL, then runs mplayer to find out
# the dimensions of the video.
#
sub video_url_size($$$) {
  my ($title, $id, $url) = @_;

  my $file = sprintf ("%s/youtubedown.%08x",
                      ($ENV{TMPDIR} ? $ENV{TMPDIR} : "/tmp"),
                      rand(0xFFFFFFFF));
  unlink $file;

  my $bytes = 380 * 1024;	   # Need a lot of data to get size from HD

  my ($http, $head, $body) = get_url ($url, undef, undef, 0, $file, $bytes, 0);
  check_http_status ($url, $http, 2);  # internal error if still 403

  my ($ct) = ($head =~ m/^content-type:\s*([^\s;&]+)/mi);
  errorI ("$id: expected video, got \"$ct\" in $url")
    if ($ct =~ m/text/i);

  my ($size) = ($head =~ m/^content-length:\s*(\d+)/mi);
  $size = -1 unless defined($size); # WTF?

  my ($w, $h) = video_file_size ($file);
  unlink $file;

  return ($w, $h, $size);
}


# 24-Jun-2013: When use_cipher_signature=True, the signature must be
# translated from lengths ranging from 82 to 88 back down to the 
# original, unciphered length of 81 (40.40).
#
# This is not crypto or a hash, just a character-rearrangement cipher.
# Total security through obscurity.  Total dick move.
#
# The implementation of this cipher used by the Youtube HTML5 video
# player lives in a Javascript file with a name like:
#   http://s.ytimg.com/yts/jsbin/html5player-VERSION.js
# where VERSION changes periodically.  Sometimes the algorithm in the
# Javascript changes, also.  So we name each algorithm according to
# the VERSION string, and dispatch off of that.  Each time Youtube
# rolls out a new html5player file, we will need to update the
# algorithm accordingly.  See guess_cipher(), below.  Run this
# script with --guess if it has changed.  Run --guess --guess from
# cron to have it tell you only when there's a new cipher.
#
# So far, only three commands are used in the ciphers, so we can represent
# them compactly:
#
# - r  = reverse the string;
# - sN = slice from character N to the end;
# - wN = swap 0th and Nth character.
#
my %ciphers = (
  'vflNzKG7n' => 's3 r s2 r s1 r w67',   	    # 30 Jan 2013, untested
  'vfllMCQWM' => 's2 w46 r w27 s2 w43 s2 r',	    # 15 Feb 2013, untested
  'vflJv8FA8' => 's1 w51 w52 r',		    # 12 Mar 2013, untested
  'vflR_cX32' => 's2 w64 s3',			    # 11 Apr 2013, untested
  'vflveGye9' => 'w21 w3 s1 r w44 w36 r w41 s1',    # 02 May 2013, untested
  'vflj7Fxxt' => 'r s3 w3 r w17 r w41 r s2',	    # 14 May 2013, untested
  'vfltM3odl' => 'w60 s1 w49 r s1 w7 r s2 r',	    # 23 May 2013
  'vflDG7-a-' => 'w52 r s3 w21 r s3 r',  	    # 06 Jun 2013
  'vfl39KBj1' => 'w52 r s3 w21 r s3 r',  	    # 12 Jun 2013
  'vflmOfVEX' => 'w52 r s3 w21 r s3 r',  	    # 21 Jun 2013
  'vflJwJuHJ' => 'r s3 w19 r s2',		    # 25 Jun 2013
  'vfl_ymO4Z' => 'r s3 w19 r s2',		    # 26 Jun 2013
  'vfl26ng3K' => 'r s2 r',			    # 08 Jul 2013
  'vflcaqGO8' => 'w24 w53 s2 w31 w4',		    # 11 Jul 2013
  'vflQw-fB4' => 's2 r s3 w9 s3 w43 s3 r w23',      # 16 Jul 2013
  'vflSAFCP9' => 'r s2 w17 w61 r s1 w7 s1',         # 18 Jul 2013
  'vflART1Nf' => 's3 r w63 s2 r s1',                # 22 Jul 2013
  'vflLC8JvQ' => 'w34 w29 w9 r w39 w24',            # 25 Jul 2013
  'vflm_D8eE' => 's2 r w39 w55 w49 s3 w56 w2',      # 30 Jul 2013
  'vflTWC9KW' => 'r s2 w65 r',                      # 31 Jul 2013
  'vflRFcHMl' => 's3 w24 r',                        # 04 Aug 2013
  'vflM2EmfJ' => 'w10 r s1 w45 s2 r s3 w50 r',      # 06 Aug 2013
  'vflz8giW0' => 's2 w18 s3',                       # 07 Aug 2013
  'vfl_wGgYV' => 'w60 s1 r s1 w9 s3 r s3 r',        # 08 Aug 2013
  'vfl1HXdPb' => 'w52 r w18 r s1 w44 w51 r s1',     # 12 Aug 2013
  'vflkn6DAl' => 'w39 s2 w57 s2 w23 w35 s2',        # 15 Aug 2013
  'vfl2LOvBh' => 'w34 w19 r s1 r s3 w24 r',         # 16 Aug 2013
  'vfl-bxy_m' => 'w48 s3 w37 s2',                   # 20 Aug 2013
  'vflZK4ZYR' => 'w19 w68 s1',                      # 21 Aug 2013
  'vflh9ybst' => 'w48 s3 w37 s2',                   # 21 Aug 2013
  'vflapUV9V' => 's2 w53 r w59 r s2 w41 s3',        # 27 Aug 2013
  'vflg0g8PQ' => 'w36 s3 r s2',                     # 28 Aug 2013
  'vflHOr_nV' => 'w58 r w50 s1 r s1 r w11 s3',      # 30 Aug 2013
  'vfluy6kdb' => 'r w12 w32 r w34 s3 w35 w42 s2',   # 05 Sep 2013
  'vflkuzxcs' => 'w22 w43 s3 r s1 w43',             # 10 Sep 2013
  'vflGNjMhJ' => 'w43 w2 w54 r w8 s1',              # 12 Sep 2013
  'vfldJ8xgI' => 'w11 r w29 s1 r s3',               # 17 Sep 2013
  'vfl79wBKW' => 's3 r s1 r s3 r s3 w59 s2',        # 19 Sep 2013
  'vflg3FZfr' => 'r s3 w66 w10 w43 s2',             # 24 Sep 2013
  'vflUKrNpT' => 'r s2 r w63 r',                    # 25 Sep 2013
  'vfldWnjUz' => 'r s1 w68',                        # 30 Sep 2013
  'vflP7iCEe' => 'w7 w37 r s1',                     # 03 Oct 2013
  'vflzVne63' => 'w59 s2 r',                        # 07 Oct 2013
  'vflO-N-9M' => 'w9 s1 w67 r s3',                  # 09 Oct 2013
  'vflZ4JlpT' => 's3 r s1 r w28 s1',                # 11 Oct 2013
  'vflDgXSDS' => 's3 r s1 r w28 s1',                # 15 Oct 2013
  'vflW444Sr' => 'r w9 r s1 w51 w27 r s1 r',        # 17 Oct 2013
  'vflK7RoTQ' => 'w44 r w36 r w45',                 # 21 Oct 2013
  'vflKOCFq2' => 's1 r w41 r w41 s1 w15',           # 23 Oct 2013
  'vflcLL31E' => 's1 r w41 r w41 s1 w15',           # 28 Oct 2013
  'vflz9bT3N' => 's1 r w41 r w41 s1 w15',           # 31 Oct 2013
  'vfliZsE79' => 'r s3 w49 s3 r w58 s2 r s2',       # 05 Nov 2013
  'vfljOFtAt' => 'r s3 r s1 r w69 r',               # 07 Nov 2013
  'vflqSl9GX' => 'w32 r s2 w65 w26 w45 w24 w40 s2', # 14 Nov 2013
  'vflFrKymJ' => 'w32 r s2 w65 w26 w45 w24 w40 s2', # 15 Nov 2013
  'vflKz4WoM' => 'w50 w17 r w7 w65',                # 19 Nov 2013
  'vflhdWW8S' => 's2 w55 w10 s3 w57 r w25 w41',     # 21 Nov 2013
  'vfl66X2C5' => 'r s2 w34 s2 w39',                 # 26 Nov 2013
  'vflCXG8Sm' => 'r s2 w34 s2 w39',                 # 02 Dec 2013
  'vfl_3Uag6' => 'w3 w7 r s2 w27 s2 w42 r',         # 04 Dec 2013
  'vflQdXVwM' => 's1 r w66 s2 r w12',               # 10 Dec 2013
  'vflCtc3aO' => 's2 r w11 r s3 w28',               # 12 Dec 2013
  'vflCt6YZX' => 's2 r w11 r s3 w28',               # 17 Dec 2013
  'vflG49soT' => 'w32 r s3 r s1 r w19 w24 s3',      # 18 Dec 2013
  'vfl4cHApe' => 'w25 s1 r s1 w27 w21 s1 w39',      # 06 Jan 2014
  'vflwMrwdI' => 'w3 r w39 r w51 s1 w36 w14',       # 06 Jan 2014
  'vfl4AMHqP' => 'r s1 w1 r w43 r s1 r',            # 09 Jan 2014
  'vfln8xPyM' => 'w36 w14 s1 r s1 w54',             # 10 Jan 2014
  'vflVSLmnY' => 's3 w56 w10 r s2 r w28 w35',       # 13 Jan 2014
  'vflkLvpg7' => 'w4 s3 w53 s2',                    # 15 Jan 2014
  'vflbxes4n' => 'w4 s3 w53 s2',                    # 15 Jan 2014
  'vflmXMtFI' => 'w57 s3 w62 w41 s3 r w60 r',       # 23 Jan 2014
  'vflYDqEW1' => 'w24 s1 r s2 w31 w4 w11 r',        # 24 Jan 2014
  'vflapGX6Q' => 's3 w2 w59 s2 w68 r s3 r s1',      # 28 Jan 2014
  'vflLCYwkM' => 's3 w2 w59 s2 w68 r s3 r s1',      # 29 Jan 2014
  'vflcY_8N0' => 's2 w36 s1 r w18 r w19 r',         # 30 Jan 2014
  'vfl9qWoOL' => 'w68 w64 w28 r',                   # 03 Feb 2014
  'vfle-mVwz' => 's3 w7 r s3 r w14 w59 s3 r',       # 04 Feb 2014
  'vfltdb6U3' => 'w61 w5 r s2 w69 s2 r',            # 05 Feb 2014
  'vflLjFx3B' => 'w40 w62 r s2 w21 s3 r w7 s3',     # 10 Feb 2014
  'vfliqjKfF' => 'w40 w62 r s2 w21 s3 r w7 s3',     # 13 Feb 2014
  'ima-vflxBu-5R' => 'w40 w62 r s2 w21 s3 r w7 s3', # 13 Feb 2014
  'ima-vflrGwWV9' => 'w36 w45 r s2 r',              # 20 Feb 2014
  'ima-vflCME3y0' => 'w8 s2 r w52',                 # 27 Feb 2014
  'ima-vfl1LZyZ5' => 'w8 s2 r w52',                 # 27 Feb 2014
  'ima-vfl4_saJa' => 'r s1 w19 w9 w57 w38 s3 r s2', # 01 Mar 2014
  'ima-en_US-vflP9269H' => 'r w63 w37 s3 r w14 r',  # 06 Mar 2014
  'ima-en_US-vflkClbFb' => 's1 w12 w24 s1 w52 w70 s2',# 07 Mar 2014
  'ima-en_US-vflYhChiG' => 'w27 r s3',              # 10 Mar 2014
  'ima-en_US-vflWnCYSF' => 'r s1 r s3 w19 r w35 w61 s2',# 13 Mar 2014
  'en_US-vflbT9-GA' => 'w51 w15 s1 w22 s1 w41 r w43 r',# 17 Mar 2014
  'en_US-vflAYBrl7' => 's2 r w39 w43',              # 18 Mar 2014
  'en_US-vflS1POwl' => 'w48 s2 r s1 w4 w35',        # 19 Mar 2014
  'en_US-vflLMtkhg' => 'w30 r w30 w39',             # 20 Mar 2014
  'en_US-vflbJnZqE' => 'w26 s1 w15 w3 w62 w54 w22', # 24 Mar 2014
  'en_US-vflgd5txb' => 'w26 s1 w15 w3 w62 w54 w22', # 25 Mar 2014
  'en_US-vflTm330y' => 'w26 s1 w15 w3 w62 w54 w22', # 26 Mar 2014
  'en_US-vflnwMARr' => 's3 r w24 s2',               # 27 Mar 2014
  'en_US-vflTq0XZu' => 'r w7 s3 w28 w52 r',         # 31 Mar 2014
  'en_US-vfl8s5-Vs' => 'w26 s1 w14 r s3 w8',        # 01 Apr 2014
  'en_US-vfl7i9w86' => 'w26 s1 w14 r s3 w8',        # 02 Apr 2014
  'en_US-vflA-1YdP' => 'w26 s1 w14 r s3 w8',        # 03 Apr 2014
  'en_US-vflZwcnOf' => 'w46 s2 w29 r s2 w51 w20 s1',# 07 Apr 2014
  'en_US-vflFqBlmB' => 'w46 s2 w29 r s2 w51 w20 s1',# 08 Apr 2014
  'en_US-vflG0UvOo' => 'w46 s2 w29 r s2 w51 w20 s1',# 09 Apr 2014
  'en_US-vflS6PgfC' => 'w40 s2 w40 r w56 w26 r s2', # 10 Apr 2014
  'en_US-vfl6Q1v_C' => 'w23 r s2 w55 s2',           # 15 Apr 2014
  'en_US-vflMYwWq8' => 'w51 w32 r s1 r s3',         # 17 Apr 2014
  'en_US-vflGC4r8Z' => 'w17 w34 w66 s3',            # 24 Apr 2014
  'en_US-vflyEvP6v' => 's1 r w26',                  # 29 Apr 2014
  'en_US-vflm397e5' => 's1 r w26',                  # 01 May 2014
  'en_US-vfldK8353' => 'r s3 w32',                  # 03 May 2014
  'en_US-vflPTD6yH' => 'w59 s1 w66 s3 w10 r w55 w70 s1',# 06 May 2014
  'en_US-vfl7KJl0G' => 'w59 s1 w66 s3 w10 r w55 w70 s1',# 07 May 2014
  'en_US-vflhUwbGZ' => 'w49 r w60 s2 w61 s3',       # 12 May 2014
);

sub decipher_sig($$$) {
  my ($id, $cipher, $signature) = @_;

  return $signature unless defined ($cipher);

  my $orig = $signature;
  my @s = split (//, $signature);

  my $c = $ciphers{$cipher};
  if (! $c) {
    print STDERR "$progname: WARNING: $id: unknown cipher $cipher!\n"
      if ($verbose);
    $c = guess_cipher ($cipher);
  }

  $c =~ s/([^\s])([a-z])/$1 $2/gs;
  foreach my $c (split(/\s+/, $c)) {
    if    ($c eq '')           { }
    elsif ($c eq 'r')          { @s = reverse (@s);  }
    elsif ($c =~ m/^s(\d+)$/s) { @s = @s[$1 .. $#s]; }
    elsif ($c =~ m/^w(\d+)$/s) {
      my $a = 0;
      my $b = $1 % @s;
      ($s[$a], $s[$b]) = ($s[$b], $s[$a]);
    }
    else { errorI ("bogus cipher: $c"); }
  }

  $signature = join ('', @s);

  my $L1 = length($orig);
  my $L2 = length($signature);
  if ($verbose > 4 && $signature ne $orig) {
    print STDERR ("$progname: $id: translated sig, $cipher:\n" .
                  "$progname:  old: $L1: $orig\n" .
                  "$progname:  new: $L2: $signature\n");
  }

  return $signature;
}


# Total kludge that downloads the current html5player, parses the JavaScript,
# and intuits what the current cipher is.  Normally we go by the list of
# known ciphers above, but if that fails, we try and do it the hard way.
#
sub guess_cipher(;$$) {
  my ($cipher_id, $selftest_p) = @_;

  $verbose = 2 if ($verbose == 1 && !$selftest_p);


  my $url = "http://www.youtube.com/";
  my ($http, $head, $body);

  if (! $cipher_id) {
    ($http, $head, $body) = get_url ($url);		# Get home page
    check_http_status ($url, $http, 2);
    my ($id) = ($body =~ m@/watch\?v=([^\"\'/<>]+)@si);
    errorI ("unparsable cipher") unless $id;
    $url .= "/watch\?v=$id";

    ($http, $head, $body) = get_url ($url);		# Get random video
    check_http_status ($url, $http, 2);

    $body =~ s/\\//gs;
    ($cipher_id) = ($body =~ m@/jsbin\\?/html5player-(.+?)\.js@s);
    errorI ("unparsable cipher url: $url") unless $cipher_id;
  }

  $url = "http://s.ytimg.com/yts/jsbin/html5player-$cipher_id.js";
  ($http, $head, $body) = get_url ($url);
  check_http_status ($url, $http, 2);

  my ($date) = ($head =~ m/^Last-Modified:\s+(.*)$/mi);
  $date =~ s/^[A-Z][a-z][a-z], (\d\d? [A-Z][a-z][a-z] \d{4}).*$/$1/s;

  my $v = '[\$a-zA-Z][a-zA-Z\d]*';	# JS variable

  # Since the script is minimized and obfuscated, we can't search for
  # specific function names, since those change. Instead we match the
  # code structure.
  #
  # Note that the obfuscator sometimes does crap like y="split",
  # so a[y]("") really means a.split("")


  # Find "C" in this: var A = B.sig || C (B.s)
  my (undef, $fn) = ($body =~ m/$v = ( $v ) \.sig \|\| ( $v ) \( \1 \.s \)/sx);
  errorI ("$cipher_id: unparsable cipher js: $url") unless $fn;

  # Find body of function C(D) { ... }
  ($fn) = ($body =~ m@\b function \s+ $fn \s* \( $v \) \s* { ( .*? ) }@sx);
  errorI ("$cipher_id: unparsable fn") unless $fn;

  my $fn2 = $fn;

  # They inline the swapper if it's used only once.
  # Convert "var b=a[0];a[0]=a[63%a.length];a[63]=b;" to "a=swap(a,63);".
  $fn2 =~ s@
            var \s ( $v ) = ( $v ) \[ 0 \];
            \2 \[ 0 \] = \2 \[ ( \d+ ) % \2 \. length \];
            \2 \[ \3 \]= \1 ;
           @$2=swap($2,$3);@sx;

  my @cipher = ();
  foreach my $c (split (/\s*;\s*/, $fn2)) {
    if      ($c =~ m@^ ( $v ) = \1 . $v \(""\) $@sx) {         # A=A.split("");
    } elsif ($c =~ m@^ ( $v ) = \1 .  $v \(\)  $@sx) {         # A=A.reverse();
      push @cipher, "r";
    } elsif ($c =~ m@^ ( $v ) = \1 . $v \( (\d+) \) $@sx) {    # A=A.slice(N);
      push @cipher, "s$2";
    } elsif ($c =~ m@^ ( $v ) = $v \( \1 , ( \d+ ) \) $@sx) {  # A=swap(A,N);
      push @cipher, "w$2";
    } elsif ($c =~ m@^ return \s+ $v \. $v \(""\) $@sx) { # return A.join("");
    } else {
      errorI ("$cipher_id: unparsable: $c\n\tin: $fn");
    }
  }
  my $cipher = join(' ', @cipher);

  if ($selftest_p) {
    return $cipher if defined($ciphers{$cipher_id});
    $verbose = 2 if ($verbose < 2);
  }

  if ($verbose > 1) {
    my $c2 = "  '$cipher_id' => '$cipher',";
    $c2 = sprintf ("%-52s# %s", $c2, $date);
    auto_update($c2) if ($selftest_p && $selftest_p == 2);
    print STDERR "$progname: current cipher is:\n$c2\n";
  }

  return $cipher;
}


# Tired of doing this by hand. Crontabbed self-modifying code!
#
sub auto_update($) {
  my ($cipher_line) = @_;

  open (my $in, '<', $progname0) || error ("$progname0: $!");
  local $/ = undef;  # read entire file  
  my ($body) = <$in>;
  close $in;

  $body =~ s@(\nmy %ciphers = .*?)(\);)@$1$cipher_line\n$2@s ||
    error ("auto-update: unable to splice");

  # Since I'm not using CVS any more, also update the version number.
  $body =~ s@([\$]Revision:\s+\d+\.)(\d+)(\s+[\$])@
             { $1 . ($2 + 1) . $3 }@sexi ||
    error ("auto-update: unable to tick version");

  open (my $out, '>', $progname0) || error ("$progname0: $!");
  print $out $body;
  close $out;
  print STDERR "$progname: auto-updated $progname0\n";

  my ($dir) = $ENV{HOME} . '/www/hacks';
  system ("cd '$dir'" .
          " && git commit -q -m 'cipher auto-update' '$progname'" .
          " && git push -q");
}


# For verifying that decipher_sig() implements exactly the same transformation
# that the JavaScript implementations do.
#
sub decipher_selftest() {
  my $tests = {
   'UNKNOWN 88' . "\t" .
   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGHIJ.' .		# 88
   'LMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvw' =>
   'Pqponmlkjihgfedrba`_u]\\[ZYXWVUTSRQcONML.' .
   'JIHGFEDCBA@?>=<;:9876543210/x-#+*)(\'&%$",',

   'vflmOfVEX' . "\t" .
   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGHIJ.' .		# 87
   'LMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuv' =>
   '^rqponmlkjihgfedcba`_s]\\[ZYXWVU SRQPONML.' .
   'JIHGFEDCBA@?>=<;:9876543210/x-,+*)(\'&%$#',

   'vfl_ymO4Z' . "\t" .
   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGHI.' .		# 86
   'KLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstu' =>
   '"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGHI.' .
   'KLMNOPQRSTUVWXYZ[\]^r`abcdefghijklmnopq_',

   'vfltM3odl' . "\t" .
   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGHI.' .		# 85
   'KLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrst' =>
   'lrqponmskjihgfedcba`_^] [ZYXWVUTS!QPONMLK.' .
   'IHGFEDCBA@?>=<;:9876543210/x-,+*)(\'&%$#',

   'UNKNOWN 84' . "\t" .
   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGH.' .		# 84
   'JKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrs' =>
   'srqponmlkjihgfedcba`_^]\\[ZYXWVUTSRQPONMLKJ.' .
   'HGFE"CBA@?>=<;#9876543210/x-,+*)(\'&%$:',

   'UNKNOWN 83' . "\t" .
   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGH.' .		# 83
   'JKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqr' =>
   'Tqponmlkjihgfedcba`_^]\\[ZYX"VUrSRQPONMLKJ.' .
   'HGFEWCBA@?>=<;:9876543210/x-,+*)(\'&%$#D',

   'UNKNOWN 82' . "\t" .
   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFG.' .		# 82
   'IJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopq' =>
   'Donmlkjihgfedqba`_^]\\[ZYXWVUTSRQPONMLKJIAGFE.' .
   'C c@?>=<;:9876543210/x-,+*)(\'&%$#"!B',

   'vflmOfVEX' . "\t" .
   '5AEEAE0EC39677BC65FD9021CCD115F1F2DBD5A59E4.' .		# Real examples
   'C0B243A3E2DED6769199AF3461781E75122AE135135' =>		# 87
   '931EA22157E1871643FA9519676DED253A342B0C.' .
   '4E95A5DBD2F1F511DCC1209DF56CB77693CE0EAE',

   'vflmOfVEX' . "\t" .
   '7C03C0B9B947D9DCCB27CD2D1144BA8F91B7462B430.' .		# 87
   '8CFE5FA73DDE66DCA33BF9F902E09B160BC42924924' =>
   '32924CB061B90E209F9FB43ACD66EDD77AF5EFC8.' .
   '034B2647B19F8AB4411D2DC72BCCD9D749B9B0C3',

   'vflmOfVEX' . "\t" .
   '38A48AA6FAC88C2240DEBE5F74F4E62DC1F0828E990.' .		# 87
   '53B824774161BD7CE735CA84963AA17B002D1901901' =>
   '3091D200B71AA36948AC517EC7DB161377428B35.' .
   '099E8280F1CD26E4F47F5EBED0422C88CAF6AA84',

   # This one seems to be used by "content restricted" videos?
   'vfl_ymO4Z' . "\t" .
   '7272B1BA35548BA3939F9CE39C4E72A98BB78ABB28.' .		# 86
   '560A7424D42FF070C115935232F8BDB8A1F3E05C05C' =>
   '72B1BA35548BA3939F9CE39C4E72A98BB78ABB28.' .
   '560A7424D42FF070C115C35232F8BDB8A1F3E059',

   'vflmOfVEX' . "\t" .
   'CFDEFDEBFC25C1BA6E940A10E4ED8326FD4EDDD0B1A.' .   # 87 from "watch?v="
   '22F7E77BE9637FBE657ED4FDE0DEE96F06CB011D11D' =>
#  '61661661658E036DF1B58C21783028FE116E7DB7C62B.' .  # corresponding sig
#  'D225BE11FBCBD59C62F163A57BF8EC1B47897485E85E' =>  # from "get_video_info"
   '7110BC60F69EED0EDF4DED56EBF7369CB77E7F22.' .
   'A1B0DDDE4DF6238DE4E01A049E6AB1C52CFBEDFE',
  };

  my %verified;
  foreach my $key (sort { my ($aa, $bb) = ($a, $b);
                          foreach ($aa, $bb) { s/^.*?\t//s; }
                          length($aa) == length($bb)
                          ? $aa cmp $bb
                          : length($aa) <=> length($bb) }
                   keys (%$tests)) {
    my $expect = $tests->{$key};
    my ($cipher, $sig) = split (/\t/, $key);
    my $id = $cipher . " " . length ($sig);
    my $got = decipher_sig ($id, $cipher, $sig);
    my $L2 = length ($got);
    if ($expect eq $got) {
      my $v = ($key !~ m/ABCDEF/s);
      print STDERR "$id: OK ($L2) $got\n";
      $verified{$id} = $verified{$id} || $v;
    }
    else { print STDERR "$id: FAIL: $got\n"; }
  }
  my @un = ();
  foreach my $k (sort (keys %verified)) {
    push @un, $k unless $verified{$k};
  }
  print STDERR "Unverified: " . join(', ', @un) . "\n";
}

#decipher_selftest(); exit();




# Example URLs that have use_cipher_signature=True:
#
# http://www.youtube.com/watch?v=ktoaj1IpTbw  Chvrches
# http://www.youtube.com/watch?v=ttqMGYHhFFA  Metric
# http://www.youtube.com/watch?v=28Vu8c9fDG4  Emika
# http://www.youtube.com/watch?v=_mDxcDjg9P4  Vampire Weekend
# http://www.youtube.com/watch?v=8UVNT4wvIGY  Gotye
# http://www.youtube.com/watch?v=OhhOU5FUPBE  Black Sabbath
# http://www.youtube.com/watch?v=1ltcDfZMA3U  Maps
# http://www.youtube.com/watch?v=UxxajLWwzqY  Icona Pop
#
# This video is both enciphered and "content warning", so we can't download it.
# Update: it is no longer "content warning". It used to be but it changed!
# http://www.youtube.com/watch?v=7wL9NUZRZ4I  Bowie
# Here's one we can't download:
# http://www.youtube.com/watch?v=07FYdnEawAQ Timberlake


# Replace the signature in the URL, deciphering it first if necessary.
#
sub apply_signature($$$$$) {
  my ($id, $fmt, $url, $cipher, $sig) = @_;
  if ($sig) {
    if (defined ($cipher)) {
      my $o = $sig;
      $sig = decipher_sig ("$id/$fmt", $cipher, $sig);
      if ($o ne $sig) {
        my $n = $sig;
        my ($a, $b) = split(/\./, $o);
        my ($c, $d) = split(/\./, $sig);
        ($a, $b) = ($o,   '') unless defined($b);
        ($c, $d) = ($sig, '') unless defined($d);
        my $L1 = sprintf("%d %d.%d", length($o),   length($a), length($b));
        my $L2 = sprintf("%d %d.%d", length($sig), length($c), length($d));
        foreach ($o, $n) { s/\./.\n          /gs; }
        my $s = "cipher:   $cipher\n$L1: $o\n$L2: $n";
        $error_whiteboard .= "\n" if $error_whiteboard;
        $error_whiteboard .= "$fmt:       " .
                             "http://www.youtube.com/watch?v=$id\n$s";
        if ($verbose > 1) {
          print STDERR "$progname: $id: deciphered and replaced signature\n";
          $s =~ s/^([^ ]+)(  )/$2$1/s;
          $s =~ s/^/$progname:    /gm;
          print STDERR "$s\n";
        }
      }
    }
    $url =~ s@&signature=[^&]+@@gs;
    $url .= '&signature=' . $sig;
  }
  return $url;
}


# Parses the video_info XML page and returns several values:
# - the content type and underlying URL of the video itself;
# - title, if known
# - year, if known
# - width and height, if known
# - size in bytes, if known
#
sub scrape_youtube_url($$$$$) {
  my ($url, $id, $title, $size_p, $force_fmt) = @_;

  my $info_url = ("http://www.youtube.com/get_video_info?video_id=$id" .
                  "&el=vevo");	# Needed for VEVO, works on non-VEVO.
  # Maybe these instead of Vevo?
  # '&el=detailpage' .
  # '&ps=default' .
  # '&eurl=' .
  # '&gl=US' .
  # '&hl=en'

  my ($kind, $urlmap, $body, $fmtlist, $rental);

  my $retries = 5;
  my $err = undef;

  while (--$retries) {	# Sometimes the $info_url fails; try a few times.

    my ($http, $head);
    ($http, $head, $body) = get_url ($info_url);
    $err = (check_http_status ($url, $http, 0) ? undef : $http);

    ($kind, $urlmap) = ($body =~ m@&(fmt_url_map)=([^&]+)@si);
    ($kind, $urlmap) = ($body =~ m@&(fmt_stream_map)=([^&]+)@si)	# VEVO
      unless $urlmap;
    ($kind, $urlmap) = ($body =~ m@&(url_encoded_fmt_stream_map)=([^&]+)@si) 
      unless $urlmap;			   # New nonsense seen in Aug 2011
    print STDERR "$progname: $id: found $kind in JSON\n"
      if ($kind && $verbose > 1);

    ($fmtlist) = ($body =~ m@&fmt_list=([^&]+)@si);
    ($title)   = ($body =~ m@&title=([^&]+)@si) unless $title;
    ($rental)  = ($body =~ m@&ypc_video_rental_bar_text=([^&]+)@si);

    last if ($urlmap && $title);

    if ($verbose) {
      if (!$urlmap) {
        print STDERR "$progname: $id: no urlmap, retrying...\n";
      } else {
        print STDERR "$progname: $id: no title, retrying...\n";
      }
    }

    sleep (1);
  }

  $err = "can't download rental videos"
    if (!$err && !$urlmap && $rental);

  error ("$progname: $id: $err")
    if $err;

  # The "use_cipher_signature" parameter is as lie: it is sometimes true
  # even when the signatures are not enciphered.  The only way to tell
  # is if the URLs in the map contain "s=" instead of "sig=".
  #
  # If the urlmap from get_video_info has an enciphered signature,
  # we have no way of knowing what cipher is in use!  So in that case
  # we need to scrape the HTML, since from there we can pull the
  # cipher ID out of the Javascript.
  #
  # This is, in fact, utter lunacy.
  #
  # Shitty side effect: it's not possible to download enciphered
  # videos that are marked as "adults only", since in that case the
  # HTML doesn't contain the url_map.  The url_map is in get_video_info,
  # but those signatures don't work.

  if (!$urlmap) {
    # If we couldn't get a URL map out of the info URL, try harder.

    if ($body =~ m/private[+\s]video|video[+\s]is[+\s]private/si) {
      error ("$id: private video");  # scraping won't work.
    }

    my ($err) = ($body =~ m@reason=([^&]+)@s);
    $err = '' unless $err;
    if ($err) {
      $err = url_unquote($err);
      $err =~ s/^"[^\"\n]+"\n//s;
      $err =~ s/\s+/ /gs;
      $err =~ s/^\s+|\s+$//s;
      $err = " (\"$err\")";
    }

    print STDERR "$progname: $id: no fmt_url_map$err.  Scraping HTML...\n"
      if ($verbose > 1);

    return scrape_youtube_url_html ($url, $id, $size_p, $force_fmt, $err);
  }

  $urlmap  = url_unquote ($urlmap);
  $fmtlist = url_unquote ($fmtlist || '');

  ($title) = ($body =~ m@&title=([^&]+)@si) unless $title;
  errorI ("$id: no title in $info_url") unless $title;
  $title = url_unquote($title);

  my $cipher = undef; # initially assume signature is not enciphered
  my $year   = undef; # no published date in get_video_info
  return scrape_youtube_url_2 ($id, $urlmap, $fmtlist, $cipher, $title, $year,
                               $size_p, $force_fmt);
}


# Return the year at which this video was uploaded.
#
sub get_youtube_year($) {
  my ($id) = @_;
  my $data_url = ("http://gdata.youtube.com/feeds/api/videos/$id?v=2" .
                  "&fields=published" .
                  "&safeSearch=none" .
                  "&strict=true");
  my ($http, $head, $body) = get_url ($data_url, undef, undef, 0, undef);
  return undef unless check_http_status ($data_url, $http, 0);

  my ($year, $mon, $dotm, $hh, $mm, $ss) = 
    ($body =~ m@<published>(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)@si);
  return $year;
}


# Return the year at which this video was uploaded.
#
sub get_vimeo_year($) {
  my ($id) = @_;
  my $data_url = "http://vimeo.com/api/v2/video/$id.xml";
  my ($http, $head, $body) = get_url ($data_url, undef, undef, 0, undef);
  return undef unless check_http_status ($data_url, $http, 0);

  my ($year, $mon, $dotm, $hh, $mm, $ss) = 
    ($body =~ m@<upload_date>(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)@si);
  return $year;
}



# This version parses the HTML instead of get_video_info.
# We need to do that for "embedding disable" videos,
# and for videos that have enciphered signatures.
#
sub scrape_youtube_url_html($$$$$) {
  my ($url, $id, $size_p, $force_fmt, $oerror) = @_;

  my ($http, $head, $body) = get_url ($url);

  my $unquote_p = 1;
  my ($args) = ($body =~ m@'SWF_ARGS' *: *{(.*?)}@s);

  if (! $args) {    # Sigh, new way as of Apr 2010...
    ($args) = ($body =~ m@var swfHTML = [^\"]*\"(.*?)\";@si);
    $args =~ s@\\@@gs if $args;
    ($args) = ($args =~ m@<param name="flashvars" value="(.*?)">@si) if $args;
    ($args) = ($args =~ m@fmt_url_map=([^&]+)@si) if $args;
    $args = "\"fmt_url_map\": \"$args\"" if $args;
  }
  if (! $args) {    # Sigh, new way as of Aug 2011...
    ($args) = ($body =~ m@'PLAYER_CONFIG':\s*{(.*?)}@s);
    $args =~ s@\\u0026@&@gs if $args;
    $unquote_p = 0;
  }
  if (! $args) {    # Sigh, new way as of Jun 2013...
    ($args) = ($body =~ m@ytplayer\.config\s*=\s*{(.*?)};@s);
    $args =~ s@\\u0026@&@gs if $args;
    $unquote_p = 1;
  }

  my $blocked_re = join ('|',
                         ('(available|blocked it) in your country',
                          'copyright (claim|grounds)',
                          'removed by the user',
                          'is not available'));

  if (! $args) {
    # Try to find a better error message
    my (undef, $err) = ($body =~ m@<( div | h1 ) \s+
                                    (?: id | class ) = 
                                   "(?: error-box |
                                        yt-alert-content |
                                        unavailable-message )"
                                   [^<>]* > \s* 
                                   ( [^<>]+? ) \s*
                                   </ \1 > @six);
    $err = "Rate limited: CAPCHA required"
      if (!$err && $body =~ m/large volume of requests/);
    if ($err) {
      my ($err2) = ($body =~ m@<div class="submessage">(.*?)</div>@si);
      if ($err2) {
        $err2 =~ s@<button.*$@@s;
        $err2 =~ s/<[^<>]*>//gs;
        $err .= ": $err2";
      }
      $err =~ s/^"[^\"\n]+"\n//s;
      $err =~ s/^&quot;[^\"\n]+?&quot;\n//s;
      $err =~ s/\s+/ /gs;
      $err =~ s/^\s+|\s+$//s;
      $err =~ s/\.(: )/$1/gs;
      $err =~ s/\.$//gs;

      my ($title) = ($body =~ m@<title>\s*(.*?)\s*</title>@si);
      if ($title) {
        $title = munge_title (url_unquote ($title));
        $err = "$err ($title)";
      }

      $oerror = $err;
      $http = 'HTTP/1.0 404';
    }
  }

  if ($verbose == 0 && $oerror =~ m/$blocked_re/sio) {
    # With --quiet, just silently ignore country-locked video failures,
    # for "youtubefeed".
    exit (0);
  }

  # Sometimes Youtube returns HTTP 404 pages that have real messages in them,
  # so we have to check the HTTP status late. But sometimes it doesn't return
  # 404 for pages that no longer exist. Hooray.

  $http = 'HTTP/1.0 404'
    if ($oerror && $oerror =~ m/$blocked_re/sio);
  error ("$id: $http$oerror")
    unless (check_http_status ($url, $http, 0));
  errorI ("$id: no ytplayer.config$oerror")
    unless $args;

  my ($kind, $urlmap) = ($args =~ m@"(fmt_url_map)": "(.*?)"@s);
  ($kind, $urlmap) = ($args =~ m@"(fmt_stream_map)": "(.*?)"@s)	    # VEVO
    unless $urlmap;
  ($kind, $urlmap) = ($args =~ m@"(url_encoded_fmt_stream_map)": "(.*?)"@s)
    unless $urlmap;			   # New nonsense seen in Aug 2011
  if (! $urlmap) {
    if ($body =~ m/This video has been age-restricted/s) {
      error ("$id: enciphered but age-restricted$oerror");
    }
    errorI ("$id: no fmt_url_map$oerror");
  }
  print STDERR "$progname: $id: found $kind in HTML\n"
    if ($kind && $verbose > 1);

  my ($cipher) = ($body =~ m@/jsbin\\?/html5player-(.+?)\.js@s);

  my ($fmtlist) = ($args =~ m@"fmt_list": "(.*?)"@s);
  $fmtlist =~ s/\\//g if $fmtlist;

  $fmtlist = url_unquote ($fmtlist || '');

  my ($title) = ($body =~ m@<title>\s*(.*?)\s*</title>@si);
  $title = munge_title (url_unquote ($title));

  my $year = $1   # might be a published date in the HTML.
    if ($body =~ m@<SPAN \b [^<>]* ID=[\'\"]eow-date[\'\"] [^<>]* >
                   [^<>]* \b ( \d{4} ) \s* <@gsix);

  return scrape_youtube_url_2 ($id, $urlmap, $fmtlist, $cipher, $title, $year,
                               $size_p, $force_fmt);
}


# Parses the given fmt_url_map to determine the preferred URL of the
# underlying Youtube video.
#
sub scrape_youtube_url_2($$$$$$$$$) {
  my ($id, $urlmap, $fmtlist, $cipher, $title, $year, $size_p,
      $force_fmt) = @_;

  print STDERR "\n$progname: urlmap:\n" if ($verbose > 3);

  my $url;
  my %urlmap;
  my %urlct;
  my %urlsig;
  my @urlmap;
  my %fmtsizes;

  foreach (split (/,/, $fmtlist)) {
    my ($fmt, $size, $a, $b, $c) = split(/\//);  # What are A, B, and C?
    $fmtsizes{$fmt} = $size;
  }

  foreach (split (/,/, $urlmap)) {
    # Format used to be: "N|url,N|url,N|url"
    # Now it is: "url=...&quality=hd720&fallback_host=...&type=...&itag=N"
    my ($k, $v, $e, $sig, $sig2);
    if (m/^\d+\|/s) {
      ($k, $v) = m/^(.*?)\|(.*)$/s;
    } elsif (m/^[a-z][a-z\d_]*=/s) {

      ($sig)  = m/\bsig=([^&]+)/s;	# sig= when un-ciphered.
      ($sig2) = m/\bs=([^&]+)/s;	# s= when enciphered.

      ($k) = m/\bitag=(\d+)/s;
      ($v) = m/\burl=([^&]+)/s;
      $v = url_unquote($v) if ($v);

      my ($q) = m/\bquality=([^&]+)/s;
      my ($t) = m/\btype=([^&]+)/s;
      $e = "\t$q, $t" if ($q && $t);
      $e = url_unquote($e) if ($e);
    }

    error ("$id: RTMPE DRM: not supported")
      if (!$v && $urlmap =~ m/rtmpe(=|%3D)yes/s);	# Well, fuck.

    errorI ("$id: unparsable urlmap entry: no itag: $_") unless ($k);
    errorI ("$id: unparsable urlmap entry: no url: $_")  unless ($v);

    my ($ct) = ($e =~ m@\bvideo/(?:x-)?([a-z\d]+)\b@si);

    my $s = $fmtsizes{$k};
    $s = '?x?' unless $s;

    $v =~ s/^https:/http:/s;

    $urlmap{$k} = $v;
    $urlct{$k}  = $ct;
    $urlsig{$k} = [ $sig2 ? 1 : 0, $sig || $sig2 ];

    push @urlmap, $k;
    print STDERR "\t\t$k $s\t$v$e\n" if ($verbose > 3);
  }

  print STDERR "\n" if ($verbose > 3);


  # If we're doing all formats, iterate them here now that we know which
  # ones are available. This ends up parsing things multiple times.
  #
  if (defined($force_fmt) && $force_fmt eq 'all') {
    foreach my $fmt (sort { $a <=> $b } @urlmap) {
      my $url = "http://www.youtube.com/v/$id";
      my $x = $fmt . "/" . $urlct{$fmt};
      $append_suffix_p = $x;
      download_video_url ($url, $title, $year,
                          ($size_p ? $append_suffix_p : 0),
                          undef, 0, $fmt);
    }
    exit (0);
  }

  #
  # fmt    video codec           video size               audio codec
  # --- -------------------  -------------------  ---------------------------
  #
  #  0  FLV h.263  251 Kbps  320x180  29.896 fps  MP3  64 Kbps  1ch 22.05 KHz
  #  5  FLV h.263  251 Kbps  320x180  29.896 fps  MP3  64 Kbps  1ch 22.05 KHz
  #  5* FLV h.263  251 Kbps  320x240  29.896 fps  MP3  64 Kbps  1ch 22.05 KHz
  #  6  FLV h.263  892 Kbps  480x270  29.887 fps  MP3  96 Kbps  1ch 44.10 KHz
  # 13  3GP h.263   77 Kbps  176x144  15.000 fps  AMR  13 Kbps  1ch  8.00 KHz
  # 17  3GP  xVid   55 Kbps  176x144  12.000 fps  AAC  29 Kbps  1ch 22.05 KHz
  # 18  MP4 h.264  505 Kbps  480x270  29.886 fps  AAC 125 Kbps  2ch 44.10 KHz
  # 18* MP4 h.264  505 Kbps  480x360  24.990 fps  AAC 125 Kbps  2ch 44.10 KHz
  # 22  MP4 h.264 2001 Kbps 1280x720  29.918 fps  AAC 198 Kbps  2ch 44.10 KHz
  # 34  FLV h.264  256 Kbps  320x180  29.906 fps  AAC  62 Kbps  2ch 22.05 KHz
  # 34* FLV h.264  593 Kbps  320x240  25.000 fps  AAC  52 Kbps  2ch 22.05 KHz
  # 34* FLV h.264  593 Kbps  640x360  30.000 fps  AAC  52 Kbps  2ch 22.05 KHz
  # 35  FLV h.264  831 Kbps  640x360  29.942 fps  AAC 107 Kbps  2ch 44.10 KHz
  # 35* FLV h.264 1185 Kbps  854x480  30.000 fps  AAC 107 Kbps  2ch 44.10 KHz
  # 36  3GP h.264  191 Kbps  320x240  29.970 fps  AAC  37 Kbps  1ch 22.05 KHz
  # 37  MP4 h.264 3653 Kbps 1920x1080 29.970 fps  AAC 128 Kbps  2ch 44.10 KHz
  # 38  MP4 h.264 6559 Kbps 4096x2304 23.980 fps  AAC 128 Kbps  2ch 48.00 KHz
  # 43  WebM vp8   481 Kbps  480x360  30.000 fps  Vorbis ?Kbps  2ch 44.10 KHz
  # 44  WebM vp8   756 Kbps  640x480  30.000 fps  Vorbis ?Kbps  2ch 44.10 KHz
  # 45  WebM vp8  2124 Kbps 1280x720  30.000 fps  Vorbis ?Kbps  2ch 44.10 KHz
  # 46  WebM vp8  4676 Kbps 1920x540 stereo wide  Vorbis ?Kbps  2ch 44.10 KHz
  # 59  MP4 h.264  743 Kbps  854x480  25.000 fps  AAC 128 Kbps  2ch 48.00 KHz
  # 78  MP4 h.264  611 Kbps  720x406  25.000 fps  AAC 128 Kbps  2ch 48.00 KHz
  # 82  MP4 h.264  926 Kbps  640x360 stereo       AAC 128 Kbps  2ch 44.10 KHz
  # 83  MP4 h.264  934 Kbps  854x240 stereo       AAC 128 Kbps  2ch 44.10 KHz
  # 84  MP4 h.264 3190 Kbps 1280x720 stereo       AAC 198 Kbps  2ch 44.10 KHz
  # 85  MP4 h.264 3862 Kbps 1920x520 stereo wide  AAC 198 Kbps  2ch 44.10 KHz
  # 100 WebM vp8   357 Kbps  640x360 stereo       Vorbis ?Kbps  2ch 44.10 KHz
  # 101 WebM vp8   870 Kbps  854x480 stereo       Vorbis ?Kbps  2ch 44.10 KHz
  # 102 WebM vp8   864 Kbps 1280x720 stereo       Vorbis ?Kbps  2ch 44.10 KHz
  # 120  FLV AVC     ?      1280x720              AAC   ? Kbps  ?       ? KHz
  # 133 MP4 h.264    ?          240p       ? fps     video only
  # 134 MP4 h.264    ?          360p       ? fps     video only
  # 135 MP4 h.264    ?          480p       ? fps     video only
  # 136 MP4 h.264    ?      1280x720       ? fps     video only
  # 137 MP4 h.264    ?     1920x1080       ? fps     video only
  # 138 ?
  # 139 MP4 h.264    ?    audio only               ?     "low"  ?       ? KHz
  # 140 MP4 h.264    ?    audio only               ?     "med"  ?       ? KHz
  # 141 MP4 h.264    ?    audio only               ?     "high" ?       ? KHz
  # 160 MP4 h.264    ?          144p       ? fps   ?    ? Kbps  ?       ? KHz
  #
  # fmt=38/37/22 are only available if upload was that exact resolution.
  #
  # For things uploaded in 2009 and earlier, fmt=18 was higher resolution
  # than fmt=34.  But for things uploaded later, fmt=34 is higher resolution.
  # This code assumes that 34 is the better of the two.
  #
  # The WebM formats 43, 44 and 45 began showing up around Jul 2011.
  # The MP4 versions are higher resolution (e.g. 37=1080p but 45=720p).
  #
  # The stereo/3D formats 46, 82-84, 100-102 first spotted in Sep/Nov 2011.
  #
  # For debugging this stuff, use "--fmt N" to force downloading of a
  # particular format or "--fmt all" to grab them all.
  #
  #
  # Test cases and examples:
  #
  #   http://www.youtube.com/watch?v=wjzyv2Q_hdM
  #   5-Aug-2011: 38=flv/1080p but 45=webm/720p.
  #   6-Aug-2011: 38 no longer offered.
  #
  #   http://www.youtube.com/watch?v=ms1C5WeSocY
  #   6-Aug-2011: embedding disabled, but get_video_info works.
  #
  #   http://www.youtube.com/watch?v=g40K0dFi9Bo
  #   10-Sep-2011: 3D, fmts 82 and 84.
  #
  #   http://www.youtube.com/watch?v=KZaVq1tFC9I
  #   14-Nov-2011: 3D, fmts 100 and 102.  This one has 2D images in most
  #   formats but left/right images in the 3D formats.
  #
  #   http://www.youtube.com/watch?v=SlbpRviBVXA
  #   15-Nov-2011: 3D, fmts 46, 83, 85, 101.  This one has left/right images
  #   in all of the formats, even the 2D formats.
  #
  #   http://www.youtube.com/watch?v=711bZ_pLusQ
  #   30-May-2012: First sighting of fmt 36, 3gpp/240p.
  #
  #   http://www.youtube.com/watch?v=0yyorhl6IjM
  #   30-May-2013: Here's one that's more than an hour long.
  #
  #   http://www.youtube.com/watch?v=pc4ANivCCgs
  #   15-Nov-2013: First sighting of formats 59 and 78.
  #
  # The table on http://en.wikipedia.org/wiki/YouTube#Quality_and_codecs
  # disagrees with the above to some extent.  Which is more accurate?
  #

  my %known_formats  = (   0 => 1,   5 => 1,   6 => 1,  13 => 1,  17 => 1,
                          18 => 1,  22 => 1,  34 => 1,  35 => 1,  36 => 1,
                          37 => 1,  38 => 1,  43 => 1,  44 => 1,  45 => 1,
                          46 => 1,  59 => 1,  78 => 1,  82 => 1,  83 => 1,
                          84 => 1, 85 => 1,  100 => 1, 101 => 1, 102 => 1,
                       );
  my @preferred_fmts = ( 38,  # huge mp4
                         37,  # 1080 mp4
                         22,  #  720 mp4
                         45,  #  720 webm
                         59,  #  480 mp4
                         35,  #  480 flv
                         44,  #  480 webm
                         78,  #  406 mp4
                         34,  #  360 flv, mostly
                         18,  #  360 mp4, mostly
                       );
  my $fmt;
  foreach my $k (@preferred_fmts) {
    $fmt = $k;
    $url = $urlmap{$fmt};
    last if defined($url);
  }

  # If none of our preferred formats are available, use first one in the list.
  if (! defined($url)) {
    $fmt = $urlmap[0];
    $url = $urlmap{$fmt};
  }

  my $how = 'picked';
  if (defined($force_fmt)) {
    $how = 'forced';
    $fmt = $force_fmt;
    $url = $urlmap{$fmt};
    error ("$id: fmt $fmt does not exist") unless $url;
  }

  print STDERR "$progname: $id: available formats: " . 
    join(', ', @urlmap) . "; $how $fmt.\n"
      if ($verbose > 1);


  # If there is a format in the list that we don't know about, warn.
  # This is the only way I have of knowing when new ones turn up...
  #
  my @unk = ();
  foreach my $k (@urlmap) {
    push @unk, $k if (!$known_formats{$k});
  }
  print STDERR "$progname: $id: unknown format " . join(', ', @unk) .
               "$errorI\n"
      if (@unk);

  $url =~ s@^.*?\|@@s;  # VEVO

  my ($wh) = $fmtsizes{$fmt};
  my ($w, $h) = ($wh =~ m/^(\d+)x(\d+)$/s) if $wh;
  ($w, $h) = ();  # Turns out these are full of lies.


  # If the signature is enciphered, we need to scrape HTML instead, to
  # get the cipher algorithm.

  my $sig = $urlsig{$fmt};
  if ($sig->[0]) {  # enciphered
    if (! $cipher) {
      print STDERR "$progname: $id: enciphered. Scraping HTML...\n"
        if ($verbose > 1);
      $url = 'http://www.youtube.com/watch?v=' . $id;
      return scrape_youtube_url_html ($url, $id, $size_p, $force_fmt, '');
    }
  }

  # Now that we have chosen a URL, make sure it has a signature.
  $url = apply_signature ($id, $fmt, $url, 
                          $sig->[0] ? $cipher : undef,
                          $sig->[1]);


  # We need to do a HEAD on the video URL to find its size in bytes,
  # and the content-type for the file name.
  #
  my ($http, $head, $body);
  ($http, $head, $body, $url) = get_url ($url, undef, undef, 1);
  check_http_status ($url, $http, 2);  # internal error if still 403
  my ($ct)   = ($head =~ m/^content-type:\s*([^\s;]+)/mi);
  my ($size) = ($head =~ m/^content-length:\s*(\d+)/mi);

  errorI ("couldn't find video for $url") unless $ct;

  return ($ct, $url, $title, $year, $w, $h, $size);
}


# Parses the HTML and returns several values:
# - the content type and underlying URL of the video itself;
# - title, if known
# - year, if known
# - width and height, if known
# - size in bytes, if known
#
sub scrape_vimeo_url($$) {
  my ($url, $id) = @_;

  # Vimeo's New Way, May 2012.

  my $info_url = "http://vimeo.com/$id?action=download";
  my $referer = $url;
  my $hdrs = ("X-Requested-With: XMLHttpRequest\n");

  #### This is no longer working on some, e.g. http://vimeo.com/70949607
  #
  # It may need some new headers. I'm seeing the HTML5 player send:
  #
  #   X-Playback-Session-Id: 5B0FE3D3-DBC5-4F95-857F-BEA8D81B674F
  #   Cookie: html_player=1
  #   Accept-Encoding: identity
  #
  # But I haven't made any of that work yet, even when just trying
  # to duplicate it from the command line.


  my ($http, $head, $body) = get_url ($info_url, $referer, $hdrs);

  if (!check_http_status ($info_url, $http, 0)) {
    my ($err) = ($body =~ m@\"display_message\":\"(.*?)\"[,\}]@si);
    $err = 'unknown error' unless $err;
    $err =~ s@<[^<>]*>@@gsi;
    if ($err =~ m/private[+\s]video/si) {
      print STDERR "$progname: $id: private video.  Scraping HTML...\n"
        if ($verbose > 1);
      return scrape_vimeo_private ($url, $id);
    } else {
      error ("$id: error: $err");
    }
  }

  my ($title) = ($body =~ m@<H4>([^<>]+)</@si);
  $title = de_entify ($title) if $title;
  $title =~ s/^Download //si;

  my ($w, $h, $size, $selection);
  my $max = 0;
  $body =~ s@<A \b [^<>]*?
                HREF=\"([^\"]+)\" [^<>]*?
                DOWNLOAD=\"[^\"]+? _(\d+)x(\d+) \.
             .*? </A>
             .*? ( \d+ ) \s* MB
            @{
              my $url2;
              ($url2, $w, $h, $size) = ($1, $2, $3, $4);
              $url2 = "http://vimeo.com$url2" if ($url2 =~ m|^/|s);
              print STDERR "$progname: $id: ${w}x$h ${size}MB: $url2\n"
                if ($verbose > 1);
              # If two videos have the same size in MB, pick higher rez.
              my $nn = ($size * 10000000) + ($w * $h);
              if ($nn > $max) {
                $selection = "${w}x$h ${size}MB: $url";
                $url = $url2;
                $max = $nn;
              }
              '';
            }@gsexi;

  print STDERR "$progname: $id: selected ${selection}\n"
    if ($verbose > 1);

  # HEAD doesn't work, so just do a GET but don't read the body.
  my $ct;
  ($http, $head, $body) = get_url ($url, $referer, $hdrs, 0, undef, 1);

  ($ct)   = ($head =~ m/^content-type:\s*([^\s;]+)/mi);
  ($size) = ($head =~ m/^content-length:\s*(\d+)/mi);
  my $year = undef; # no published date in HTML

  errorI ("couldn't find video for $url") unless $ct;

  return ($ct, $url, $title, $year, $w, $h, $size);
}


sub scrape_vimeo_private($$) {
  my ($url, $id) = @_;

  # Grab the iframe embed document, because the other page is 404.
  $url = "http://player.vimeo.com/video/$id/";

  # Send a referer to dodge "The creator of this video has not given you
  # permission to embed it on this domain."
  my $referer = $url;

  # Note: while "http://player.vimeo.com/video/$id/" contains a signature,
  # it is one that doesn't work!  We need the one from the main HTML page.
  # Also note that User-Agent must be the same on both this URL and the
  # play_redirect URL: it seems to be part of what the signature signs.
  #  $url = "http://vimeo.com/$id";
  # No longer true? Instead, look at the URL inside "files" which has sig.

  my ($http, $head, $body) = get_url ($url, $referer);
  if (! check_http_status ($url, $http, 0)) {
    exit (1) if ($verbose <= 0); # Skip silently if --quiet.
    errorI ("$id: $http: scraping private video failed");
  }

  my ($title) = ($body =~ m@<title>\s*([^<>]+?)\s*</title>@si);
  my ($sig)   = ($body  =~ m@"signature":"([a-fA-F\d]+)"@s);
  my ($time)  = ($body  =~ m@"timestamp":"?(\d+)"?@s);
  my ($files) = ($body  =~ m@("hd":{.*?})@s);
     ($files) = ($body  =~ m@("sd":{.*?})@s) unless $files;
     ($files) = ($body  =~ m@"files":{(.*?)\]}@s) unless $files;

  errorI ("$id: vimeo HTML unparsable") unless ($sig && $time && $files);

  # Have seen "hd", "sd" and "mobile" for $qual.  Hopefully they are sorted.
  my ($codec, $qual) = ($files =~ m@^\"([^\"]+)\":[\[\{]\"([^\"]+)\"@si);

  errorI ("$id: vimeo HTML unparsable: no qual/codec") unless ($qual && $codec);

  $url = ('http://player.vimeo.com/play_redirect' .
          '?clip_id=' . $id .
          '&quality=' . $qual .
          '&codecs='  . $codec .
          '&time='    . $time .
          '&sig='     . $sig .
          '&type=html5_desktop_local');

  # Hmm, let's just try to use this one directly.
  # Sometimes the "sd" and "mobile" entries work but "hd" doesn't, WTF.
  $url = $1 if ($files =~ m@"url":"([^\"]+)"@s);

  my $ct = ($codec =~ m@mov@si  ? 'video/quicktime' :
            $codec =~ m@flv@si  ? 'video/flv' :
            $codec =~ m@webm@si ? 'video/webm' :
            'video/mpeg');
  my $w    = undef;
  my $h    = undef;
  my $size = undef;
  my $year = undef;

  return ($ct, $url, $title, $year, $w, $h, $size);
}


sub munge_title($) {
  my ($title) = @_;

  return $title unless defined($title);

  utf8::decode ($title);  # Pack multi-byte UTF-8 back into wide chars.

  # Crud added by the sites themselves.

  $title =~ s/\s+/ /gsi;
  $title =~ s/^Youtube - //si;
  $title =~ s/- Youtube$//si;
  $title =~ s/ on Vimeo\s*$//si;
  $title = '' if ($title eq 'Broadcast Yourself.');
  $title =~ s@: @ - @sg;    # colons, slashes not allowed.
  $title =~ s@[:/]@ @sg;
  $title =~ s@\s+$@@gs;
  $title =~ s@&[^;]+;@@sg; # Fuck it, just omit all entities.

  $title =~ s@\.(mp[34]|m4[auv]|mov|mqv|flv|wmv)\b@@si;

  # Do some simple rewrites / clean-ups to dumb things people do
  # when titling their videos.

  # yes I know it's a video
  $title =~ s/\s*[\[\(][^\[\(]*?\s*\b(video|hd|hq|high quality)[\]\)]\s*$//gsi;
  $title =~ s@\[audio\]@ @gsi;
  $title =~ s@\[mv\]@ @gsi;
  $title =~ s/(official\s*)?(music\s*)?video(\s*clip)?\b//gsi;
  $title =~ s/\s\(official\)//gsi;
  $title =~ s/[-:\s]*SXSW[\d ]*Showcas(e|ing) Artist\b//gsi;
  $title =~ s/^.*\bPresents -+ //gsi;
  $title =~ s/ \| / - /gsi;
  $title =~ s/ - Director - .*$//si;
  $title =~ s/\bHD\s*(720|1080)\s*[pi]\b//si;

  $title =~ s/'s\s+[\'\"](.*)[\'\"]/ - $1/gsi;      # foo's "bar" => foo - bar
  $title =~ s/^([^\"]+) [\'\"](.*)[\'\"]/$1 - $2/gsi; # foo "bar" => foo - bar

  $title =~ s/ -+ *-+ / - /gsi;   # collapse dashes to a single dash
  $title =~ s/~/-/gsi;
  $title =~ s/\s*\{\s*\}\s*$//gsi;	# lose trailing " { }"
  $title =~ s/\s*\(\s*\)\s*$//gsi;	# lose trailing " ( )"

  $title =~ s/[^][[:alnum:]!?()]+$//gsi;  # lose trailing non-alpha-or-paren

  $title =~ s/\s+/ /gs;
  $title =~ s/^\s+|\s+$//gs;

  # If there are no dashes, insert them after the leading upper case words.
  $title =~ s/^((?:[[:upper:]\d]+\s+)+)(.+)/$1-- $2/si
    unless ($title =~ m/ -/s);

  # If there are no dashes, insert them before the trailing upper case words.
  $title =~ s/^(.+?)((\s+[[:upper:]\d]+)+)$/$1 --$2/si
    unless ($title =~ m/ -/s);

  # Capitalize all fully-upper-case words.
  $title =~ s/\b([[:upper:]])([[:upper:]\d]+)\b/$1\L$2/gsi;

# $title =~ s/\b([[:alpha:]])([[:alnum:]\']+)\b/$1\L$2/gsi   # capitalize words
#   if ($title !~ m/[[:lower:]]/s);                    # if it's all upper case


  $title =~ s/ \(\)//gs;
  $title =~ s/ \[\]//gs;

  # Don't allow the title to begin with "." or it writes a hidden file.
  $title =~ s/^([.,\s])/_$1/gs;

  return $title;
}


# Does any version of the file exist with the usual video suffixes?
# Returns the one that exists.
#
sub file_exists_with_suffix($) {
  my ($f) = @_;
  foreach my $ext (@video_extensions) {
    my $ff = "$f.$ext";
    return ($ff) if -f ($ff);
  }
  return undef;
}


# Generates HTML output that provides a link for direct downloading of
# the highest-resolution underlying video.  The HTML also lists the
# video dimensions and file size, if possible.
#
sub cgi_output($$$$$$$) {
  my ($title, $file, $id, $url, $w, $h, $size) = @_;

  if (! ($w && $h)) {
    ($w, $h, $size) = video_url_size ($title, $id, $url);
  }

  $size = -1 unless defined($size);

  my $ss = ($size <= 0        ? '<SPAN CLASS="err">size unknown</SPAN>' :
            $size > 1024*1024 ? sprintf ("%.0fM", $size/(1024*1024)) :
            $size > 1024      ? sprintf ("%.0fK", $size/1024) :
            "$size bytes");
  my $wh = ($w && $h ? "$w &times; $h" : "resolution unknown");
  $wh = '<SPAN CLASS="err">' . $wh . '</SPAN>'
    if (($w || 0) < 1024);
  $ss .= ", $wh";


  # I had hoped that transforming
  #
  #   http://v5.lscache2.googlevideo.com/videoplayback?ip=....
  #
  # into
  #
  #   http://v5.lscache2.googlevideo.com/videoplayback/Video+Title.mp4?ip=....
  #
  # would trick Safari into downloading the file with a sensible file name.
  # Normally Safari picks the target file name for a download from the final
  # component of the URL.  Unfortunately that doesn't work in this case,
  # because the "videoplayback" URL is sending
  #
  #   Content-Disposition: attachment; filename="video.mp4"
  #
  # which overrides my trickery, and always downloads it as "video.mp4"
  # regardless of what the final component in the path is.
  #
  # However, if you do "Save Link As..." on this link, the default file
  # name is sensible!  So it takes two clicks to download it instead of
  # one.  Oh well, I can live with that.
  #
  # UPDATE: If we do "proxy=" instead of "redir=", then all the data moves
  # through this CGI, and it will insert a proper Content-Disposition header.
  # However, if the CGI is not hosted on localhost, then this will first
  # download the entire video to your web host, then download it again to
  # your local machine.
  #
  # Sadly, Vimeo is now doing user-agent sniffing on the "moogaloop/play/"
  # URLs, so this is now the *only* way to make it work: if you try to
  # download one of those URLs with a Safari/Firefox user-agent, you get
  # a "500 Server Error" back.
  #
  my $proxy_p = 1;
  utf8::encode ($file);   # Unpack wide chars into multi-byte UTF-8.
  $url = ($ENV{SCRIPT_NAME} . 
          '/' . url_quote($file) .
          '?' . ($proxy_p? 'proxy' : 'redir') .
          '=' . url_quote($url));
  $url = html_quote ($url);
  $title = html_quote ($title);

  # New HTML5 feature: <A DOWNLOAD=...> seems to be a client-side way of
  # doing the same thing that "Content-Disposition: attachment; filename="
  # does.  Unfortunately, even with this, Safari still opens the .MP4 file
  # after downloading instead of just saving it.

  my $body = ($html_head .
              "  Save Link As:&nbsp; " .
              "  <A HREF=\"$url\" DOWNLOAD=\"$title\">$title</A>, " .
              "  <NOBR>$ss.</NOBR>\n" .
              $html_tail);
  $body =~ s@(<TITLE>)[^<>]*@$1Download "$title"@gsi;
  print STDOUT ("Content-Type: text/html; charset=UTF-8\n" .
                "\n" .
                $body);
}


sub download_video_url($$$$$$$);
sub download_video_url($$$$$$$) {
  my ($url, $title, $year, $size_p, $progress_p, $cgi_p, $force_fmt) = @_;

  $error_whiteboard = '';	# reset per-URL diagnostics
  $progress_ticks = 0;		# reset progress-bar counters
  $progress_time = 0;

  # Add missing "http:"
  $url = "http://$url" unless ($url =~ m@^https?://@si);

  # Rewrite youtu.be URL shortener.
  $url =~ s@^https?://([a-z]+\.)?youtu\.be/@http://youtube.com/v/@si;

  # Rewrite Vimeo URLs so that we get a page with the proper video title:
  # "/...#NNNNN" => "/NNNNN"
  $url =~ s@^(https?://([a-z]+\.)?vimeo\.com/)[^\d].*\#(\d+)$@$1$3@s;

  $url =~ s@^https:@http:@s;	# No https.

  my ($id, $site, $playlist_p);

  # Youtube /view_play_list?p= or /p/ URLs. 
  if ($url =~ m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/
                (?: view_play_list\?p= |
                    p/ |
                    embed/p/ |
                    playlist\?list=(?:PL)? |
                    embed/videoseries\?list=(?:PL)?
                )
                ([^<>?&,]+) ($|&) @sx) {
    ($site, $id) = ($1, $2);
    $url = "http://www.$site.com/view_play_list?p=$id";
    $playlist_p = 1;

  # Youtube /watch/??v= or /watch#!v= or /v/ URLs. 
  } elsif ($url =~ m@^https?:// (?:[a-z]+\.)?
                     (youtube) (?:-nocookie)? (?:\.googleapis)? \.com/+
                     (?: (?: watch/? )? (?: \? | \#! ) v= |
                         v/ |
                         embed/ |
                         .*? &v= |
                         [^/\#?&]+ \#p(?: /[a-zA-Z\d] )* /
                     )
                     ([^<>?&,\'\"]+) ($|[?&]) @sx) {
    ($site, $id) = ($1, $2);
    $url = "http://www.$site.com/watch?v=$id";

  # Youtube "/verify_age" URLs.
  } elsif ($url =~ 
           m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/+
	     .* next_url=([^&]+)@sx ||
           $url =~ m@^https?://(?:[a-z]+\.)?google\.com/
                     .* service = (youtube)
                     .* continue = ( http%3A [^?&]+)@sx ||
           $url =~ m@^https?://(?:[a-z]+\.)?google\.com/
                     .* service = (youtube)
                     .* next = ( [^?&]+)@sx
          ) {
    $site = $1;
    $url = url_unquote($2);
    if ($url =~ m@&next=([^&]+)@s) {
      $url = url_unquote($1);
      $url =~ s@&.*$@@s;
    }
    $url = "http://www.$site.com$url" if ($url =~ m@^/@s);
    return download_video_url ($url, $title, $year, $size_p, undef, $cgi_p,
                               $force_fmt);

  # Youtube "/user" and "/profile" URLs.
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/
                     (?:user|profile).*\#.*/([^&/]+)@sx) {
    $site = $1;
    $id = url_unquote($2);
    $url = "http://www.$site.com/watch?v=$id";
    error ("unparsable user next_url: $url") unless $id;

  # Vimeo /NNNNNN URLs (and player.vimeo.com/video/NNNNNN)
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(vimeo)\.com/(?:video/)?(\d+)@s) {
    ($site, $id) = ($1, $2);

  # Vimeo /videos/NNNNNN URLs.
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(vimeo)\.com/.*/videos/(\d+)@s) {
    ($site, $id) = ($1, $2);

  # Vimeo /channels/name/NNNNNN URLs.
  # Vimeo /ondemand/name/NNNNNN URLs.
  } elsif ($url =~ 
           m@^https?://(?:[a-z]+\.)?(vimeo)\.com/[^/]+/[^/]+/(\d+)@s) {
    ($site, $id) = ($1, $2);

  # Vimeo /moogaloop.swf?clip_id=NNNNN
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(vimeo)\.com/.*clip_id=(\d+)@s) {
    ($site, $id) = ($1, $2);

  } else {
    error ("no ID in $url" . ($title ? " ($title)" : ""))
      unless ($id);
  }

  if ($playlist_p) {
    return download_playlist ($id, $url, $title, $size_p, $cgi_p);
  }

  my $suf = ($append_suffix_p eq '1' ? "$id" :
             $append_suffix_p ? "$id $append_suffix_p" : "");
  $suf =~ s@/.*$@@s;
  $suf = " [$suf]" if $suf;

  # Check for any file with "[this-ID]" in it, as written by --suffix,
  # in case the title changed or something.  IDs don't change.
  #
  my $err = undef;
  my $o = (glob ("*\\[$id\\]*"))[0];
  $err = "exists: $o" if ($o);

  # If we already have a --title, we can check for the existence of the file
  # before hitting the network.  Otherwise, we need to download the video
  # info to find out the title and thus the file name.
  #
  if (defined($title)) {
    $title  = munge_title ($title);
    my $ff = file_exists_with_suffix (de_entify ("$title$suf"));

    if (! $size_p) {
      $err = "$id: exists: $ff"  if ($ff && !$err);
      if ($err) {
        exit (1) if ($verbose <= 0); # Skip silently if --quiet.
        error ($err);
      }
    }
  }

  my ($ct, $w, $h, $size, $title2);

  # Get the video metadata (URL of underlying video, title, year and size)
  #
  if ($site eq 'youtube') {
    ($ct, $url, $title2, $year, $w, $h, $size) = 
      scrape_youtube_url ($url, $id, $title, $size_p, $force_fmt);
  } else {
    error ("--fmt only works with Youtube") if (defined($force_fmt));
    ($ct, $url, $title2, $year, $w, $h, $size) = scrape_vimeo_url ($url, $id);
  }

  # Set the title unless it was specified on the command line with --title.
  #
  if (! defined($title)) {
    $title = munge_title ($title2);

    # Add the year to the title unless there's a year there already.
    #
    if ($title !~ m@ \(\d{4}\)@si) {  # skip if already contains " (NNNN)"
      if (! $year) {
        $year = ($site eq 'youtube' ? get_youtube_year ($id) :
                 $site eq 'vimeo'   ? get_vimeo_year ($id)   : undef);
      }
      if ($year && 
          $year  != (localtime())[5]+1900 &&   # Omit this year
          $title !~ m@\b$year\b@s) {		 # Already in the title
        $title .= " ($year)";
      }
    }
  }

  my $file = de_entify ("$title$suf");
  if    ($ct =~ m@/(x-)?flv$@si)  { $file .= '.flv';  }   # proper extensions
  elsif ($ct =~ m@/(x-)?webm$@si) { $file .= '.webm'; }
  elsif ($ct =~ m@/quicktime$@si) { $file .= '.mov';  }
  else                            { $file .= '.mp4';  }

  if ($size_p) {
    if (! ($w && $h)) {
      ($w, $h, $size) = video_url_size ($title, $id, $url);
    }
    # for "--fmt all"
    my $ii = $id . ($size_p eq '1' || $size_p eq '2' ? '' : ":$size_p");

    my $ss = ($size > 1024*1024 ? sprintf ("%.0fM", $size/(1024*1024)) :
              $size > 1024 ? sprintf ("%.0fK", $size/1024) :
              "$size bytes");

    print STDOUT "$ii\t${w} x ${h}\t$ss\t$title\n";

  } elsif ($cgi_p) {
    cgi_output ($title, $file, $id, $url, $w, $h, $size);

  } else {

    # Might be checking twice, if --title was specified.
    if (! $err) {
      my $ff = file_exists_with_suffix (de_entify ("$title$suf"));
      $err = "$id: exists: $ff"  if ($ff);
    }
    if ($err) {
      exit (1) if ($verbose <= 0); # Skip silently if --quiet.
      error ($err);
    }

    print STDERR "$progname: downloading \"$title\"\n" if ($verbose);

    my $expect_bytes = ($size ? ($progress_p ? $size : -$size) : undef);
    my ($http, $head, $body) = get_url ($url, undef, undef, 0, $file, undef,
                                        undef, $expect_bytes);
    check_http_status ($url, $http, 2);  # internal error if still 403

    if (! -s $file) {
      unlink ($file);
      error ("$file: failed: $url");
    }

    if ($verbose) {

      # Now that we've written the file, get the real numbers from it,
      # in case the server metadata lied to us.
      ($w, $h, $size) = video_file_size ($file);

      $size = -1 unless $size;
      my $ss = ($size > 1024*1024 ? sprintf ("%.0fM", $size/(1024*1024)) :
                $size > 1024 ? sprintf ("%.0fK", $size/1024) :
                "$size bytes");
      $ss .= ", $w x $h" if ($w && $h);
      print STDERR "$progname: wrote       \"$file\", $ss\n";
    }
  }
}


sub download_playlist($$$$$) {
  my ($id, $url, $title, $size_p, $cgi_p) = @_;

  my $start = 0;
  while (1) {

    # max-results is ignored if it is >50, so we get 50 at a time until
    # we run out.
    my $chunk = 50;
    my $data_url = ("http://gdata.youtube.com/feeds/api/playlists/$id?v=2" .
                    "&start-index=" . ($start+1) .
                    "&max-results=$chunk" .
                    "&fields=title,entry(title,link)" .
                    "&safeSearch=none" .
                    "&strict=true");

    my ($http, $head, $body) = get_url ($data_url, undef, undef, 0, undef);
    check_http_status ($url, $http, 1);

    ($title) = ($body =~ m@<title>\s*([^<>]+?)\s*</title>@si)
      unless $title;
    $title = 'Untitled Playlist' unless $title;

    $body =~ s@(<entry)@\001$1@gs;
    my @entries = split(m/\001/, $body);
    shift @entries;
    print STDERR "$progname: playlist \"$title\" (" . ($#entries+1) .
                 " entries)\n"
      if ($verbose > 1 && $start == 0);

    my $i = $start;
    foreach my $entry (@entries) {
      my ($t2) = ($entry =~ m@<title>\s*([^<>]+?)\s*</title>@si);
      my ($u2, $id2) =
        ($entry =~ m@<link.*?href=[\'\"]
                     (https?://[a-z.]+/
                     (?: watch/? (?: \? | \#! ) v= | v/ | embed/ )
                     ([^<>?&,\'\"]+))@sxi);
      $t2 = sprintf("%s: %02d: %s", $title, ++$i, $t2);
      my $year = undef;

      eval {
        $noerror = 1;
        download_video_url ($u2, $t2, $year, $size_p, undef, $cgi_p, undef);
        $noerror = 0;
      };
      print STDERR "$progname: $@" if $@;

      # With "--size", only get the size of the first video.
      # With "--size --size", get them all.
      last if ($size_p == 1);
    }
    last if ($size_p == 1);

    $start += $chunk;
    last unless @entries;
  }
}


sub do_cgi() {
  $|=1;

  my $args = "";
  if (!defined ($ENV{REQUEST_METHOD})) {
  } elsif ($ENV{REQUEST_METHOD} eq "GET") {
    $args = $ENV{QUERY_STRING} if (defined($ENV{QUERY_STRING}));
  } elsif ($ENV{REQUEST_METHOD} eq "POST") {
    local $/ = undef;  # read entire file
    $args .= <STDIN>;
  }

  if (!$args &&
      defined($ENV{REQUEST_URI}) && 
      $ENV{REQUEST_URI} =~ m/^(.*?)\?(.*)$/s) {
    $args = $2;
    # for cmd-line debugging
    $ENV{SCRIPT_NAME} = $1 unless defined($ENV{SCRIPT_NAME});
#    $ENV{PATH_INFO} = $1 if (!$ENV{PATH_INFO} && 
#                             $ENV{SCRIPT_NAME} =~ m@^.*/(.*)@s);
  }

  my ($url, $redir, $proxy);
  foreach (split (/&/, $args)) {
    my ($key, $val) = m/^([^=]+)=(.*)$/;
    $key = url_unquote ($key);
    $val = url_unquote ($val);
    if    ($key eq 'url')   { $url = $val; }
    elsif ($key eq 'redir') { $redir = $val; }
    elsif ($key eq 'proxy') { $proxy = $val; }
    else { error ("unknown option: $key"); }
  }

  if ($redir || $proxy) {
    error ("can't specify both url and redir")   if ($redir && $url);
    error ("can't specify both url and proxy")   if ($proxy && $url);
    error ("can't specify both redir and proxy") if ($proxy && $redir);
    my $name = $ENV{PATH_INFO} || '';
    $name =~ s@^/@@s;
    $name = ($redir || $proxy) unless $name;
    $name =~ s@\"@%22@gs;
    if ($redir) {
      # Return a redirect to the underlying video URL.
      print STDOUT ("Content-Type: text/html\n" .
                    "Location: $redir\n" .
                    "Content-Disposition: attachment; filename=\"$name\"\n" .
                    "\n" .
                    "<A HREF=\"$redir\">$name</A>\n" .
                    "\n");
    } else {
      # Proxy the data, so that we can feed it a non-browser user agent.
      print STDOUT "Content-Disposition: attachment; filename=\"$name\"\n";
      binmode (STDOUT);
      get_url ($proxy, undef, undef, 0, '-');
    }

  } elsif ($url) {
    error ("extraneous crap in URL: $ENV{PATH_INFO}")
      if (defined($ENV{PATH_INFO}) && $ENV{PATH_INFO} ne "");
    download_video_url ($url, undef, undef, 0, undef, 1, undef);

  } else {
    error ("no URL specified for CGI");
  }
}


sub usage() {
  print STDERR "usage: $progname [--verbose] [--quiet] [--size]" .
		       " [--progress] [--suffix] [--fmt N]\n" .
               "\t\t   [--title title] youtube-or-vimeo-urls ...\n";
  exit 1;
}

sub main() {

  binmode (STDOUT, ':utf8');   # video titles in messages
  binmode (STDERR, ':utf8');

  # historical suckage: the environment variable name is lower case.
  $http_proxy = $ENV{http_proxy} || $ENV{HTTP_PROXY};

  if ($http_proxy && $http_proxy =~ m@^https?://([^/]*)/?$@ ) {
    # historical suckage: allow "http://host:port" as well as "host:port".
    $http_proxy = $1;
  }

  my @urls = ();
  my $title = undef;
  my $size_p = 0;
  my $progress_p = 0;
  my $fmt = undef;
  my $expect = undef;
  my $guessp = 0;

  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if (m/^--?verbose$/)     { $verbose++; }
    elsif (m/^-v+$/)         { $verbose += length($_)-1; }
    elsif (m/^--?q(uiet)?$/) { $verbose--; }
    elsif (m/^--?progress$/) { $progress_p++; }
    elsif (m/^--?suffix$/)   { $append_suffix_p++; }
    elsif (m/^--?title$/)    { $expect = $_; $title = shift @ARGV; }
    elsif (m/^--?size$/)     { $expect = $_; $size_p++; }
    elsif (m/^--?fmt$/)      { $expect = $_; $fmt = shift @ARGV; }
    elsif (m/^--?guess$/)    { $guessp++; }
    elsif (m/^-./)           { usage; }
    else { 
      s@^//@http://@s;
      error ("not a Youtube or Vimeo URL: $_")
        unless (m@^(https?://)?
                   ([a-z]+\.)?
                   ( youtube(-nocookie)?\.com/ |
                     youtu\.be/ |
                     vimeo\.com/ |
                     google\.com/ .* service=youtube |
                     youtube\.googleapis\.com
                   )@six);
      my @P = ($title, $fmt, $_);
      push @urls, \@P;
      $title = undef;
      $expect = undef;
    }
  }

  error ("$expect applies to the following URLs, so it must come first")
    if ($expect);

  if ($guessp) {
    guess_cipher (undef, $guessp - 1);
    exit (0);
  }

  return do_cgi() if (defined ($ENV{REQUEST_URI}));

  usage if (defined($fmt) && $fmt !~ m/^\d+|all$/s);

  usage unless ($#urls >= 0);
  foreach (@urls) {
    my ($title, $fmt, $url) = @$_;
    download_video_url ($url, $title, undef, $size_p, $progress_p, 0, $fmt);
  }
}

main();
exit 0;
