use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use Mosaicly::Experimental::ScanSessionV2;
my $E = 'e' x 32;
my $E2 = 'f' x 32;
my $A = 'a' x 32;
my $AT = '1' x 32;
my $B = 'b' x 32;
my $BT = '2' x 32;
my $C = 'c' x 32;
my $CT = '3' x 32;
my $now = 0;
sub model {
    Mosaicly::Experimental::ScanSessionV2->new(
        clock => sub { $now }, boot_epoch => $E,
        lease_seconds => 300, completion_seconds => 30,
        tombstone_limit => 20, @_
    );
}
my $m = model();
is($m->status, 'IDLE', 'initial idle');
ok($m->register($E,$A,$AT), 'register A');
is($m->status, 'REGISTERED', 'registered');
ok(!$m->register($E,$A,$AT), 'duplicate active register denied');
ok(!$m->register($E,$B,$BT), 'different simultaneous scanner rejected');
ok(!$m->ack($E,$B,$BT), 'stale B ack cannot alter A');
ok(!$m->verify($E,$B,$BT), 'mismatched verify denied');
is($m->status,'REGISTERED','mismatched verify does not destroy A');
ok($m->heartbeat($E,$A,$AT),'heartbeat A');
ok($m->ack($E,$A,$AT),'ACK A');
ok(!$m->ack($E,$A,$AT),'duplicate ACK A rejected');
ok(!$m->heartbeat($E,$A,$AT),'heartbeat cannot extend completion');
ok($m->verify($E,$A,$AT),'verify A once');
is($m->status,'IDLE','consumed active cleared');
ok(!$m->verify($E,$A,$AT),'reverify A false');
ok(!$m->ack($E,$A,$AT),'reack A false');
ok(!$m->register($E,$A,$AT),'re-register consumed A rejected');
ok(!$m->register($E,$A,$CT),'re-register same ID with new token rejected');
ok(!$m->register($E,$C,$AT),'re-register new ID with consumed token rejected');
ok($m->register($E,$B,$BT),'register B after A');
ok(!$m->ack($E,$A,$AT),'stale A ack cannot authorize B');
ok(!$m->verify($E,$A,$AT),'stale A verify cannot authorize B');
is($m->status,'REGISTERED','B survives stale A');
ok($m->ack($E,$B,$BT),'ack B');
ok($m->verify($E,$B,$BT),'verify B');

$now=0; $m=model();
ok($m->register($E,$A,$AT),'long scan start');
for my $step (1..60) {
    $now += 60;
    ok($m->heartbeat($E,$A,$AT),"heartbeat at ${now}s");
}
ok($m->ack($E,$A,$AT),'long scan ACK after one hour');
ok($m->verify($E,$A,$AT),'long scan verify after one hour');

$now=0; $m=model();
ok($m->register($E,$A,$AT),'expiry start');
$now=301;
is($m->status,'IDLE','lease expired');
ok(!$m->heartbeat($E,$A,$AT),'expired heartbeat rejected');
ok(!$m->ack($E,$A,$AT),'expired ack rejected');
ok(!$m->verify($E,$A,$AT),'expired verify rejected');
ok(!$m->register($E,$A,$AT),'expired token cannot re-register');
ok($m->register($E,$B,$BT),'new B after expiry');

$now=0; $m=model();
ok($m->register($E,$A,$AT),'completion lease start');
ok($m->ack($E,$A,$AT),'completion ACK');
$now=31;
ok(!$m->verify($E,$A,$AT),'completion authorization expires');
ok(!$m->register($E,$A,$AT),'completed timeout tombstoned');

$now=0; $m=model();
ok($m->register($E,$A,$AT),'verify preack register');
ok(!$m->verify($E,$A,$AT),'verify before ACK denied');
ok(!$m->ack($E,$A,$AT),'no late ack after deny');
ok(!$m->register($E,$A,$AT),'denied token retired');

$now=0; $m=model();
ok($m->register($E,$A,$AT),'cancel register');
ok($m->cancel($E,$A,$AT),'cancel active');
ok(!$m->cancel($E,$A,$AT),'duplicate cancel rejected');
ok(!$m->register($E,$A,$AT),'cancelled token retired');

$now=0; $m=model();
ok(!$m->register($E2,$A,$AT),'wrong epoch register rejected');
ok($m->register($E,$A,$AT),'valid epoch accepted');
ok(!$m->ack($E2,$A,$AT),'wrong epoch ack rejected');
ok(!$m->verify($E2,$A,$AT),'wrong epoch verify rejected');
is($m->status,'REGISTERED','wrong epoch non-destructive');
ok(!$m->register($E,'not-hex',$AT),'bad id register rejected');
ok(!$m->ack($E,$A,'xyz'),'bad token ack rejected');
ok(!$m->verify($E,$A,undef),'missing token verify rejected');
ok($m->ack($E,$A,$AT),'valid ACK survives malformed requests');
ok($m->verify($E,$A,$AT),'valid verify survives malformed requests');

$now=0; $m=model(tombstone_limit=>2);
ok($m->register($E,$A,$AT),'capacity one registration');
ok($m->ack($E,$A,$AT),'capacity ACK');
ok($m->verify($E,$A,$AT),'capacity verify');
is($m->retired_count,2,'two tombstone digests');
ok(!$m->register($E,$B,$BT),'capacity full blocks next registration');
ok(!$m->register($E,$A,$AT),'capacity full cannot revive A');

$now=100; $m=model();
ok($m->register($E,$A,$AT),'clock test start');
$now=99;
ok(!$m->ack($E,$A,$AT),'clock rollback denies');
is($m->status,'CLOCK_INVALID','clock failure permanently fail closed');
$now=1000;
ok(!$m->register($E,$B,$BT),'clock failure blocks new sessions');

$now=0; my $old=model();
ok($old->register($E,$A,$AT),'old boot register');
my $fresh=Mosaicly::Experimental::ScanSessionV2->new(clock=>sub{$now},boot_epoch=>$E2);
ok(!$fresh->ack($E,$A,$AT),'new server refuses old epoch ack');
ok(!$fresh->verify($E,$A,$AT),'new server refuses old epoch verify');
ok($fresh->register($E2,$A,$AT),'new epoch permits fresh registration of same id/token bytes');

$now=0; $m=model();
ok(!$m->register($E,$A,$A),'same token and id rejected');
ok($m->register($E,$A,$AT),'normal after invalid request');

done_testing();
