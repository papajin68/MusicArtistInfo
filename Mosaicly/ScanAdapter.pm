package Plugins::MusicArtistInfo::Mosaicly::ScanAdapter;
use strict;
use warnings;
use Plugins::MusicArtistInfo::Mosaicly::ScanSession;
use Time::HiRes qw(time);

sub install {
    my ($class,%a)=@_;
    require Slim::Music::Import;
    require Slim::Control::Request;
    require Slim::Utils::Timers;
    my $native=Slim::Music::Import->can('launchScan') or die 'native launch unavailable';
    my $owner=Plugins::MusicArtistInfo::Mosaicly::ScanSession->new(
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
    no warnings 'redefine';
    *Slim::Music::Import::launchScan=sub { $owner->launch($native,@_) };
    return $owner;
}

1;
