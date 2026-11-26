use strict;
use warnings;
use Test::More;
BEGIN {
    plan skip_all=>'Linux timeout/prlimit required'
        unless $^O eq 'linux' && -x '/usr/bin/timeout' && -x '/usr/bin/prlimit';
}
use FindBin;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use Time::HiRes qw(time sleep);
BEGIN {
    my $p="$FindBin::Bin/../Mosaicly/Process.pm";
    require $p;
    $INC{'Plugins/MusicArtistInfo/Mosaicly/Process.pm'}=$p;
    require "$FindBin::Bin/../Mosaicly/Coordinator.pm";
}
my $root=abs_path(tempdir(CLEANUP=>1));
my $script="$root/mock-worker.pl";
open my $fh,'>',$script or die $!;
print {$fh} <<'WORKER';
use strict;
use warnings;
use JSON::PP;
use Digest::SHA qw(sha256_hex);
my ($dir)=@ARGV;
open my $f,'<:raw',"$dir/job.json" or die $!;
my $raw=do {local $/; <$f>};
close $f;
my $job=JSON::PP->new->utf8->decode($raw);
my $mode=$job->{diagnostics}{mode};
exit 4 if $mode eq 'exit';
exit 137 if $mode eq 'ambiguous';
exit 0 if $mode eq 'missing';
# Synthetic JPEG envelope only: this test exercises transport validation,
# not image decoding or native rendering.
my $jpeg="\xff\xd8test\xff\xd9";
my $r={ok=>1,contributor_id=>$job->{contributor_id},
    job_sha256=>sha256_hex($raw),width=>600,height=>600,
    content_type=>'image/jpeg',jpeg_bytes=>length($jpeg),
    jpeg_sha256=>sha256_hex($jpeg),
    sources=>[{album_id=>2,artwork_id=>'12345678',track_id=>3,
        source_kind=>'external',sha256=>'a'x64}]};
$r->{job_sha256}='0'x64 if $mode eq 'stale';
$r->{jpeg_sha256}='0'x64 if $mode eq 'digest';
$r->{sources}[0]{track_id}=4 if $mode eq 'source';
$r->{ok}=0 if $mode eq 'failure';
for my $pair (['portrait.jpg',$jpeg],['result.json',JSON::PP->new->utf8->encode($r)]) {
    open my $o,'>:raw',"$dir/$pair->[0]" or die $!;
    print {$o} $pair->[1] or die $!;
    close $o or die $!;
}
exit 7 if $mode eq 'nonzero';
WORKER
close $fh;
my $c='Plugins::MusicArtistInfo::Mosaicly::Coordinator'->new(
    root=>$root,library=>$root,worker=>$script,includes=>[],perl=>abs_path($^X));
sub job {
    my ($mode)=@_;
    return {ok=>1,contributor_id=>1,entries=>[
        {candidate=>{album_id=>2},source=>{ok=>1,album_id=>2,
        artwork_id=>'12345678',track_id=>3,source_kind=>'external'}}
    ],diagnostics=>{mode=>$mode}};
}
sub finish {
    my $deadline=time()+5;
    while(time()<$deadline) {
        my $r=$c->poll;
        return $r if $r->{state} eq 'complete';
        sleep 0.02;
    }
    die 'worker did not finish';
}
is($c->poll->{state},'idle','idle before launch');
ok($c->start(job('valid'))->{ok},'launch');
is($c->start(job('valid'))->{reason},'busy','one reservation');
my $r=finish();
ok($r->{ok},'valid result accepted');
is($r->{bytes},"\xff\xd8test\xff\xd9",'bytes returned');
is($r->{process}{exit_code},0,'actual exit status');
ok(!$c->busy,'cleaned successful job');
for my $pair (['exit','worker_exit'],['missing','invalid_result'],
    ['stale','invalid_result'],['digest','invalid_result'],
    ['source','invalid_result'],['failure','generation_failed'],
    ['nonzero','worker_exit']) {
    ok($c->start(job($pair->[0]))->{ok},"launch $pair->[0]");
    $r=finish();
    is($r->{reason},$pair->[1],"reject $pair->[0]");
    ok(!$c->busy,"release completed $pair->[0]");
}
my $big=job('valid');
$big->{diagnostics}{padding}='x'x262144;
is($c->start($big)->{reason},'invalid_job','oversized job refused');
mkdir "$root/active",0700 or die $!;
is($c->start(job('valid'))->{reason},'busy','stale directory blocks admission');
rmdir "$root/active" or die $!;
ok($c->start(job('ambiguous'))->{ok},'launch ambiguous wrapper status');
$r=finish();
is($r->{reason},'termination_unverified','ambiguous status fails closed');
ok($c->busy,'ambiguous status retains reservation');
is($c->start(job('valid'))->{reason},'busy','no overlapping worker after ambiguous termination');
done_testing;
