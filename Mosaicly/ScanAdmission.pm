package Plugins::MusicArtistInfo::Mosaicly::ScanAdmission;
use strict;
use warnings;

# The native queue owns requests, ordering, deduplication and supersession.
# This object owns only a temporary admission hold and one retry timer.
sub new {
    my ($class,%a)=@_;
    for my $key (qw(invalidate drain schedule queued nativeQueue scanning next clear)) {
        die "missing $key callback" unless ref($a{$key}) eq 'CODE';
    }
    return bless \%a,$class;
}

sub held { $_[0]{held} || $_[0]{stopped} ? 1 : 0 }
sub pending {
    my ($self)=@_;
    return $self->held || $self->{queued}->() || $self->{nativeQueue}->();
}

sub _retry {
    my ($self)=@_;
    return if $self->{stopped} || $self->{retry};
    $self->{retry}=1;
    $self->{schedule}->(sub {
        delete $self->{retry};
        return unless $self->{held} && !$self->{stopped};
        $self->next;
    });
}

sub intent {
    my ($self)=@_;
    die 'Mosaicly scan admission stopped' if $self->{stopped};
    my $already=$self->{held};
    # Close admission before invalidation or any callback.
    $self->{held}=1;
    $self->{invalidate}->();
    if ($self->{drain}->() && !$already) {
        delete $self->{held};
        return 1;
    }
    $self->_retry;
    return 0;
}

sub next {
    my ($self,@args)=@_;
    return if $self->{stopped};
    my $queued=$self->{queued}->();
    # Do not dequeue/requeue while waiting: native recent-request suppression
    # would be able to discard the request before it ever runs.
    $self->intent if $queued && !$self->{held};
    if ($self->{held}) {
        if (!$self->{drain}->() ||
                ($queued && ($self->{nativeQueue}->() || $self->{scanning}->()))) {
            $self->_retry;
            return;
        }
        delete $self->{held};
    }
    return unless $self->{queued}->();
    return $self->{next}->(@args);
}

sub abort {
    my ($self)=@_;
    return unless $self->{held} && !$self->{stopped};
    $self->{invalidate}->();
    # Native abortScan clears the queue only when stillScanning is true.
    # During our hold there may be no scanner yet.
    $self->{clear}->();
    $self->_retry;
}

sub shutdown {
    my ($self)=@_;
    $self->{stopped}=1;
}

1;
