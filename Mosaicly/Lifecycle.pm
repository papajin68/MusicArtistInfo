package Plugins::MusicArtistInfo::Mosaicly::Lifecycle;
use strict;
use warnings;

# The normal plugin owns one instance. Admission requires the installed
# scanner adapter, authenticated completion and current resource checks.
sub new {
    my ($class,%a)=@_;
    die 'missing lifecycle callbacks' unless ref($a{enabled}) eq 'CODE'
        && ref($a{build}) eq 'CODE' && ref($a{report}) eq 'CODE';
    return bless {%a,epoch=>0},$class;
}

sub refresh {
    my ($self)=@_;
    ++$self->{epoch};
    delete $self->{authorized};
    $self->{scheduler}->cancel if $self->{scheduler};
    return if $self->{stopped} || !$self->{enabled}->();
    return if $self->{server};
    my $server=eval { $self->{build}->(
        admit=>sub { $self->current($self->{epoch}) && $self->{resource} && $self->{resource}->() },
        current=>sub { $self->current($_[0]) },
    ) };
    if (!$server) {
        $self->{report}->($@ || 'server unavailable');
        return;
    }
    $self->{server}=$server;
    return 1;
}

# A successful scan completion is the only entry point for a new epoch.
# The activation gate requires the installed scanner admission adapter.
sub current {
    my ($self,$epoch)=@_;
    return 0 if $self->{stopped} || !defined($epoch) || $epoch!=$self->{epoch}
        || !defined($self->{authorized}) || $self->{authorized}!=$epoch
        || !$self->{activation} || !$self->{activation}->() || !$self->{enabled}->()
        || !$self->{safe} || !$self->{scheduler} || !$self->{scheduler}->active;
    my $ok=eval { $self->{safe}->() };
    return $ok && $self->{epoch}==$epoch && !$self->{stopped}
        && $self->{scheduler}->active && $self->{enabled}->() && $self->{activation}->();
}
sub completed {
    my ($self,$session)=@_;
    return 0 unless defined($session) && !ref($session) && $session=~/\A[1-9][0-9]*\z/
        && $self->{server} && !$self->{stopped}
        && $self->{activation} && $self->{activation}->()
        && $self->{schedulerBuild};
    return 0 if defined($self->{lastSession}) && $session<=$self->{lastSession};
    $self->{lastSession}=$session;
    $self->{authorized}=$self->{epoch};
    $self->{scheduler} ||= $self->{schedulerBuild}->($self);
    return $self->{scheduler}->begin($self->{epoch});
}
sub shutdown {
    my ($self)=@_;
    ++$self->{epoch};
    $self->{stopped}=1;
    $self->{scheduler}->cancel if $self->{scheduler};
    # Retain ownership even if the worker is still running or unresolved.
    return $self->{server} ? $self->{server}->shutdown : 1;
}

sub server { $_[0]{server} }
sub epoch { $_[0]{epoch} }

1;
