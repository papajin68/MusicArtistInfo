package Plugins::MusicArtistInfo::Mosaicly::Server;

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use Time::HiRes qw(time);
use Scalar::Util qw(weaken);
use Plugins::MusicArtistInfo::Mosaicly::Generator;
use Plugins::MusicArtistInfo::Mosaicly::Coordinator;
use Plugins::MusicArtistInfo::Mosaicly::Publisher;

sub _fail { +{ok=>0,reason=>$_[0]} }

# One initialized-server instance. The caller owns successful scan
# authorization, epoch invalidation, and resource admission.
sub new {
    my ($class,%a)=@_;
    die 'missing admission or lifecycle guard' unless ref($a{admit}) eq 'CODE'
        && ref($a{current}) eq 'CODE';
    die 'persistent worker ownership required' unless defined $a{ownership};
    require Slim::Utils::OSDetect;
    require Slim::Utils::Timers;
    die 'unsupported platform' unless Slim::Utils::OSDetect::isLinux() && !main::SCANNER();
    die 'native EV loop unavailable' unless $INC{'EV.pm'};
    my $lib=scalar Slim::Utils::OSDetect::dirsFor('libpath');
    my $perl=abs_path($^X);
    my $module=abs_path($INC{'Plugins/MusicArtistInfo/Mosaicly/Server.pm'});
    die 'native runtime unavailable' unless $lib && -d $lib && $perl && $module;
    my $worker=dirname($module).'/worker.pl';
    my $pluginparent=dirname(dirname(dirname(dirname($module))));
    my %seen;
    my @includes=grep { !$seen{$_}++ } map { abs_path($_) }
        grep { defined($_) && !ref($_) && m{\A/} && -d $_ }
        ($pluginparent,@INC);
    my $self=bless {admit=>$a{admit},current=>$a{current}},$class;
    $self->{coordinator}=Plugins::MusicArtistInfo::Mosaicly::Coordinator->new(
        root=>$a{jobs},library=>abs_path($lib),worker=>$worker,
        includes=>\@includes,perl=>$perl,ev=>1,ownership=>$a{ownership});
    # Guard is bound to the specific active epoch, not just current idle status.
    my $owner=$self;
    weaken($owner);
    $self->{publisher}=Plugins::MusicArtistInfo::Mosaicly::Publisher->new(
        root=>$a{portraits},current=>sub {
            $owner && !$owner->{stopped} && $owner->{active} && $owner->{current}->($owner->{active}{epoch});
        });
    return $self;
}

sub busy { $_[0]{active} || $_[0]{coordinator}->busy }

# Stop admission/publication, but retain the timer and process ownership.
# A real server exit may prevent further polling; the reservation survives
# if its storage survives. Never remove it on an unverified shutdown.
sub drain {
    my ($self)=@_;
    $self->{active}{discard}=1 if $self->{active};
    $self->{coordinator}->drain;
    return !$self->busy;
}

sub shutdown {
    my ($self)=@_;
    $self->{stopped}=1;
    return $self->drain;
}

sub start {
    my ($self,%a)=@_;
    return _fail('shutdown') if $self->{stopped};
    return _fail('busy') if $self->busy;
    return _fail('invalid_callback') unless ref($a{done}) eq 'CODE';
    return _fail('stale_job') unless defined($a{epoch}) && $self->{current}->($a{epoch});
    return _fail('admission_denied') unless $self->{admit}->();
    my $identity=eval {$self->{publisher}->identity($a{contributor_id})};
    return _fail('artist_unavailable') unless $identity;
    my $job=Plugins::MusicArtistInfo::Mosaicly::Generator->prepare_job(
        contributor_id=>$a{contributor_id});
    return $job unless $job->{ok};
    return _fail('stale_job') unless $self->{current}->($a{epoch});
    return _fail('admission_denied') unless $self->{admit}->();
    my $r=$self->{coordinator}->start($job);
    return $r unless $r->{ok};
    $self->{active}={identity=>$identity,epoch=>$a{epoch},done=>$a{done}};
    $self->_schedule;
    return {ok=>1};
}

sub _schedule {
    my ($self)=@_;
    Slim::Utils::Timers::setTimer($self,time()+0.25,\&_tick);
}

sub _tick {
    my ($self)=@_;
    my $a=$self->{active} or return;
    my $r=$self->{coordinator}->poll;
    if ($r->{state} eq 'running' || $r->{state} eq 'unresolved') {
        $self->_schedule;
        return;
    }
    my $out=$r;
    if ($r->{state} eq 'complete' && $r->{ok}) {
        $out=$self->{stopped} || $a->{discard} || !$self->{current}->($a->{epoch})
            ? _fail('stale_job')
            : $self->{publisher}->publish(identity=>$a->{identity},output=>$r);
        # Report bounded metadata only, not JPEG bytes or private paths.
        $out->{sources}=$r->{result}{sources} if $out->{ok};
        $out->{jpeg_sha256}=$r->{result}{jpeg_sha256} if $out->{ok};
    }
    delete $self->{active};
    $a->{done}->($out);
}

1;
