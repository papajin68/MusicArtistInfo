package Plugins::MusicArtistInfo::Mosaicly::Lifecycle;
use strict;
use warnings;

# The normal plugin owns one instance. Admission remains explicitly closed
# until successful scan authorization and resource admission are integrated.
sub new {
    my ($class,%a)=@_;
    die 'missing lifecycle callbacks' unless ref($a{enabled}) eq 'CODE'
        && ref($a{build}) eq 'CODE' && ref($a{report}) eq 'CODE';
    return bless {%a,epoch=>0},$class;
}

sub refresh {
    my ($self)=@_;
    ++$self->{epoch};
    return if $self->{stopped} || !$self->{enabled}->();
    return if $self->{server};
    my $server=eval { $self->{build}->(
        admit=>sub { 0 },
        current=>sub { 0 },
    ) };
    if (!$server) {
        $self->{report}->($@ || 'server unavailable');
        return;
    }
    $self->{server}=$server;
    return 1;
}

sub shutdown {
    my ($self)=@_;
    ++$self->{epoch};
    $self->{stopped}=1;
    # Retain ownership even if the worker is still running or unresolved.
    return $self->{server} ? $self->{server}->shutdown : 1;
}

sub server { $_[0]{server} }
sub epoch { $_[0]{epoch} }

1;
