use strict;
use warnings;
use Test::More;
require './Mosaicly/ScanAdmission.pm';

my ($ready,$nativeFlag,$scanning,$invalidations,$launches,$clears)=(1,0,0,0,0,0);
my (@queue,@timers);
my $admission=Plugins::MusicArtistInfo::Mosaicly::ScanAdmission->new(
    invalidate=>sub {++$invalidations},
    drain=>sub {$ready},
    schedule=>sub {push @timers,$_[0]},
    queued=>sub {scalar @queue},
    nativeQueue=>sub {$nativeFlag},
    scanning=>sub {$scanning},
    next=>sub {++$launches; shift @queue},
    clear=>sub {++$clears; @queue=()},
);
sub tick { my $cb=shift @timers or die 'no timer'; $cb->() }
ok($admission->intent,'idle intent admitted');
is($invalidations,1,'intent invalidates');
ok(!$admission->pending,'idle admission not held');
is(scalar @timers,0,'idle no retry timer');
$ready=0;
ok(!$admission->intent,'active worker blocks admission');
ok($admission->held,'hold visible to queue predicate');
ok($admission->pending,'new generation blocked');
push @queue,'rescan';
$admission->next;
is_deeply(\@queue,['rescan'],'blocked next does not consume queue');
is($launches,0,'no native next while draining');
ok(!$admission->intent,'repeated request still held');
is(scalar @timers,1,'one retry timer');
tick();
is_deeply(\@queue,['rescan'],'ambiguous termination retains request');
is(scalar @timers,1,'retry remains scheduled');
# Native queue can supersede an older request during the hold.
@queue=('wipecache');
$ready=1;
$nativeFlag=1;
tick();
is_deeply(\@queue,['wipecache'],'native queue flag respected');
$nativeFlag=0;
$scanning=1;
tick();
is($launches,0,'native active scan prevents release');
$scanning=0;
tick();
is($launches,1,'verified readiness dispatches native next once');
is_deeply(\@queue,[],'native queue consumed by native next only');
ok(!$admission->pending,'hold released');
is(scalar @timers,0,'no timer after release');
$ready=0;
$admission->intent;
push @queue,'rescan';
$admission->abort;
is($clears,1,'abort clears held native queue');
is_deeply(\@queue,[],'abort removes queued scan');
ok($admission->held,'abort does not establish termination');
tick();
is($launches,1,'aborted scan not launched');
$ready=1;
tick();
ok(!$admission->held,'verified drain clears aborted hold');
is($launches,1,'no launch after abort');
$scanning=1;
my $before=$invalidations;
$admission->abort;
is($invalidations,$before+1,'native active scanner abort invalidates authorization without hold');
is($clears,1,'native abort owns ordinary queue clearing');
ok(!$admission->held,'ordinary abort does not introduce a hold');
$scanning=0;
$nativeFlag=1;
ok($admission->pending,'native queue flag blocks generation independently');
ok(!$admission->held,'native flag does not become Mosaicly hold');
$nativeFlag=0;
push @queue,'rescan';
ok($admission->pending,'queued request independently blocks generation');
$ready=0;
$admission->next;
is($launches,1,'preexisting native queue protected');
$admission->shutdown;
$ready=1;
tick();
is($launches,1,'shutdown prevents timer dispatch');
ok($admission->pending,'shutdown blocks generation');
ok(!eval {$admission->intent; 1},'shutdown prevents direct launch admission');
done_testing;
