use strict;
use warnings;
use Test::More;
require './Mosaicly/ScanSession.pm';
{
    package FakeScan;
    sub alive { $_[0]{alive} }
    sub wait { $_[0]{status} }
}
my ($process,$enabled,$invalidations)=(undef,1,0);
my (@timers,@completed,@events);
my $owner=Plugins::MusicArtistInfoMosaicly::Mosaicly::ScanSession->new(
    enabled=>sub {$enabled}, process=>sub {$process},
    schedule=>sub {push @timers,[@_]},
    completed=>sub {push @completed,$_[0]},
    invalidate=>sub {++$invalidations}, report=>sub {},
    observe=>sub {push @events,$_[0]},
    random=>sub {'a' x (2*$_[0])});
my @credentials;
sub native {
    @credentials=split /:/,$ENV{MOSAICLY_SESSION_V2}//'';
    $process=bless {alive=>1,status=>0},'FakeScan';
    return wantarray ? ('a','b') : 7;
}
sub transition { $owner->transition($_[0],@credentials) }
sub finish {
    $process->{alive}=0;
    my $t=shift @timers;
    $t->[0]->poll($t->[1]);
}
is($owner->launch(\&native,'Slim::Music::Import',{rescan=>1}),7,'scalar native result');
is(scalar @credentials,3,'inherited capability');
is($credentials[1],1,'first session');
ok(!$owner->transition('claim','bad',@credentials[1,2]),'wrong boot denied');
ok(!transition('verify'),'premature verification denied');
ok(transition('claim'),'claim');
ok(!transition('claim'),'duplicate claim denied');
ok(transition('ack'),'ack');
ok(!transition('ack'),'duplicate ack denied');
ok(transition('verify'),'verify');
ok(!transition('verify'),'duplicate verify denied');
my $t=shift @timers;
$t->[0]->poll($t->[1]);
is(scalar @completed,0,'live scanner cannot authorize');
finish();
is_deeply(\@completed,[1],'successful exit authorizes once');
is_deeply(\@events,[qw(process_captured CLAIMED ACKNOWLEDGED CONSUMED exit_verified completion_delivered)],'credential-free positive events in order');
my @old=@credentials;
my @result=$owner->launch(\&native,'Slim::Music::Import',{rescan=>1});
is_deeply(\@result,['a','b'],'list native result');
is($credentials[1],2,'new session ID');
ok(!$owner->transition('claim',@old),'old capability rejected');
ok(transition('claim'),'new claim');
ok(transition('ack'),'new ack');
finish();
is_deeply(\@completed,[1],'missing verify denied');
is($events[-1],'completion_rejected','missing verify observed');
$owner->launch(\&native,'Slim::Music::Import',{rescan=>1});
transition($_) for qw(claim ack verify);
$process->{status}=256;
finish();
is_deeply(\@completed,[1],'failed exit denied');
is($events[-1],'exit_rejected','failed exit observed');
$owner->launch(\&native,'Slim::Music::Import',{rescan=>1});
transition($_) for qw(claim ack verify);
$owner->invalidate;
finish();
is_deeply(\@completed,[1],'invalidated session denied');
# Unsupported native launches preserve native execution but never issue credentials.
for my $args ({playlists=>1},{onlinelibrary=>1},{rescan=>1,singledir=>'/music'},
        {},{wipe=>1,rescan=>1},{rescan=>0},{unknown=>1}) {
    is($owner->launch(\&native,'Slim::Music::Import',$args),7,'unsupported launch preserved');
    is(scalar @credentials,0,'unsupported launch issues no capability');
}
is($owner->launch(\&native,'Slim::Music::Import',{wipe=>1}),7,'full rebuild native result');
is(scalar @credentials,3,'full rebuild receives capability');
transition($_) for qw(claim ack verify);
finish();
is_deeply(\@completed,[1,5],'full rebuild authorizes');
$enabled=0;
is($owner->launch(\&native,'Slim::Music::Import',{rescan=>1}),7,'disabled preserves native launch');
is(scalar @credentials,0,'disabled issues no capability');
$enabled=1;
$owner->launch(\&native,'Slim::Music::Import',{rescan=>1});
transition($_) for qw(claim ack verify);
$owner->shutdown;
finish();
is_deeply(\@completed,[1,5],'shutdown denies completion');
ok($invalidations>=6,'launch and shutdown invalidate');
ok(!(grep { /a{32}/ } @events),'no credentials in events');
$owner->{observe}=sub {die 'log sink failed'};
my $result=eval { $owner->_observe('process_captured'); 1 };
ok($result,'logging failure does not escape');
done_testing;
