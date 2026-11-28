package Plugins::MusicArtistInfo::Mosaicly::ScanSession;
use strict;
use warnings;
use Scalar::Util qw(blessed refaddr);

sub randomHex {
    my ($bytes)=@_;
    open my $fh,'<:raw','/dev/urandom' or return;
    my $n=read($fh,my $raw,$bytes);
    close $fh;
    return unless defined($n) && $n==$bytes;
    return unpack('H*',$raw);
}

sub new {
    my ($class,%a)=@_;
    for my $key (qw(enabled process schedule completed invalidate report)) {
        die "missing $key callback" unless ref($a{$key}) eq 'CODE';
    }
    my $random=$a{random} || \&randomHex;
    my $boot=$random->(16);
    die 'scanner boot identity unavailable' unless defined($boot) && $boot =~ /\A[a-f0-9]{32}\z/;
    return bless {%a,random=>$random,boot=>$boot,next=>1},$class;
}

# Fixed event names only; never report boot identity, secret, or RPC payload.
sub _observe {
    my ($self,$event)=@_;
    eval { $self->{observe}->($event) } if ref($self->{observe}) eq 'CODE';
}

sub invalidate {
    my ($self)=@_;
    $self->{active}{invalid}=1 if $self->{active};
    $self->{invalidate}->();
}

sub shutdown {
    my ($self)=@_;
    $self->{stopped}=1;
    $self->{admission}->shutdown if $self->{admission};
    $self->invalidate;
}

sub admissionPending {
    my ($self)=@_;
    return $self->{stopped} || ($self->{admission} && $self->{admission}->pending) ? 1 : 0;
}

sub _fresh {
    my ($new,$old)=@_;
    return blessed($new) && (!blessed($old) || refaddr($new)!=refaddr($old));
}

# The verified native request paths supply exactly rescan=>1 or wipe=>1.
# All other native launches still run normally but cannot authorize Mosaicly.
sub _supportedLaunch {
    my ($class,$args)=@_;
    return 0 unless @_==2 && defined($class) && !ref($class)
        && $class eq 'Slim::Music::Import' && ref($args) eq 'HASH'
        && keys(%$args)==1;
    my ($key)=keys %$args;
    return ($key eq 'rescan' || $key eq 'wipe') && defined($args->{$key})
        && !ref($args->{$key}) && "$args->{$key}" eq '1';
}

sub launch {
    my ($self,$native,@args)=@_;
    # Every native launch attempt invalidates prior generation authorization.
    $self->invalidate;
    my $previous=$self->{process}->();
    my ($session,$bootstrap);
    if (!$self->{stopped} && $self->{enabled}->() && !$self->{active}
            && $self->{next}<=2147483647 && _supportedLaunch(@args)) {
        my $secret=$self->{random}->(32);
        if (defined($secret) && $secret =~ /\A[a-f0-9]{64}\z/) {
            my $id="".$self->{next}++;
            $session=$self->{active}={id=>$id,secret=>$secret,state=>'ISSUED'};
            $bootstrap=join(':',$self->{boot},$id,$secret);
        }
    }
    local $ENV{MOSAICLY_SESSION_V2}=$bootstrap;
    my $context=wantarray;
    my (@result,$result);
    my $ok=eval {
        if ($context) { @result=$native->(@args) }
        elsif (defined $context) { $result=$native->(@args) }
        else { $native->(@args) }
        1;
    };
    my $error=$@;
    if ($session) {
        my $candidate=eval { $self->{process}->() };
        if (_fresh($candidate,$previous)) {
            $session->{process}=$candidate;
            $session->{invalid}=1 unless $ok;
            $self->_observe('process_captured');
            $self->{schedule}->($self,$session);
        } elsif (!$ok || $@) {
            # Unknown launch ownership remains reserved until restart.
            $session->{invalid}=1;
            $session->{unknown}=1;
        } else {
            delete $self->{active};
        }
    }
    die $error unless $ok;
    return @result if $context;
    return $result if defined $context;
    return;
}

sub transition {
    my ($self,$operation,$boot,$id,$secret)=@_;
    my $s=$self->{active};
    return 0 unless !$self->{stopped} && $s && !$s->{invalid} && $s->{process}
        && $self->{enabled}->() && defined($boot) && defined($id) && defined($secret)
        && !ref($boot) && !ref($id) && !ref($secret)
        && $boot eq $self->{boot} && $id eq $s->{id} && $secret eq $s->{secret};
    my %steps=(claim=>['ISSUED','CLAIMED'],ack=>['CLAIMED','ACKNOWLEDGED'],
        verify=>['ACKNOWLEDGED','CONSUMED']);
    my $step=$steps{$operation} or return 0;
    return 0 unless $s->{state} eq $step->[0];
    $s->{state}=$step->[1];
    $self->_observe($step->[1]);
    return 1;
}

sub poll {
    my ($self,$session)=@_;
    return unless $self->{active} && refaddr($self->{active})==refaddr($session);
    return unless $session->{process};
    my $alive=eval { $session->{process}->alive };
    if ($@ || $alive) {
        $self->{schedule}->($self,$session);
        return;
    }
    delete $self->{active};
    if ($self->{stopped} || $session->{invalid} || !$self->{enabled}->()
        || $session->{state} ne 'CONSUMED') {
        $self->_observe('completion_rejected');
        return;
    }
    # The process must also report a successful exit, not merely non-liveness.
    my $status=eval { $session->{process}->wait };
    if ($@ || !defined($status) || $status != 0) {
        $self->_observe('exit_rejected');
        return;
    }
    $self->_observe('exit_verified');
    $self->{completed}->($session->{id});
    $self->_observe('completion_delivered');
}

1;
