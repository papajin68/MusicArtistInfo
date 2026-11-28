use strict;
use warnings;
use Test::More;
require './Mosaicly/ScanSession.pm';
require './Mosaicly/ScanAdmission.pm';
$INC{'Plugins/MusicArtistInfoMosaicly/Mosaicly/ScanSession.pm'}=1;
$INC{'Plugins/MusicArtistInfoMosaicly/Mosaicly/ScanAdmission.pm'}=1;
{
    package Slim::Control::Request;
    our (%dispatch,%listeners);
    sub addDispatch {
        my ($verbs,$data)=@_;
        my $old=$dispatch{$verbs->[0]};
        $dispatch{$verbs->[0]}=$data->[3];
        return $old;
    }
    sub subscribe { $listeners{$_[0]}=$_[0] }
    sub unsubscribe { delete $listeners{$_[0]} }
    package Slim::Utils::Timers;
    our @timers;
    sub setTimer { push @timers,$_[2] }
    package Slim::Music::Import;
    our ($flag,$scanning,$launches,$aborts)=(0,0,0,0);
    our @queue;
    sub doQueueScanTasks { $flag=$_[1] if @_>1; $flag }
    sub scanningProcess { undef }
    sub stillScanning { $scanning }
    sub hasScanTask { scalar @queue }
    sub clearScanQueue { @queue=() }
    sub queueScanTask {
        my ($class,$r)=@_;
        @queue=() if $r->{type} eq 'wipecache';
        push @queue,{type=>$r->{type}} unless grep {$_->{type} eq $r->{type}} @queue;
    }
    sub nextScanTask {
        return if $scanning;
        my $r=shift @queue or return;
        $Slim::Control::Request::dispatch{$r->{type}}->($r);
    }
    sub abortScan { ++$aborts; @queue=() if $scanning; return 9 }
    sub launchScan { ++$launches; return 7 }
}
$INC{'Slim/Control/Request.pm'}=1;
$INC{'Slim/Utils/Timers.pm'}=1;
$INC{'Slim/Music/Import.pm'}=1;
require './Mosaicly/ScanAdapter.pm';
my $native=sub {
    my ($r)=@_;
    if (Slim::Music::Import->stillScanning || Slim::Music::Import->doQueueScanTasks) {
        Slim::Music::Import->queueScanTask($r);
        $r->{queued}=1;
    } else {
        $r->{launched}=Slim::Music::Import->launchScan({});
    }
    $r->{done}=1;
};
$Slim::Control::Request::dispatch{$_}=$native for qw(rescan wipecache);
my $oldNext=Slim::Music::Import->can('nextScanTask');
Slim::Control::Request::subscribe($oldNext,[['rescan'],['done']]);
my ($ready,$invalidations)=(1,0);
my $owner=Plugins::MusicArtistInfoMosaicly::Mosaicly::ScanAdapter->install(
    enabled=>sub {0}, invalidate=>sub {++$invalidations},
    drain=>sub {$ready}, completed=>sub {die 'unexpected completion'},
    report=>sub {},random=>sub {'a' x (2*$_[0])},
);
sub request {
    my ($type)=@_;
    my $r={type=>$type};
    $Slim::Control::Request::dispatch{$type}->($r);
    return $r;
}
sub tick {
    my $cb=shift @Slim::Utils::Timers::timers or die 'no timer';
    $cb->();
}
ok(!exists $Slim::Control::Request::listeners{$oldNext},'old unguarded listener removed');
is(scalar keys %Slim::Control::Request::listeners,1,'single guarded listener');
my $r=request('rescan');
ok($r->{done} && $r->{launched}==7,'idle native handler launches and completes');
is($Slim::Music::Import::launches,1,'one native launch');
$ready=0;
$r=request('rescan');
ok($r->{done} && $r->{queued} && !$r->{launched},'native queue acknowledgement only');
ok($owner->admissionPending,'owner exposes pending admission');
request('rescan');
is(scalar @Slim::Music::Import::queue,1,'native dedup retained');
request('wipecache');
is_deeply([map {$_->{type}} @Slim::Music::Import::queue],['wipecache'],'native wipe supersession retained');
$_->() for values %Slim::Control::Request::listeners;
is(scalar @Slim::Music::Import::queue,1,'notification cannot dequeue during hold');
ok(!eval {Slim::Music::Import->launchScan({}); 1},'direct bypass raises failure');
like($@,qr/scanner not launched/,'direct bypass error truthful');
is($Slim::Music::Import::launches,1,'no blocked native launch');
is(scalar @Slim::Utils::Timers::timers,1,'single drain retry');
Slim::Music::Import->doQueueScanTasks(1);
$ready=1;
tick();
is($Slim::Music::Import::launches,1,'native flag preserves hold after drain');
Slim::Music::Import->doQueueScanTasks(0);
ok(Slim::Music::Import->doQueueScanTasks,'Mosaicly hold independent of native setter');
tick();
is($Slim::Music::Import::launches,2,'native launch after verified drain');
ok(!$owner->admissionPending,'owner no longer pending');
ok(!Slim::Music::Import->doQueueScanTasks,'native flag restored unchanged');
$ready=0;
request('rescan');
is(Slim::Music::Import->abortScan,9,'native abort return preserved');
is($Slim::Music::Import::aborts,1,'native abort invoked');
is(scalar @Slim::Music::Import::queue,0,'abort cancels held request while scanner idle');
ok($owner->admissionPending,'abort does not release worker hold');
$ready=1;
tick();
is($Slim::Music::Import::launches,2,'cancelled request not launched');
$ready=0;
request('rescan');
$owner->shutdown;
$ready=1;
tick();
is($Slim::Music::Import::launches,2,'shutdown prevents deferred scan launch');
ok($owner->admissionPending,'shutdown prevents generation admission');
done_testing;
