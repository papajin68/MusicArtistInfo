package Plugins::MusicArtistInfoMosaicly::Importer;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use Plugins::MusicArtistInfoMosaicly::IdentityGuard;

my $decision = Plugins::MusicArtistInfoMosaicly::IdentityGuard->nativeDecision;
if ($decision->{allowed}) {
    # Native PluginManager prepends lib/ before module load, even for a soft
    # inactive plugin. Only expose this fork's private bundled modules when active.
    my $vendor = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), 'MosaiclyVendor'));
    die 'Mosaicly vendor directory missing' unless -d $vendor;
    unshift @INC, $vendor unless grep { !ref($_) && $_ eq $vendor } @INC;
    require Plugins::MusicArtistInfoMosaicly::ImporterImplementation;
} else {
    eval { Slim::Utils::Log::logger('server.plugins')->warn(
        'MusicArtistInfoMosaicly Importer inactive: ' . $decision->{reason}) };
}

1;
