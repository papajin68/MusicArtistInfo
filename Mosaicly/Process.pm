package Plugins::MusicArtistInfo::Mosaicly::Process;

use strict;
use warnings;
use POSIX qw(WNOHANG WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG);
use Errno qw(EINTR ECHILD);

# Narrow adapter for the Linux MVP. No global signal handlers, generic
# child reaping, shell invocation, or retry sleeps. The caller supplies
# the already bounded command and owns scheduling and job storage.
sub supported { $^O eq 'linux' }

sub launch {
    my ($class, %args) = @_;
    return {ok=>0, reason=>'unsupported_platform'} unless $class->supported;
    my ($argv,$dir,$log) = @args{qw(argv directory log)};
    return {ok=>0,reason=>'invalid_command'} unless ref($argv) eq 'ARRAY'
        && @$argv && !grep { !defined($_) || ref($_) || /\0/ } @$argv;
    return {ok=>0,reason=>'invalid_command'} unless $argv->[0] =~ m{\A/}
        && -f $argv->[0] && -x _;
    return {ok=>0,reason=>'invalid_directory'} unless defined($dir)
        && !ref($dir) && $dir =~ m{\A/} && -d $dir && !-l $dir;
    return {ok=>0,reason=>'invalid_log'} unless defined($log)
        && !ref($log) && $log eq "$dir/worker.log";

    # Do not change the initialized parent's environment or descriptors.
    my $pid = fork();
    return {ok=>0,reason=>'fork_failed'} unless defined $pid;
    if (!$pid) {
        # Never run inherited server END blocks or object destructors.
        eval {
            $SIG{$_} = 'DEFAULT' for qw(INT HUP QUIT TERM PIPE CHLD __WARN__ __DIE__);
            umask 0077;
            chdir $dir or die "chdir: $!";
            open STDIN, '<', '/dev/null' or die "stdin: $!";
            require Fcntl;
            sysopen STDOUT,$log,Fcntl::O_WRONLY()|Fcntl::O_CREAT()|Fcntl::O_EXCL(),0600
                or die "log: $!";
            open STDERR, '>&', \*STDOUT or die "stderr: $!";
            # Close inherited native DB/socket descriptors, even if their
            # close-on-exec flags were not set. Linux procfs is required.
            opendir my $dh, '/proc/self/fd' or die "fd inventory: $!";
            my $inventory_fd=fileno($dh);
            my @fds = grep { /\A[0-9]+\z/ && $_ > 2 && $_ != $inventory_fd } readdir $dh;
            closedir $dh or die "fd inventory close: $!";
            for my $fd (@fds) {
                my $rc=POSIX::close($fd);
                die "close inherited descriptor: $!" unless defined($rc) && $rc==0;
            }
            exec {$argv->[0]} @$argv;
        };
        POSIX::_exit(126);
    }
    return {ok=>1, process=>bless({pid=>$pid},$class)};
}

sub poll {
    my ($self) = @_;
    return $self->{terminal} if exists $self->{terminal};
    local $?;
    my $pid = waitpid($self->{pid}, WNOHANG);
    my ($status,$errno) = ($?,0+$!);
    return {state=>'running'} if $pid == 0 || ($pid == -1 && $errno == EINTR);
    my $r;
    if ($pid == $self->{pid}) {
        $r = WIFEXITED($status)
            ? {state=>'exited',exit_code=>WEXITSTATUS($status)}
            : WIFSIGNALED($status)
                ? {state=>'signaled',signal=>WTERMSIG($status)}
                : {state=>'unknown',reason=>'unexpected_wait_status'};
    } elsif ($pid == -1 && $errno == ECHILD) {
        $r = {state=>'unknown',reason=>'exit_status_lost'};
    } else {
        # Unresolved ownership: keep reservation; retry on a later tick.
        return {state=>'unresolved',reason=>'wait_failed',errno=>$errno};
    }
    return $self->{terminal} = $r;
}

1;
