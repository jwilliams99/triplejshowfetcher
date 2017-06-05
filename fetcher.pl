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
             url => 'http://www.abc.net.au/triplej/shortfastloud/',
             desc => 'Short_Fast_Loud',
             idv3 => { album => 'Short Fast Loud', artist => 'Triple J' }
           },
    rac => {
             url  => 'http://www.abc.net.au/triplej/racket/',
             desc => 'Racket',
             idv3 => { album => 'Racket', artist => 'Triple J' }
           },
);

my %opts = (
    #           Usage:                                     Value
    show      => [" --show [".join(' | ', keys %shows)."]", 0                             ],
    sftphost  => [" [ --sftphost <host name> ]",            'ryszard.us'                  ],
    sftpuser  => [" [ --sftpuser <user> ]",                 'sftpuser'                    ],
    proxy     => [" [ --proxy <proxy> ]",                   '192.168.88.230:8080'         ],
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

my $url  = $shows{ $opts{show}[1] }->{ url };
my $desc = $shows{ $opts{show}[1] }->{ desc };

my $segmentUrlBase = 'http://abcradiomodhls.abc-cdn.net.au/i/triplej/audio/';

my $ua = LWP::UserAgent->new();
$ua->ssl_opts( verify_hostname => $opts{ssl_hn}[1] );
$ua->proxy(['http', 'https', 'ftp'], 'http://'.$opts{proxy}[1].'/');

print STDERR "Fetching $url\n";
my $r = $ua->get($url);
if (! $r->is_success) {
    print "Error fetching page! ".$r->status_line;
    exit;
}
my $content = $r->decoded_content;
my $p = HTML::TokeParser->new(\$content);

# locate the current date of the show
my $showDate = '';
print STDERR "Toke parsing\n" if ($opts{debug}[1] > 0);
while( my $t = $p->get_tag("a") ){

    if (defined $t->[1]->{class} && $t->[1]->{class} eq 'listen') {
        print STDERR Dumper($t->[1]->{href}) if ($opts{debug}[1] > 0); 
        $t->[1]->{href} =~ m!([\d]{4}-[\d]{2}-[\d]{2})$!;
        print "Found date $1\n" if ($opts{debug}[1] > 0);
        $showDate = $1;
    }
}

my $showDir  = "$opts{show}[1]-$showDate";
if (! $showDate){
    die "Problem parsing page, unable to find show date!"
}
make_path("$opts{show}[1]-$showDate");

# check to see if we've downloaded some before
my $start = `ls -1v $showDir/*m4a 2>/dev/null | tail -1 | cut -d\/ -f2 | cut -d\- -f1`; chomp $start; 
print "Last number downloaded: $start\n" if ($opts{debug}[1] > 0);
if ($start =~ /[^\d]+/) { $start = 1 } else { $start++ }
print "Begining at file $start\n" if ($opts{debug}[1] > 0);

for(my$i=$start;$i<2000;$i++) {

    next if (-f "$showDir/${i}-$desc.m4a");

    #http://abcradiomodhls.abc-cdn.net.au/i/triplej/audio/sfl-1-2017-03-29.m4a/segment7_0_a.ts?null=0'. 
    my $url = "http://abcradiomodhls.abc-cdn.net.au/i/triplej/audio/$opts{show}[1]-1-$showDate.m4a/segment${i}_0_a.ts?null=0";
    print "Downloading segment $i: $url \n";
    my $r = $ua->get($url);

    if ($r->is_success) {
        getstore( $url, "$showDir/${i}-$desc.m4a");
        my $sleep = int(rand( $opts{rand_wait}[1] ));
        print "Sleeping $sleep seconds\n" if ($opts{debug}[1] > 0 && $opts{rand_wait}[1] > 0);
        sleep $sleep;
    } else {

        if ($r->code eq '404') {
            last;
        } else {
            print "Fatal error when downloading $url, bailing\n";
            print "\t".$r->code."\n";
            print Dumper($r) if ($opts{debug}[1] > 0);
            die 54;
        }
    }
    #my $retval = `ffmpeg -loglevel 8 -y -i $url -acodec copy $showDir/${i}-$desc.m4a 2>&1`;
    #print "retval: $retval, $!\n";
}
my $fragCount = `ls $showDir/*.m4a 2>/dev/null| wc -l`;
if ($fragCount == 0) {
    print "No fragments downloaded..\n";
    remove_tree $showDir; 
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

