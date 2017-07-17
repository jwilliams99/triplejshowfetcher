#!/usr/bin/perl -w

use strict;
use Getopt::Long;
use Data::Dumper;
use LWP::UserAgent;
use HTML::TokeParser;
use Net::SFTP::Foreign;
use LWP::Simple qw(getstore);
use File::Path qw(make_path remove_tree);

my %shows = (
    sfl => {
             host => 'http://www.abc.net.au/',
             url => 'http://www.abc.net.au/triplej/shortfastloud/',
             desc => 'Short_Fast_Loud',
             lookfor => 'Short.Fast.Loud',
             idv3 => { album => 'Short Fast Loud', artist => 'Triple J' }
           },
    rac => {
             host => 'http://www.abc.net.au/',
             url  => 'http://www.abc.net.au/triplej/racket/',
             desc => 'Racket',
             lookfor => 'The Racket',
             idv3 => { album => 'Racket', artist => 'Triple J' }
           },
);

my %opts = (
    #           Usage:                                     Value
    show      => [" --show [".join(' | ', keys %shows)."]", 0                             ],
    sftphost  => [" [ --sftphost <host name> ]",            'ryszard.us'                  ],
    sftpuser  => [" [ --sftpuser <user> ]",                 'sftpuser'                    ],
    proxy     => [" [ --proxy <proxy> ]",                   undef                         ],
    #proxy     => [" [ --proxy <proxy> ]",                   '192.168.88.230:8080'         ],
    debug     => [" [ --debug [ 0 | 1 ] ]",                 0                             ], 
    keep      => [" [ --keep [ 0 | 1 ] ]",                  0                             ], # keep downloaded fragments
    ssl_hn    => [" [ --ssl_hn [ 0 | 1 ] ]",                0                             ], # ssl verify hostname http://search.cpan.org/~oalders/libwww-perl-6.26/lib/LWP/UserAgent.pm#ssl_opts
    rand_wait => [" [ --rnd_wait <number>]",                0                             ], # wait a random amount of time up to rand_wait before fetching next segment
);

GetOptions (

    "show=s"     => \$opts{show}[1], 
    "sftphost=s" => \$opts{sftphost}[1], 
    "sftpuser=s" => \$opts{sftphost}[1], 
    "proxy=s"    => \$opts{proxy}[1],
    "debug=s"    => \$opts{debug}[1],
    "keep=s"     => \$opts{keep}[1],
    "ssl_hn=s"   => \$opts{ssl_hn}[1],
    "rand_wait=s"=> \$opts{rand_wait}[1],

) or &usage;

if ( ! grep { /$opts{show}[1]/ } keys %shows ){
    &usage;
}

my $host = $shows{ $opts{show}[1] }->{ host };
my $url  = $shows{ $opts{show}[1] }->{ url };
my $desc = $shows{ $opts{show}[1] }->{ desc };

my $ua = LWP::UserAgent->new();
$ua->ssl_opts( verify_hostname => $opts{ssl_hn}[1] );
if (defined $opts{proxy}[1]){
    $ua->proxy(['http', 'https', 'ftp'], 'http://'.$opts{proxy}[1].'/');
}

print STDERR "Fetching $url\n";
my $r = $ua->get($url);
if (! $r->is_success) {
    print "Error fetching page! ".$r->status_line;
    exit;
}
my $content = $r->decoded_content;
my $p = HTML::TokeParser->new(\$content);

# locate the current date of the show
my $showDate = '';my $showUrl = '';
print STDERR "Toke parsing\n" if ($opts{debug}[1] > 0);
while( my $t = $p->get_tag("a") ){

    print STDERR Dumper($t->[1]->{title}) if ($opts{debug}[1] > 0); 
    if (defined $t->[1]->{title} && $t->[1]->{title} eq $shows{ $opts{show}[1] }->{lookfor}) {
        print STDERR Dumper($t->[1]->{href}) if ($opts{debug}[1] > 0); 
        $showUrl = $t->[1]->{href};
        last;
    }
}
# now weha vethe url we need to go and ge the page
$r = $ua->get($host.'/'.$showUrl);

# oncw we have the page, we need to parse it and look for 
# the script tag that has a m3u8 file.  this file contains
# a link to a file that has all the sengments to download
#print Dumper($r->decoded_content);

print STDERR "Toke parsing\n" if ($opts{debug}[1] > 0);
$content = $r->decoded_content;
$p = HTML::TokeParser->new(\$content);

# we're looking for this:
# http://abcradiomodhls.abc-cdn.net.au/i/triplej/audio/rac-2017-07-11.m4a/master.m3u8
my $segmentURL;
while( my $t = $p->get_tag("div") ){

    if (defined $t->[1]->{class} && $t->[1]->{class} eq 'comp-audio-player-player') {
        $p->get_tag("script","/script");
        my $c = $p->get_text();
        foreach my $line (split(/\n/, $c)) {
            if ($line =~ /m3u8/) {
                my @e = split(/\"/, $line);
                print $e[3];
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
my $showDir  = "$opts{show}[1]-$showDate";
make_path("$opts{show}[1]-$showDate");

$r = $ua->get($segmentURL);
my @segments;
if ($r->is_success){
    my $tmp = $r->decoded_content;
    foreach my $line(split(/\n/, $tmp)){
        chomp;
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

my $i = 0;
foreach my $segment(@segments) {

    next if (-f "$showDir/${i}-$desc.m4a");

    print "Downloading segment: $segment \n";
    my $r = $ua->get($segment);
#    print Dumper($r) if ($opts{debug}[1] > 0);

    if ($r->is_success) {
        getstore( $segment, "$showDir/$i-$desc.m4a");
        my $sleep = int(rand( $opts{rand_wait}[1] ));
        print "Sleeping $sleep seconds\n" if ($opts{debug}[1] > 0 && $opts{rand_wait}[1] > 0);
        sleep $sleep;
    } else {

        if ($r->code eq '404') {
            last;
        } else {
            print "Fatal error when downloading $segment, bailing\n";
            print "\t".$r->code."\n";
            print Dumper($r) if ($opts{debug}[1] > 0);
            die 54;
        }
    }
    $i++;
    #my $retval = `ffmpeg -loglevel 8 -y -i $url -acodec copy $showDir/${i}-$desc.m4a 2>&1`;
    #print "retval: $retval, $!\n";
}
my $fragCount = `ls $showDir/*.m4a 2>/dev/null| wc -l`;
if ($fragCount == 0) {
    print "No fragments downloaded..\n";
    remove_tree $showDir; 
    exit;
}
if ($fragCount < 1000) {
    print "Not enough fragments downloaded, we need around 1000 and have $fragCount..\n";
    exit;
}

`cd $showDir;ls -1v *.m4a | awk '{print "file "\$1}' > "segments.txt"`;

print "Concatenating downloaded fragments\n";
`ffmpeg -y -f concat -safe 0 -i $showDir/segments.txt -codec:a libmp3lame -q:a 2 $opts{show}[1]-$showDate.mp3`;
`id3v2 -a  "$shows{ $opts{show}[1] }->{ idv3 }->{artist}" -A "$shows{ $opts{show}[1] }->{ idv3 }->{album}  $showDate" $opts{show}[1]-$showDate.mp3`;
unlink $showDir unless ( $opts{keep}[1] == 1 );

if ( -f "$opts{show}[1]-$showDate.mp3" && $opts{sftphost}[1] ne '' ) {
    my ($ph, $pp) = split(/\:/, $opts{proxy}[1]);
    my $sftp = Net::SFTP::Foreign->new(
        host => $opts{sftphost}[1], 
        user => $opts{sftpuser}[1],
        more => [-o => "ProxyCommand /usr/bin/corkscrew $ph $pp %h %p"]
    );

    $sftp->die_on_error("Unable to establish SFTP connection");
    $sftp->setcwd('jjj') or die "unable to change cwd: " . $sftp->error;
    print "sftping file to $opts{sftphost}[1]..\n";
    $sftp->put("$opts{show}[1]-$showDate.mp3") || die "sftpput failed: ".$sftp->error ;

}
#unlink "$opts{show}[1]-$showDate.mp3" unless ( $opts{keep}[1] == 1 );

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

