use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
use FindBin;
use lib "$FindBin::Bin/..";
BEGIN {
    require "$FindBin::Bin/../Mosaicly/Process.pm";
}
my $class='Plugins::MusicArtistInfo::Mosaicly::Process';
plan skip_all=>'Linux process adapter' unless $class->supported;

my $root=tempdir(CLEANUP=>1);
my $n=0;
sub launch {
    my (@cmd)=@_;
    my $dir=File::Spec->catdir($root,++$n);
    mkdir $dir or die $!;
    return $class->launch(argv=>\@cmd,directory=>$dir,log=>"$dir/worker.log");
}
sub terminal {
    my ($p)=@_;
    my $deadline=time()+5;
    while (time()<$deadline) {
        my $r=$p->poll;
        return $r if $r->{state} ne 'running' && $r->{state} ne 'unresolved';
        sleep 0.02;
    }
    die 'child did not terminate within test deadline';
}
my $r=launch($^X,'-e','select undef,undef,undef,0.3; exit 0');
ok($r->{ok},'spawn independent process');
is($r->{process}->poll->{state},'running','nonblocking poll');
is_deeply(terminal($r->{process}),{state=>'exited',exit_code=>0},'normal exit');
is_deeply($r->{process}->poll,{state=>'exited',exit_code=>0},'cached status');
$r=launch($^X,'-e','exit 7');
is_deeply(terminal($r->{process}),{state=>'exited',exit_code=>7},'nonzero exit');
$r=launch($^X,'-e','kill "KILL", $$');
is_deeply(terminal($r->{process}),{state=>'signaled',signal=>9},'signal exit');
$r=launch($^X,'-e','exit 0');
my $p=$r->{process};
is(waitpid($p->{pid},0),$p->{pid},'simulate external reap');
is_deeply($p->poll,{state=>'unknown',reason=>'exit_status_lost'},'lost status fails closed');
$r=launch('/definitely/not/a/program');
is($r->{reason},'invalid_command','nonexistent executable rejected');
$r=launch($^X,'-e','print $ARGV[0]', 'literal ; $()');
is(terminal($r->{process})->{exit_code},0,'literal argument accepted');
open my $fh,'<',"$root/$n/worker.log" or die $!;
is(do {local $/; <$fh>},'literal ; $()','no shell interpretation');
close $fh;
done_testing;
