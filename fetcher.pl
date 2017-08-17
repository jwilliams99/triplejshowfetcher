#!/usr/bin/perl -w

use strict;
use Getopt::Long;
use Data::Dumper;
use LWP::UserAgent;
use HTML::TokeParser;
use Net::SFTP::Foreign;
use LWP::Simple qw(getstore);
use File::Path qw(make_path remove_tree);

my $host = 'http://www.abc.net.au';
my $path = '/triplej/programs';

my %shows = (
    sfl => {
             showPath => '/short-fast-loud',
             lookfor  => '/short-fast-loud/short.fast.loud/',
             showURL  => '',                        # where we look to download the file that has the segments in it
             desc     => 'Short_Fast_Loud',
             idv3     => { album => 'Short Fast Loud', artist => 'Triple J' }
           },
    rac => {
             showPath => '/the-racket',
             lookfor  => '/the-racket/the-racket/', # what to look for when we parse the page looking for the show id
             showURL  => '',                        # where we look to download the file that has the segments in it
             desc     => 'Racket',
             idv3     => { album => 'Racket', artist => 'Triple J' }
           },
);
my $sfl; my $rac;my $shows;
my %opts = (
    #           Usage:                                     Value
    shows     => [" Available shows: [".join(' | ', keys %shows), 0                       ],
    sftphost  => [" [ --sftphost <host name> ]",            'ryszard.us'                  ],
    sftpport  => [" [ --sftpport ]",                        '443'                         ],
    sftpuser  => [" [ --sftpuser <user> ]",                 'sftpuser'                    ],
    proxy     => [" [ --proxy <proxy> ]",                   undef                         ],
    #proxy     => [" [ --proxy <proxy> ]",                   '192.168.88.230:8080'         ],
    debug     => [" [ --debug [ 0 | 1 ] ]",                 0                             ], 
    keep      => [" [ --keep [ 0 | 1 ] ]",                  0                             ], # keep downloaded fragments
    ssl_hn    => [" [ --ssl_hn [ 0 | 1 ] ]",                0                             ], # ssl verify hostname http://search.cpan.org/~oalders/libwww-perl-6.26/lib/LWP/UserAgent.pm#ssl_opts
    rand_wait => [" [ --rand_wait <number> ]",              0                             ], # wait a random amount of time up to rand_wait before fetching next segment
    sfl       => [" [ --sfl ] (Short Fast Loud)",           'sfl'                         ],
    rac       => [" [ --rac ] (Racket)",                    'rac'                         ],
);

GetOptions (

    "shows"      => \$opts{show}[1], 
    "sftphost=s" => \$opts{sftphost}[1], 
    "sftpuser=s" => \$opts{sftphost}[1], 
    "proxy=s"    => \$opts{proxy}[1],
    "debug=s"    => \$opts{debug}[1],
    "keep=s"     => \$opts{keep}[1],
    "ssl_hn=s"   => \$opts{ssl_hn}[1],
    "rand_wait=s"=> \$opts{rand_wait}[1],
    "sfl"        => \$sfl,
    "rac"        => \$rac,

) or &usage;

my $show = '';
if ($sfl ne '') { $show = 'sfl' }
if ($rac ne '') { $show = 'rac' }

if ( ! grep { /$show/ } keys %shows ){
    &usage;
}

if (  $show eq '' ){
    &usage;
}

my $desc = $shows{ $show }->{ desc };

my $ua = LWP::UserAgent->new();
$ua->ssl_opts( verify_hostname => $opts{ssl_hn}[1] );
if (defined $opts{proxy}[1]){
    $ua->proxy(['http', 'https', 'ftp'], 'http://'.$opts{proxy}[1].'/');
}

# first we have to parse the show page to get the ID for the current show
my $showUrl = $host.$path.$shows{ $show }->{showPath};
print "Have show page: $showUrl\n";

my $r = $ua->get( $showUrl );
print STDERR "Looking for show ID\n";
print STDERR "Toke parsing for the show ID\n" if ($opts{debug}[1] > 0);
my $idContent = $r->decoded_content;
my $idP = HTML::TokeParser->new( \$idContent );
while( my $t = $idP->get_tag("a") ){

    if (defined $t->[1]->{href} && $t->[1]->{href} =~ /$shows{ $show }->{lookfor}/) {
        print Dumper($t) if ($opts{debug}[1] > 0);
        print "URL PATH $t->[1]->{href}\n" if ($opts{debug}[1] > 0);
        $shows{ $show }->{showURL} = $t->[1]->{href};
        print "Show URL = $shows{ $show }->{showURL}\n" if ($opts{debug}[1] > 0);

    }

}
if ($shows{ $show }->{showURL} eq '') {
    die "Cant find show URL";
}

# oncw we have the page, we need to parse it and look for 
# the script tag that has a m3u8 file.  this file contains
# a link to a file that has all the sengments to download
$r = $ua->get($host.$shows{ $show }->{showURL});
print Dumper($r->decoded_content) if ($opts{debug}[1] > 1);

print STDERR "Toke parsing\n" if ($opts{debug}[1] > 0);
my $content = $r->decoded_content;
my $p = HTML::TokeParser->new(\$content);

# we're looking for this:
# http://abcradiomodhls.abc-cdn.net.au/i/triplej/audio/rac-2017-07-11.m4a/master.m3u8
my $segmentURL;my $showDate;
while( my $t = $p->get_tag("div") ){

    #print STDERR Dumper($t)  if ($opts{debug}[1] > 0);
    if (defined $t->[1]->{class} && $t->[1]->{class} eq 'comp-audio-player-player') {
    print STDERR Dumper($t)  if ($opts{debug}[1] > 0);
        $p->get_tag("script","/script");
        my $c = $p->get_text();
        foreach my $line (split(/\n/, $c)) {
print "$line\n" if ($opts{debug}[1] > 0);
            if ($line =~ /m3u8/) {
                my @e = split(/\"/, $line);
                print $e[3]."\n";
                $e[3] =~ /.*(\d\d\d\d)-(\d\d)-(\d\d).*/;
                $showDate = "$1-$2-$3";
                $segmentURL = $e[3];
            }
        }
    }
}

if (! $showDate){
    die "Problem parsing page, unable to find show date!"
}
my $showDir  = "$show-$showDate";
make_path( $showDir );

$r = $ua->get($segmentURL);
my @segments;
if ($r->is_success){
    my $tmp = $r->decoded_content;
    foreach my $line(split(/\n/, $tmp)){
        if ($line =~ /^http/){
            $r=$ua->get($line);
            if ($r->is_success){
                foreach my $line (split(/\n/, $r->decoded_content)){
                    if ($line =~ /^http/) {
                        push @segments, $line;
                    }
                } 
            } else {
                die "Couldnt download segments file, ".$r->status_line;
            }
        }
    }
} else {
    die "Couldnt download m3u8 file, ".$r->status_line;
}

# check to see if we've downloaded some before
my $start = `ls -1v $showDir/*m4a 2>/dev/null | tail -1 | cut -d\/ -f2 | cut -d\- -f1`; chomp $start; 
print "Last number downloaded: $start\n" if ($opts{debug}[1] > 0);
if ($start =~ /[^\d]+/) { $start = 1 } else { $start++ }
print "Begining at file $start\n" if ($opts{debug}[1] > 0);
#print Dumper(\@segments);

my $segment = ($start-1);  # just incase a file was aborted 1/2 way thru;
$segment = 0 if ($segment < 0);
for (my $i=$segment;$i<=$#segments;$i++) {  #$segment(@segments) {
    #next if (-f "$showDir/${i}-$desc.m4a");

    print "Downloading segment: $segments[$i] \n";
    my $r = $ua->get($segments[$i]);
#    print Dumper($r) if ($opts{debug}[1] > 0);

    if ($r->is_success) {
        getstore( $segments[$i], "$showDir/$i-$desc.m4a");
        my $sleep = int(rand( $opts{rand_wait}[1] ));
        print "Sleeping $sleep seconds\n" if ($opts{debug}[1] > 0 && $opts{rand_wait}[1] > 0);
        sleep $sleep;
    } else {

        if ($r->code eq '404') {
            last;
        } else {
            print "Fatal error when downloading $segments[$i], bailing\n";
            print "\t".$r->code."\n";
            print Dumper($r) if ($opts{debug}[1] > 0);
            die 54;
        }
    }
}
my $fragCount = `ls $showDir/*.m4a 2>/dev/null| wc -l`;
if ($fragCount == 0) {
    print "No fragments downloaded..\n";
    remove_tree $showDir; 
    exit;
}
if ($fragCount < 1000) {
    print "Not enough fragments downloaded, we need around $#segments and have $fragCount..\n";
    exit;
}

`cd $showDir;ls -1v *.m4a | awk '{print "file "\$1}' > "segments.txt"`;

print "Concatenating downloaded fragments\n";
`ffmpeg -y -f concat -safe 0 -i $showDir/segments.txt -codec:a libmp3lame -q:a 2 $show-$showDate.mp3`;
`id3v2 -a  "$shows{ $show }->{ idv3 }->{artist}" -A "$shows{ $show }->{ idv3 }->{album}  $showDate" $show-$showDate.mp3`;
unlink $showDir unless ( $opts{keep}[1] == 1 );

if ( -f "$show-$showDate.mp3" && $opts{sftphost}[1] ne '' ) {
    my ($ph, $pp) = split(/\:/, $opts{proxy}[1]);
    my $sftp = Net::SFTP::Foreign->new(
        host => $opts{sftphost}[1], 
        user => $opts{sftpuser}[1],
        more => [-o => "ProxyCommand /usr/bin/corkscrew $ph $pp %h %p"]
    );

    $sftp->die_on_error("Unable to establish SFTP connection");
    $sftp->setcwd('jjj') or die "unable to change cwd: " . $sftp->error;
    print "sftping file to $opts{sftphost}[1]..\n";
    $sftp->put("$show-$showDate.mp3") || die "sftpput failed: ".$sftp->error ;

}
#unlink "$show-$showDate.mp3" unless ( $opts{keep}[1] == 1 );

sub usage {

    my $usage; $usage .= $opts{ $_ }[0] foreach (sort keys %opts);
    die "Usage: $0 $usage\n";

}

__DATA__
HTML::TokeParser data
$VAR1 = [
          'a',
          {
            'class' => 'listen',
            'href' => 'http://www.abc.net.au/radio/search?service_guid=4068084-2017-02-22',
            'target' => '_blank'
          },
          [
            'class',
            'href',
            'target'
          ],
          '<a class="listen" href="http://www.abc.net.au/radio/search?service_guid=4068084-2017-02-22" target="_blank">'
        ];

