package Plugins::MusicArtistInfoMosaicly::Mosaicly::ScanAdapter;
use strict;
use warnings;
use Plugins::MusicArtistInfoMosaicly::Mosaicly::ScanSession;
use Plugins::MusicArtistInfoMosaicly::Mosaicly::ScanAdmission;
use Time::HiRes qw(time);

sub install {
    my ($class,%a)=@_;
    require Slim::Music::Import;
    require Slim::Control::Request;
    require Slim::Utils::Timers;
    my $native=Slim::Music::Import->can('launchScan') or die 'native launch unavailable';
    my $owner=Plugins::MusicArtistInfoMosaicly::Mosaicly::ScanSession->new(
        %a,
        process=>sub { Slim::Music::Import->scanningProcess },
        schedule=>sub {
            my ($self,$session)=@_;
            Slim::Utils::Timers::setTimer($session,time()+0.5,sub {
                $self->poll($session);
            });
        });
    for my $pair ([claim=>'claimed'],[ack=>'success'],[verify=>'authorized']) {
        my ($op,$field)=@$pair;
        Slim::Control::Request::addDispatch(
            ['mai_mosaicly_session',$op,'_boot','_session','_secret'],
            [0,0,0,sub {
                my $request=shift;
                my $ok=$owner->transition($op,map {$request->getParam($_)}
                    qw(_boot _session _secret));
                $request->addResult($field=>$ok);
                $request->setStatusDone;
            }]);
    }
    my $queueFlag=Slim::Music::Import->can('doQueueScanTasks') or die 'native queue flag unavailable';
    my $next=Slim::Music::Import->can('nextScanTask') or die 'native queue dispatch unavailable';
    my $abort=Slim::Music::Import->can('abortScan') or die 'native abort unavailable';
    my $queue=Slim::Music::Import->can('queueScanTask') or die 'native queue unavailable';
    my $admission=Plugins::MusicArtistInfoMosaicly::Mosaicly::ScanAdmission->new(
        invalidate=>sub { $owner->invalidate },
        drain=>$a{drain},
        schedule=>sub {
            my ($cb)=@_;
            Slim::Utils::Timers::setTimer($owner,time()+0.5,sub { $cb->() });
        },
        queued=>sub { Slim::Music::Import->hasScanTask },
        nativeQueue=>sub { $queueFlag->('Slim::Music::Import') },
        scanning=>sub { Slim::Music::Import->stillScanning },
        next=>$next,
        clear=>sub { Slim::Music::Import->clearScanQueue },
    );
    $owner->{admission}=$admission;

    # addDispatch returns the previous handler; native handlers retain their
    # own validation, queue operations and request completion semantics.
    for my $verbs (['rescan','_mode','_target'],['wipecache','_queue']) {
        my $previous;
        $previous=Slim::Control::Request::addDispatch($verbs,[0,0,0,sub {
            $admission->intent;
            return $previous->(@_);
        }]);
        die 'native scan request dispatch unavailable' unless ref($previous) eq 'CODE';
    }
    no warnings 'redefine';
    *Slim::Music::Import::doQueueScanTasks=sub {
        return $queueFlag->(@_) if @_>1;
        return 1 if $admission->held;
        return $queueFlag->(@_);
    };
    *Slim::Music::Import::queueScanTask=sub {
        $admission->intent;
        return $queue->(@_);
    };
    *Slim::Music::Import::nextScanTask=sub { $admission->next(@_) };
    # initScanQueue may already have captured the original code reference.
    Slim::Control::Request::unsubscribe($next);
    Slim::Control::Request::subscribe(\&Slim::Music::Import::nextScanTask,[['rescan'],['done']]);
    *Slim::Music::Import::abortScan=sub {
        $admission->abort;
        return $abort->(@_);
    };
    *Slim::Music::Import::launchScan=sub {
        # A direct bypass cannot claim success or launch while drain is held.
        die 'Mosaicly worker drain pending; scanner not launched' unless $admission->intent;
        return $owner->launch($native,@_);
    };
    return $owner;
}

1;
