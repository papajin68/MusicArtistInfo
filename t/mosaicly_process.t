use strict;
use warnings;
use Test::More;
BEGIN { plan skip_all=>'Linux process adapter' unless $^O eq 'linux' }
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
# Reproduce an initialized-server style tied STDERR without invoking LMS.
# The tie deliberately rejects Perl-level output; OS descriptor redirection
# must still work. Guard the test runner against an escaping forked child.
{
    package MosaiclyTestTrapper;
    sub TIEHANDLE { bless {},shift }
    sub FILENO { 2 }
    sub PRINT { die 'inherited tied PRINT invoked' }
    sub WRITE { die 'inherited tied WRITE invoked' }
    sub UNTIE {}
}
my $original_pid=$$;
my $tied_result;
{
    local *STDERR;
    tie *STDERR,'MosaiclyTestTrapper';
    $tied_result=eval { launch($^X,'-e','$|=1; print STDOUT "out"; print STDERR "err"') };
    POSIX::_exit(98) if $$ != $original_pid;
    untie *STDERR;
}
ok($tied_result && $tied_result->{ok},'launch with inherited tied STDERR');
is_deeply(terminal($tied_result->{process}),{state=>'exited',exit_code=>0},
    'tied STDERR does not prevent exec');
open my $tied_log,'<',"$root/$n/worker.log" or die $!;
is(do {local $/; <$tied_log>},'outerr','both OS streams captured');
close $tied_log;

# Existing log passes parent validation but fails exclusive open after fork.
my $failure_dir=File::Spec->catdir($root,++$n);
mkdir $failure_dir or die $!;
open my $existing,'>',"$failure_dir/worker.log" or die $!;
print {$existing} 'preserved';
close $existing;
{
    local *STDERR;
    tie *STDERR,'MosaiclyTestTrapper';
    $r=eval { $class->launch(argv=>[$^X,'-e','exit 99'],
        directory=>$failure_dir,log=>"$failure_dir/worker.log") };
    POSIX::_exit(98) if $$ != $original_pid;
    untie *STDERR;
}
ok($r && $r->{ok},'deliberate child setup failure admitted by parent');
is_deeply(terminal($r->{process}),{state=>'exited',exit_code=>126},
    'child setup failure terminates without unwinding');
open my $preserved,'<',"$failure_dir/worker.log" or die $!;
is(do {local $/; <$preserved>},'preserved','exclusive log remains unchanged');
close $preserved;
# Run after standalone tests: loading EV changes child-reaping ownership.
SKIP: {
    skip 'native EV unavailable', 7 unless eval { require EV; 1 };
    my $run_ev = sub {
        my ($code)=@_;
        my $dir=File::Spec->catdir($root,++$n);
        mkdir $dir or die $!;
        return $class->launch(argv=>[$^X,'-e',$code],
            directory=>$dir,log=>"$dir/worker.log",ev=>1);
    };
    my $finish_ev = sub {
        my ($child)=@_;
        my $deadline=time()+5;
        while (time()<$deadline) {
            EV::run(EV::RUN_NOWAIT());
            my $status=$child->poll;
            return $status unless $status->{state} eq 'running';
            sleep 0.02;
        }
        die 'EV child status deadline';
    };
    $r=$run_ev->('exit 0');
    ok($r->{ok},'EV child admitted');
    is($r->{process}->poll->{state},'running','EV mode does not reap directly');
    is_deeply($finish_ev->($r->{process}),{state=>'exited',exit_code=>0},
        'EV callback delivers successful termination');
    is_deeply($r->{process}->poll,{state=>'exited',exit_code=>0},'EV status retained');
    $r=$run_ev->('exit 7');
    is_deeply($finish_ev->($r->{process}),{state=>'exited',exit_code=>7},
        'EV callback delivers nonzero exit');
    $r=$run_ev->('kill "KILL", $$; exit 99');
    is_deeply($finish_ev->($r->{process}),{state=>'signaled',signal=>9},
        'EV callback delivers signal termination');
    $r=$run_ev->('print "executed"');
    my $status=$finish_ev->($r->{process});
    open my $log,'<',"$root/$n/worker.log" or die $!;
    my $bytes=do {local $/; <$log>};
    close $log;
    ok($status->{exit_code}==0 && $bytes eq 'executed','EV launch executes command and captures output');
}
done_testing;
