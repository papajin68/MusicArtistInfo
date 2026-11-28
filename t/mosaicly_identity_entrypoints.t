use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Basename qw(dirname);

my $root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
my $guard = 'Plugins::MusicArtistInfoMosaicly::IdentityGuard';
require File::Spec->catfile($root, 'IdentityGuard.pm');
$INC{'Plugins/MusicArtistInfoMosaicly/IdentityGuard.pm'} = 1;
my $vendor = File::Spec->rel2abs(File::Spec->catdir($root, 'MosaiclyVendor'));

for my $entry (qw(Plugin Importer)) {
    my $path = File::Spec->catfile($root, "$entry.pm");
    my $impl = "Plugins/MusicArtistInfoMosaicly/${entry}Implementation.pm";
    my $class = "Plugins::MusicArtistInfoMosaicly::$entry";
    for my $allowed (0, 1) {
        my $loads = 0;
        local @INC = (sub {
            my (undef, $file) = @_;
            return unless $file eq $impl;
            ++$loads;
            my $source = "1;\n";
            return \$source;
        }, @INC);
        local $INC{$path}; delete $INC{$path};
        local $INC{$impl}; delete $INC{$impl};
        {
            no warnings 'redefine';
            local *Plugins::MusicArtistInfoMosaicly::IdentityGuard::nativeDecision = sub {
                return {allowed=>$allowed, reason=>$allowed?'original_disabled':'original_enabled'};
            };
            my $ok = eval { require $path; 1 };
            ok($ok, "$entry loads safely, allowed=$allowed") or diag($@);
            is($loads, $allowed, "$entry implementation load count, allowed=$allowed");
            is(scalar(grep { !ref($_) && $_ eq $vendor } @INC), $allowed,
                "$entry vendor path exposure, allowed=$allowed");
            ok(!$class->can('initPlugin'), "$entry wrapper alone registers no init hook");
        }
    }
}

done_testing;
