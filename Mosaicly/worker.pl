#!/usr/bin/perl
# Linux MVP worker. Launch only via an externally supervised timeout/prlimit
# command, with a fresh private directory for each job. No server startup.
use strict;
use warnings;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use Cwd qw(abs_path);
use File::Spec;
use JSON::PP;
use Digest::SHA qw(sha256_hex);

use constant SLIM_SERVICE=>0;
use constant SCANNER=>1;
use constant RESIZER=>0;
use constant TRANSCODING=>0;
use constant PERFMON=>0;
use constant ISWINDOWS=>0;
use constant ISACTIVEPERL=>0;
use constant ISMAC=>0;
use constant DEBUGLOG=>0;
use constant INFOLOG=>0;
use constant STATISTICS=>0;
use constant SB1SLIMP3SYNC=>0;
use constant WEBUI=>0;
use constant HAS_AIO=>0;
use constant LOCALFILE=>0;
use constant NOMYSB=>1;
our $VERSION='9.1.1';

sub contained {
    open my $fh,'<','/proc/self/limits' or return 0;
    my ($as,$core);
    while (<$fh>) {
        $as=$1 eq '268435456' && $2 eq '268435456'
            if /^Max address space\s+(\S+)\s+(\S+)/;
        $core=$1 eq '0' && $2 eq '0'
            if /^Max core file size\s+(\S+)\s+(\S+)/;
    }
    close $fh or return 0;
    return $as && $core;
}
sub write_new {
    my ($path,$bytes)=@_;
    sysopen my $fh,$path,O_WRONLY|O_CREAT|O_EXCL,0600 or die "create output: $!";
    binmode $fh or die "binmode: $!";
    print {$fh} $bytes or die "write output: $!";
    close $fh or die "close output: $!";
}
sub read_job {
    my ($path)=@_;
    die 'invalid job file' unless -f $path && !-l $path;
    open my $fh,'<:raw',$path or die "open job: $!";
    my $bytes='';
    while (length($bytes)<=262144) {
        my $n=read($fh,my $chunk,8192);
        die "read job: $!" unless defined $n;
        last unless $n;
        $bytes.=$chunk;
    }
    close $fh or die "close job: $!";
    die 'job exceeds 256 KiB' if length($bytes)>262144;
    my $job=JSON::PP->new->utf8->max_depth(16)->decode($bytes);
    die 'invalid job' unless ref($job) eq 'HASH'
        && defined($job->{contributor_id}) && !ref($job->{contributor_id})
        && $job->{contributor_id}=~/\A[1-9][0-9]*\z/;
    return ($job,sha256_hex($bytes));
}

die "worker containment required\n" unless contained();
die "usage: worker.pl JOBDIR LMS_LIBPATH\n" unless @ARGV==2;
my ($dir,$lib)=map {abs_path($_)} @ARGV;
die 'invalid job directory' unless defined($dir) && -d $dir && !-l $ARGV[0];
my @st=stat($dir);
die 'job directory must be private and worker-owned' unless $st[4]==$> && ($st[2]&0777)==0700;
die 'invalid LMS library directory' unless defined($lib) && -d $lib;
umask 0077;
chdir $dir or die "chdir: $!";
for my $name (qw(runtime portrait.jpg result.json)) {
    die "existing worker output: $name" if -e $name || -l $name;
}
my ($job,$job_sha)=read_job('job.json');
mkdir 'runtime',0700 or die "mkdir runtime: $!";
for my $name (qw(prefs cache logs tmp home)) {
    mkdir "runtime/$name",0700 or die "mkdir runtime/$name: $!";
}
$ENV{HOME}="$dir/runtime/home";
$ENV{TMPDIR}="$dir/runtime/tmp";
$ENV{XDG_CACHE_HOME}="$dir/runtime/cache";
$ENV{XDG_CONFIG_HOME}="$dir/runtime/prefs";
$ENV{AUDIO_SCAN_NO_ARTWORK}=1;
# Prefs parses prefsdir during module load. Do not use the live prefs.
@ARGV=("--prefsdir=$dir/runtime/prefs");
our $logdir="$dir/runtime/logs";
our $cachedir="$dir/runtime/cache";

# Caller supplies the installed LMS Perl include paths (including plugin
# parent and native CPAN paths). Use the real bootstrap, not scanner.pl.
require Slim::Utils::OSDetect;
Slim::Utils::OSDetect::init($lib);
require Slim::bootstrap;
Slim::bootstrap->loadModules([qw(version Time::HiRes DBI HTML::Parser XML::Parser::Expat YAML::XS)], [], $lib);
# Initialize actual native logging before artwork modules can report errors.
# Explicit config path avoids falling back to the installed server's prefs.
require Slim::Utils::Log;
Slim::Utils::Log->init({
    logdir=>$logdir,
    logconf=>"$dir/runtime/prefs/log.conf",
    logtype=>'scanner',
});
require Plugins::MusicArtistInfo::Mosaicly::Generator;
my $r=Plugins::MusicArtistInfo::Mosaicly::Generator->generate(
    contributor_id=>$job->{contributor_id},job=>$job,
    bounded_worker_progressive=>1);
die 'invalid generator result' unless ref($r) eq 'HASH';
if ($r->{ok}) {
    my $jpeg=delete $r->{bytes};
    die 'invalid JPEG output' unless defined($jpeg) && !ref($jpeg)
        && length($jpeg)<=8*1024*1024 && substr($jpeg,0,2) eq "\xff\xd8"
        && substr($jpeg,-2) eq "\xff\xd9";
    $r->{jpeg_bytes}=length($jpeg);
    $r->{jpeg_sha256}=sha256_hex($jpeg);
    write_new('portrait.jpg',$jpeg);
}
$r->{job_sha256}=$job_sha;
my $json=JSON::PP->new->utf8->canonical->encode($r);
die 'result exceeds 64 KiB' if length($json)>65536;
# Result is the completion marker; parent must also require normal exit.
write_new('result.json',$json);
exit 0;
