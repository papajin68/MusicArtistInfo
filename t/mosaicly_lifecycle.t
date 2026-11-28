use strict;
use warnings;
use Test::More;
require './Mosaicly/Lifecycle.pm';
my $class='Plugins::MusicArtistInfo::Mosaicly::Lifecycle';
{
    package FakeServer;
    sub shutdown { ++$_[0]{shutdowns}; return 0 }
}
my ($enabled,$builds,$error,$fail)=(0,0,'',0);
my %guards;
my $owner=$class->new(
    enabled=>sub {$enabled},
    report=>sub {$error=$_[0]},
    build=>sub {
        ++$builds;
        %guards=@_;
        die 'test unavailable' if $fail;
        bless {shutdowns=>0},'FakeServer';
    });
$owner->refresh;
is($builds,0,'disabled does not load runtime');
is($owner->epoch,1,'refresh invalidates epoch');
$enabled=1;
$fail=1;
$owner->refresh;
like($error,qr/test unavailable/,'failure reported');
ok(!$owner->server,'failure leaves no server');
$fail=0;
ok($owner->refresh,'enabled constructs server');
my $server=$owner->server;
ok($server,'server owned');
ok(!$guards{admit}->(),'admission stays closed');
ok(!$guards{current}->($owner->epoch),'publication stays closed');
$owner->refresh;
is($builds,2,'no duplicate server');
$enabled=0;
$owner->refresh;
is($owner->server,$server,'disable retains ownership');
$enabled=1;
$owner->refresh;
is($owner->server,$server,'reenable reuses owner');
ok(!$owner->shutdown,'busy shutdown reported');
is($server->{shutdowns},1,'shutdown delegated');
is($owner->server,$server,'shutdown retains process owner');
$owner->refresh;
is($builds,2,'shutdown prevents construction');

SKIP: {
    skip 'Linux runtime filesystem policy', 14 unless $^O eq 'linux';
    require File::Temp;
    require './Mosaicly/Runtime.pm';
    my $root=File::Temp::tempdir(CLEANUP=>1);
    mkdir "$root/cache" or die $!;
    mkdir "$root/temp" or die $!;
    my $runtime='Plugins::MusicArtistInfo::Mosaicly::Runtime';
    my %args=(cache=>"$root/cache",temporary=>"$root/temp");
    my $p=$runtime->paths(%args);
    ok(-d $p->{jobs},'jobs directory');
    ok(-d $p->{portraits},'portrait directory');
    is($p->{ownership},$runtime->ownershipPath("$root/cache"),'persistent cache marker path');
    ok($runtime->ownershipClear($p->{ownership}),'marker absent');
    mkdir $p->{ownership},0700 or die $!;
    ok(!$runtime->ownershipClear($p->{ownership}),'marker blocks independent admission');
    is_deeply($runtime->paths(%args),$p,'runtime initialization retains persistent marker');
    ok(-d $p->{ownership},'persistent marker not cleared by initialization');
    isnt($p->{jobs},$p->{portraits},'separate roots');
    is((stat($p->{jobs}))[2]&07777,0700,'private jobs');
    is((stat($p->{portraits}))[2]&07777,0700,'private portraits');
    mkdir "$p->{jobs}/active" or die $!;
    is_deeply($runtime->paths(%args),$p,'stable roots');
    ok(-d "$p->{jobs}/active",'retains existing reservation');
    chmod 0755,$p->{jobs} or die $!;
    ok(!eval {$runtime->paths(%args);1},'reject unsafe existing root');
    chmod 0700,$p->{jobs} or die $!;
    ok(!eval {$runtime->paths(cache=>"$root/missing",temporary=>"$root/temp");1},'reject missing cache');
}
done_testing;
