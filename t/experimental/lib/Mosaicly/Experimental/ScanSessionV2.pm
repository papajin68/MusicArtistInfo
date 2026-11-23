package Mosaicly::Experimental::ScanSessionV2;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);

sub new {
    my ($class, %arg) = @_;
    die 'clock callback required' unless ref($arg{clock}) eq 'CODE';
    die 'boot_epoch must be 32 or more hex chars' unless _valid($arg{boot_epoch});
    my $lease = $arg{lease_seconds} // 300;
    my $complete = $arg{completion_seconds} // 30;
    my $capacity = $arg{tombstone_limit} // 10000;
    die 'invalid limits' unless $lease > 0 && $complete > 0 && $capacity =~ /^[1-9][0-9]*$/;
    my $now = $arg{clock}->();
    die 'invalid initial clock' unless _time_ok($now);
    return bless {
        clock => $arg{clock}, boot_epoch => lc $arg{boot_epoch},
        lease => $lease, completion => $complete,
        capacity => $capacity, active => undef, retired => {},
        last_time => $now, clock_invalid => 0,
    }, $class;
}

sub _valid {
    defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[a-fA-F0-9]{32,}\z/;
}
sub _time_ok {
    defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A(?:\d+)(?:\.\d+)?\z/;
}
sub _hash { sha256_hex(lc($_[0])) }
sub _now {
    my ($self) = @_;
    return undef if $self->{clock_invalid};
    my $now = eval { $self->{clock}->() };
    if ($@ || !_time_ok($now) || $now < $self->{last_time}) {
        $self->{clock_invalid} = 1;
        $self->_retire('DENIED') if $self->{active};
        return undef;
    }
    $self->{last_time} = $now;
    $self->_expire($now);
    return $now;
}
sub _expire {
    my ($self, $now) = @_;
    my $s = $self->{active} or return;
    my $budget = $s->{state} eq 'ACKNOWLEDGED' ? $self->{completion} : $self->{lease};
    $self->_retire('EXPIRED') if $now - $s->{last_seen} > $budget;
}
sub _retire {
    my ($self, $reason) = @_;
    my $s = delete $self->{active} or return;
    $self->{retired}{$s->{id_hash}} = $reason;
    $self->{retired}{$s->{token_hash}} = $reason;
}
sub _matches {
    my ($self, $epoch, $id, $token) = @_;
    my $s = $self->{active} or return 0;
    return 0 unless _valid($epoch) && _valid($id) && _valid($token);
    return lc($epoch) eq $self->{boot_epoch} && _hash($id) eq $s->{id_hash}
        && _hash($token) eq $s->{token_hash};
}
sub register {
    my ($self, $epoch, $id, $token) = @_;
    my $now = $self->_now;
    return 0 unless defined($now) && _valid($epoch) && _valid($id) && _valid($token);
    return 0 unless lc($epoch) eq $self->{boot_epoch};
    return 0 if $self->{active};
    my ($ih, $th) = (_hash($id), _hash($token));
    return 0 if $ih eq $th || exists($self->{retired}{$ih}) || exists($self->{retired}{$th});
    # Room for both tombstone entries must be reserved before admitting a session.
    return 0 if scalar(keys %{$self->{retired}}) + 2 > $self->{capacity};
    $self->{active} = { state => 'REGISTERED', id_hash => $ih,
        token_hash => $th, last_seen => $now };
    return 1;
}
sub heartbeat {
    my ($self, $epoch, $id, $token) = @_;
    my $now = $self->_now;
    return 0 unless defined($now) && $self->_matches($epoch, $id, $token);
    my $s = $self->{active};
    return 0 unless $s->{state} eq 'REGISTERED';
    $s->{last_seen} = $now;
    return 1;
}
sub ack {
    my ($self, $epoch, $id, $token) = @_;
    my $now = $self->_now;
    return 0 unless defined($now) && $self->_matches($epoch, $id, $token);
    my $s = $self->{active};
    return 0 unless $s->{state} eq 'REGISTERED';
    $s->{state} = 'ACKNOWLEDGED';
    $s->{last_seen} = $now;
    return 1;
}
sub verify {
    my ($self, $epoch, $id, $token) = @_;
    my $now = $self->_now;
    return 0 unless defined($now) && $self->_matches($epoch, $id, $token);
    my $ok = $self->{active}{state} eq 'ACKNOWLEDGED' ? 1 : 0;
    $self->_retire($ok ? 'CONSUMED' : 'DENIED');
    return $ok;
}
sub cancel {
    my ($self, $epoch, $id, $token) = @_;
    my $now = $self->_now;
    return 0 unless defined($now) && $self->_matches($epoch, $id, $token);
    $self->_retire('DENIED');
    return 1;
}
sub status {
    my ($self) = @_;
    $self->_now;
    return 'CLOCK_INVALID' if $self->{clock_invalid};
    return $self->{active} ? $self->{active}{state} : 'IDLE';
}
sub retired_count { scalar keys %{$_[0]{retired}} }
1;
