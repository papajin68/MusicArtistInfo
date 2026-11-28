package Plugins::MusicArtistInfoMosaicly::Mosaicly::Process;

use strict;
use warnings;
use POSIX qw(WNOHANG WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG);
use Errno qw(EINTR ECHILD);
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL);
use Scalar::Util qw(weaken);

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

    # In initialized LMS, EV already owns child reaping. Register a PID
    # watcher before returning to its event loop; never compete with waitpid.
    my $ev=$args{ev};
    return {ok=>0,reason=>'event_loop_unavailable'} if $ev && !$INC{'EV.pm'};
    # Do not change the initialized parent's environment or descriptors.
    my $pid = fork();
    return {ok=>0,reason=>'fork_failed'} unless defined $pid;
    if (!$pid) {
        # LMS ties STDERR to its logger. Do not reopen or write through
        # inherited Perl standard handles. Use fresh handles and OS dup2.
        # Every recoverable child exception must terminate here, never
        # propagate to the caller's inherited server exception handlers.
        my $redirected=0;
        eval {
            $SIG{$_} = 'DEFAULT' for qw(INT HUP QUIT TERM PIPE CHLD __WARN__ __DIE__);
            umask 0077;
            chdir $dir or die "chdir: $!";
            sysopen my $input,'/dev/null',O_RDONLY or die "stdin: $!";
            sysopen my $output,$log,O_WRONLY|O_CREAT|O_EXCL,0600
                or die "log: $!";
            chmod 0600,$log or die "log chmod: $!";
            die 'log permissions' unless ((stat($output))[2]&0777)==0600;
            my ($in,$out)=(fileno($input),fileno($output));
            die 'unexpected standard descriptor allocation'
                unless defined($in) && defined($out) && $in>2 && $out>2;
            for my $pair ([$in,0],[$out,1],[$out,2]) {
                my $rc=POSIX::dup2(@$pair);
                die "redirect descriptor: $!" unless defined($rc) && $rc==$pair->[1];
            }
            $redirected=1;
            close $input or die "close input: $!";
            close $output or die "close log: $!";
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
        # Diagnostics are best effort, through the redirected OS descriptor
        # only. In particular, never call a tied STDERR method after fork.
        my $error=$@;
        eval {
            if ($redirected) {
                my $message="Mosaicly child setup: ".($error || 'exec returned')."\n";
                POSIX::write(2,$message,length($message));
            }
        };
        POSIX::_exit(126);
    }
    my $self=bless({pid=>$pid,ev=>$ev},$class);
    if ($ev) {
        my $weak=$self;
        weaken($weak);
        # An exception here propagates: Coordinator retains reservation.
        $self->{watcher}=EV::child($pid,0,sub {
            my ($w)=@_;
            return unless $weak && $w->rpid==$pid;
            $weak->{terminal}=_status($w->rstatus);
            $w->stop;
        });
        die 'child watcher unavailable' unless $self->{watcher};
    }
    return {ok=>1,process=>$self};
}

# The timeout wrapper's ordinary exit is the existing proof of completed
# supervision. Reserved timeout/exec/signal statuses and lost status are
# deliberately not proof of descendant termination.
sub termination_verified {
    my ($class,$status)=@_;
    return ref($status) eq 'HASH' && ($status->{state}//'') eq 'exited'
        && defined($status->{exit_code}) && !ref($status->{exit_code})
        && $status->{exit_code}=~/\A[0-9]+\z/ && $status->{exit_code}<124;
}

sub _status {
    my ($status)=@_;
    return WIFEXITED($status)
        ? {state=>'exited',exit_code=>WEXITSTATUS($status)}
        : WIFSIGNALED($status)
            ? {state=>'signaled',signal=>WTERMSIG($status)}
            : {state=>'unknown',reason=>'unexpected_wait_status'};
}

sub poll {
    my ($self) = @_;
    return $self->{terminal} if exists $self->{terminal};
    return {state=>'running'} if $self->{ev};
    local $?;
    my $pid = waitpid($self->{pid}, WNOHANG);
    my ($status,$errno) = ($?,0+$!);
    return {state=>'running'} if $pid == 0 || ($pid == -1 && $errno == EINTR);
    my $r;
    if ($pid == $self->{pid}) {
        $r = _status($status);
    } elsif ($pid == -1 && $errno == ECHILD) {
        $r = {state=>'unknown',reason=>'exit_status_lost'};
    } else {
        # Unresolved ownership: keep reservation; retry on a later tick.
        return {state=>'unresolved',reason=>'wait_failed',errno=>$errno};
    }
    return $self->{terminal} = $r;
}

1;
