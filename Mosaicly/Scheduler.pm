package Plugins::MusicArtistInfo::Mosaicly::Scheduler;
use strict;
use warnings;
use Scalar::Util qw(refaddr);

# One authenticated epoch, one bounded page, one worker at a time.
# Native timers own progression; no recursive synchronous worker loop.
sub new {
    my ($class,%a)=@_;
    for my $k (qw(current limit page start schedule report)) {
        die "missing $k callback" unless ref($a{$k}) eq 'CODE';
    }
    return bless \%a,$class;
}

sub _id { defined($_[0]) && !ref($_[0]) && $_[0]=~/\A[1-9][0-9]*\z/ }
sub active { defined $_[0]{run} }
sub _same {
    my ($self,$run)=@_;
    return $self->{run} && refaddr($self->{run})==refaddr($run);
}
sub _current {
    my ($self,$run)=@_;
    return 0 unless $self->_same($run);
    my $ok=eval { $self->{current}->($run->{epoch}) };
    return $ok && $self->_same($run);
}
sub _finish {
    my ($self,$run,$reason)=@_;
    return unless $self->_same($run);
    delete $self->{run};
    $self->{report}->($reason,{%{$run->{counts}}});
}
sub cancel {
    my ($self)=@_;
    $self->_finish($self->{run},'invalidated') if $self->{run};
}
sub begin {
    my ($self,$epoch)=@_;
    return 0 if $self->{run} || !_id($epoch);
    my $run=$self->{run}={epoch=>$epoch,cursor=>0,ids=>[],
        counts=>{generated=>0,skipped=>0,failed=>0,deferred=>0}};
    unless ($self->_current($run)) {
        $self->_finish($run,'not_current');
        return 0;
    }
    $self->_schedule($run);
    return 1;
}
sub _schedule {
    my ($self,$run)=@_;
    return unless $self->_same($run) && !$run->{scheduled} && !$run->{worker};
    $run->{scheduled}=1;
    $self->{schedule}->(sub {
        return unless $self->_same($run);
        delete $run->{scheduled};
        $self->_step($run);
    });
}
sub _defer {
    my ($self,$run,$reason)=@_;
    ++$run->{counts}{deferred};
    $self->_finish($run,$reason);
}
sub _step {
    my ($self,$run)=@_;
    return $self->_finish($run,'invalidated') unless $self->_current($run);
    unless (exists $run->{limit}) {
        my $limit=eval { $self->{limit}->() };
        return $self->_defer($run,'discovery_failed') unless defined($limit)
            && !ref($limit) && $limit=~/\A(?:0|[1-9][0-9]*)\z/;
        $run->{limit}=$limit;
    }
    return $self->_finish($run,'invalidated') unless $self->_current($run);
    unless (@{$run->{ids}}) {
        return $self->_finish($run,'complete') if $run->{cursor}>=$run->{limit};
        my $page=eval { $self->{page}->($run->{cursor},$run->{limit},32) };
        return $self->_defer($run,'discovery_failed') unless ref($page) eq 'ARRAY' && @$page<=32;
        my $last=$run->{cursor};
        for my $id (@$page) {
            return $self->_defer($run,'invalid_page') unless _id($id) && $id>$last && $id<=$run->{limit};
            $last=$id;
        }
        return $self->_finish($run,'complete') unless @$page;
        $run->{ids}=[@$page];
    }
    return $self->_finish($run,'invalidated') unless $self->_current($run);
    my $id=$run->{cursor}=shift @{$run->{ids}};
    my $token=$run->{worker}={id=>$id};
    my $r=eval { $self->{start}->($id,$run->{epoch},sub {
        my ($out)=@_;
        return unless $self->_same($run) && $run->{worker}
            && refaddr($run->{worker})==refaddr($token);
        delete $run->{worker};
        return $self->_finish($run,'invalidated') unless $self->_current($run);
        $self->_result($run,$out);
    }) };
    return unless $self->_same($run) && $run->{worker}
        && refaddr($run->{worker})==refaddr($token);
    return if ref($r) eq 'HASH' && $r->{ok};
    delete $run->{worker};
    $self->_result($run,$r);
}
sub _result {
    my ($self,$run,$r)=@_;
    return $self->_finish($run,'invalidated') unless $self->_current($run);
    return $self->_defer($run,'start_unresolved') unless ref($r) eq 'HASH';
    my $reason=$r->{reason}//'';
    if ($r->{ok}) {
        ++$run->{counts}{generated};
    } elsif ($reason =~ /\A(?:artist_unavailable|already_assigned|local_artwork|no_usable_artwork)\z/) {
        ++$run->{counts}{skipped};
    } elsif ($reason =~ /\A(?:busy|admission_denied|stale_job|shutdown|termination_unverified|cleanup_failed|launch_unresolved|reservation_failed|ownership_reservation_failed|publication_pending|publication_exception|association_changed|file_publication_failed)\z/) {
        return $self->_defer($run,$reason);
    } else {
        ++$run->{counts}{failed};
    }
    $self->_schedule($run);
}
1;
