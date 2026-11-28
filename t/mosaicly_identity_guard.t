use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../IdentityGuard.pm";
my $guard = 'Plugins::MusicArtistInfoMosaicly::IdentityGuard';

is_deeply($guard->decision({}, undef),
    {allowed=>1, reason=>'original_absent'}, 'original absent');
is_deeply($guard->decision({}, 'enabled'),
    {allowed=>1, reason=>'original_absent'}, 'stale original preference ignored');

my $installed = {MusicArtistInfo=>{module=>'Plugins::MusicArtistInfo::Plugin'}};
is_deeply($guard->decision($installed, 'disabled'),
    {allowed=>1, reason=>'original_disabled'}, 'installed disabled original permits fork');
is_deeply($guard->decision($installed, 'enabled'),
    {allowed=>0, reason=>'original_enabled'}, 'enabled original wins');

for my $state ('needs-enable','needs-disable','needs-install','needs-uninstall',
    '', 'unexpected', undef, {}) {
    is_deeply($guard->decision($installed, $state),
        {allowed=>0, reason=>'original_state_unsettled'}, 'ambiguous or pending state denies');
}

for my $plugins (undef, [], 'invalid') {
    is_deeply($guard->decision($plugins, 'disabled'),
        {allowed=>0, reason=>'discovery_unavailable'}, 'missing discovery denies');
}

ok(!exists $INC{'Plugins/MusicArtistInfo/Plugin.pm'}, 'original implementation not loaded');
ok(!exists $INC{'Plugins/MusicArtistInfoMosaicly/Plugin.pm'}, 'fork implementation not loaded');

done_testing;
