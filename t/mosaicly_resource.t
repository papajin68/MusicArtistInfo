use strict;
use warnings;
use Test::More;
require './Mosaicly/Resource.pm';
my $class='Plugins::MusicArtistInfo::Mosaicly::Resource';
my $base='/sys/fs/cgroup';
my $quiet="some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n";
my %f;
sub fixture {
    %f=(
        '/proc/meminfo'=>"MemAvailable: 1048576 kB\n",
        '/proc/pressure/memory'=>$quiet,
        '/proc/self/cgroup'=>"0::/lab\n",
        '/proc/self/mountinfo'=>"30 20 0:29 / /sys/fs/cgroup rw,nosuid - cgroup2 cgroup rw\n",
        "$base/cgroup.controllers"=>"cpu memory io\n",
        "$base/lab/memory.current"=>"268435456\n",
        "$base/lab/memory.max"=>"1073741824\n",
        "$base/lab/memory.high"=>"max\n",
        "$base/lab/memory.pressure"=>$quiet,
    );
}
sub check { $class->check(read=>sub {$f{$_[0]}},absent=>sub {!exists $f{$_[0]}}) }
sub reason { check()->{reason} }
fixture(); ok(check()->{ok},'host and finite cgroup headroom');
$f{'/proc/meminfo'}="MemAvailable: 524287 kB\n";
is(reason(),'host_memory_low','insufficient host headroom');
$f{'/proc/meminfo'}="MemAvailable: 524288 kB\n";
ok(check()->{ok},'exact host minimum admitted');
delete $f{'/proc/meminfo'};
is(reason(),'host_memory_unknown','missing host memory fails closed');
fixture(); $f{'/proc/meminfo'}="MemAvailable: unknown kB\n";
is(reason(),'host_memory_unknown','malformed host memory fails closed');
fixture(); delete $f{'/proc/pressure/memory'};
is(reason(),'host_pressure_unknown','unknown pressure fails closed');
fixture(); $f{'/proc/pressure/memory'}=$quiet =~ s/some avg10=0.00/some avg10=1.00/r;
is(reason(),'host_memory_pressure','host some pressure threshold');
fixture(); $f{'/proc/pressure/memory'}=$quiet =~ s/full avg10=0.00/full avg10=0.01/r;
is(reason(),'host_memory_pressure','host full pressure');
fixture(); $f{"$base/lab/memory.max"}="805306367\n";
is(reason(),'cgroup_memory_low','finite max insufficient');
$f{"$base/lab/memory.max"}="805306368\n";
ok(check()->{ok},'exact finite minimum admitted');
$f{"$base/lab/memory.high"}="805306367\n";
is(reason(),'cgroup_memory_low','high limit respected');
fixture(); $f{"$base/lab/memory.max"}="max\n";
ok(check()->{ok},'unlimited max allowed with host guard');
delete $f{"$base/lab/memory.current"};
is(reason(),'cgroup_memory_unknown','missing child current fails closed');
fixture(); $f{"$base/lab/memory.max"}="garbage\n";
is(reason(),'cgroup_memory_unknown','malformed limit fails closed');
fixture(); $f{"$base/lab/memory.pressure"}=$quiet =~ s/full avg10=0.00/full avg10=0.01/r;
is(reason(),'cgroup_memory_pressure','cgroup pressure checked');
delete $f{"$base/lab/memory.pressure"};
is(reason(),'cgroup_pressure_unknown','missing cgroup pressure fails closed');
fixture(); $f{"$base/memory.current"}="536870912\n";
$f{"$base/memory.max"}="805306368\n";
$f{"$base/memory.high"}="max\n";
$f{"$base/memory.pressure"}=$quiet;
is(reason(),'cgroup_memory_low','visible ancestor limit checked');
$f{"$base/memory.max"}="1073741824\n";
ok(check()->{ok},'visible ancestor sufficient');
fixture(); $f{"$base/memory.max"}="max\n";
is(reason(),'cgroup_memory_unknown','partial root readings rejected');
fixture(); delete $f{"$base/cgroup.controllers"};
is(reason(),'cgroup_memory_unknown','unknown unlimited root rejected');
fixture(); $f{'/proc/self/cgroup'}="5:memory:/lab\n";
is(reason(),'cgroup_unavailable','v1-only unsupported');
fixture(); $f{'/proc/self/cgroup'}="0::/../lab\n";
is(reason(),'cgroup_unavailable','unsafe path rejected');
fixture(); delete $f{'/proc/self/mountinfo'};
is(reason(),'cgroup_mount_unknown','unknown mount rejected');
fixture(); $f{'/proc/self/mountinfo'}="30 20 0:29 /other /sys/fs/cgroup rw - cgroup2 cgroup rw\n";
is(reason(),'cgroup_path_unknown','unmapped cgroup rejected');
fixture(); $f{'/proc/self/cgroup'}="0::/\n";
$f{'/proc/self/mountinfo'}="30 20 0:29 /docker/lab /sys/fs/cgroup rw - cgroup2 cgroup rw\n";
for my $name (qw(memory.current memory.max memory.high memory.pressure)) {
    $f{"$base/$name"}=delete $f{"$base/lab/$name"};
}
ok(check()->{ok},'namespace-relative constrained root');
delete $f{"$base/memory.current"};
is(reason(),'cgroup_memory_unknown','namespace root missing current rejected');
done_testing;
