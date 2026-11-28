use strict;
use warnings;
use Test::More;
require './Mosaicly/Scheduler.pm';
require './Mosaicly/Lifecycle.pm';
my $class='Plugins::MusicArtistInfo::Mosaicly::Scheduler';
my ($current,@timers,@starts,@reports,@done,@pages,$limit,$page,$start);
sub fixture {
    ($current,$limit)=(1,40);
    @timers=@starts=@reports=@done=@pages=();
    $page=sub {my ($after,$high,$size)=@_; push @pages,[@_]; return [grep {$_>$after && $_<=$high} (1,3,40)]};
    $start=sub {push @starts,[$_[0],$_[1]]; push @done,$_[2]; return {ok=>1}};
    return $class->new(current=>sub {$current && $_[0]==7},limit=>sub {$limit},
        page=>sub {$page->(@_)},start=>sub {$start->(@_)},
        schedule=>sub {push @timers,$_[0]},report=>sub {push @reports,[@_]});
}
sub tick {my $cb=shift @timers or die 'missing timer'; $cb->()}
sub done {my $cb=shift @done or die 'missing worker'; $cb->($_[0]); return $cb}
my $s=fixture();
ok(!$s->active,'idle without authentication');
ok(!$s->begin(6),'stale epoch rejected');
is(scalar @timers,0,'no stale timer');
ok($s->begin(7),'current epoch accepted');
ok(!$s->begin(7),'duplicate begin rejected');
is(scalar @starts,0,'begin asynchronous');
tick();
is_deeply(\@pages,[[0,40,32]],'bounded discovery');
is_deeply(\@starts,[[1,7]],'first artist only');
is(scalar @timers,0,'no timer while worker active');
my $old=done({ok=>1});
is(scalar @timers,1,'completion schedules next');
$old->({ok=>1});
is(scalar @timers,1,'duplicate completion ignored');
tick();
is_deeply($starts[-1],[3,7],'second artist');
done({ok=>0,reason=>'local_artwork'});
tick();
is_deeply($starts[-1],[40,7],'third artist');
done({ok=>0,reason=>'worker_exit'});
tick();
ok(!$s->active,'completed epoch released');
is_deeply($reports[-1],['complete',{generated=>1,skipped=>1,failed=>1,deferred=>0}],'completion counts');
$s=fixture(); $s->begin(7); tick();
$current=0;
done({ok=>1});
ok(!$s->active,'obsolete callback cannot advance');
is(scalar @timers,0,'no next obsolete worker');
$s=fixture(); $s->begin(7); $s->cancel; tick();
is(scalar @starts,0,'cancelled timer cannot start');
$s=fixture(); $s->begin(7); tick(); $s->cancel;
$old=done({ok=>1});
ok(!$s->active,'cancelled worker callback ignored');
ok($s->begin(7),'new run after cancellation');
$old->({ok=>1});
is(scalar @timers,1,'old callback cannot affect new run');
tick(); done({ok=>0,reason=>'termination_unverified'});
ok(!$s->active,'unresolved termination stops pass');
is($reports[-1][1]{deferred},1,'deferred outcome counted');
$s=fixture(); $start=sub {{ok=>0,reason=>'admission_denied'}};
$s->begin(7); tick();
ok(!$s->active,'pressure/admission rejection stops pass');
is(scalar @timers,0,'no pressure retry loop');
$s=fixture(); $page=sub {[3,1]};
$s->begin(7); tick();
is($reports[-1][0],'invalid_page','unordered IDs fail closed');
$s=fixture(); $page=sub {[1..33]};
$s->begin(7); tick();
is($reports[-1][0],'discovery_failed','oversized page rejected');
$s=fixture(); $page=sub { $current=0; return [1] };
$s->begin(7); tick();
is(scalar @starts,0,'invalidate during discovery prevents start');
$s=fixture(); $limit=0; $s->begin(7); tick();
is($reports[-1][0],'complete','empty library completes');
is(scalar @pages,0,'empty library no page query');

# Normal lifecycle guards remain closed unless explicitly activated in test.
my ($activation,$enabled,$safe,$resource)=(0,1,1,1);
my (%guards,@callbacks,@jobs,@summary);
{
    package SchedulerTestServer;
    sub shutdown {1}
}
my $owner=Plugins::MusicArtistInfo::Mosaicly::Lifecycle->new(
    enabled=>sub {$enabled}, activation=>sub {$activation},
    safe=>sub {$safe},resource=>sub {$resource},report=>sub {},
    build=>sub {%guards=@_; bless {},'SchedulerTestServer'},
    schedulerBuild=>sub {
        my ($o)=@_;
        return $class->new(current=>sub {$o->current($_[0])},
            limit=>sub {1},page=>sub {[1]},
            start=>sub {push @jobs,[@_]; return {ok=>1}},
            schedule=>sub {push @callbacks,$_[0]},report=>sub {push @summary,[@_]});
    });
$owner->refresh;
ok(!$owner->completed(1),'closed gate rejects authenticated completion');
ok(!$guards{admit}->(),'closed gate rejects worker');
$activation=1;
ok(!$guards{current}->($owner->epoch),'idle alone not authorization');
ok($owner->completed(1),'authenticated completion starts epoch');
ok($guards{current}->($owner->epoch),'current epoch authorized');
ok($guards{admit}->(),'safe resource admission');
$resource=0;
ok(!$guards{admit}->(),'resource check independent');
ok($guards{current}->($owner->epoch),'resource pressure does not itself authorize or invalidate publication');
$resource=1;
$callbacks[0]->(); shift @callbacks;
is(scalar @jobs,1,'one lifecycle job');
$owner->refresh;
ok(!$guards{current}->($jobs[0][1]),'refresh invalidates prior publication');
$jobs[0][2]->({ok=>1});
is(scalar @callbacks,0,'obsolete completion cannot schedule');
ok(!$owner->completed(1),'duplicate scan completion rejected');
ok($owner->completed(2),'next authenticated epoch accepted');
$safe=0;
shift(@callbacks)->();
ok(!$guards{admit}->(),'unsafe scanner state blocks admission');
ok(!$guards{current}->($owner->epoch),'finished invalidated epoch not current');
$owner->shutdown;
ok(!$owner->completed(3),'shutdown rejects completion');
done_testing;
