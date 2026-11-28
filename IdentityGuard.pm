package Plugins::MusicArtistInfoMosaicly::IdentityGuard;

use strict;
use warnings;

# This module must remain free of load-time plugin registrations, preferences,
# and dependencies on either active implementation. Native discovery completes
# before PluginManager loads server or scanner entry modules.
sub decision {
    my ($class, $plugins, $state) = @_;

    return { allowed => 0, reason => 'discovery_unavailable' }
        unless ref($plugins) eq 'HASH';

    # Ignore stale preference entries for an uninstalled original.
    return { allowed => 1, reason => 'original_absent' }
        unless exists $plugins->{MusicArtistInfo};

    # Only an explicitly disabled original permits activation. Pending,
    # missing, malformed and enabled states deny, regardless of load order.
    return { allowed => 1, reason => 'original_disabled' }
        if defined($state) && !ref($state) && $state eq 'disabled';

    return { allowed => 0, reason => 'original_enabled' }
        if defined($state) && !ref($state) && $state eq 'enabled';

    return { allowed => 0, reason => 'original_state_unsettled' };
}

sub nativeDecision {
    my ($class) = @_;

    my $result = eval {
        require Slim::Utils::PluginManager;
        require Slim::Utils::Prefs;

        my $plugins = Slim::Utils::PluginManager->allPlugins;
        my $state;

        if (ref($plugins) eq 'HASH' && exists $plugins->{MusicArtistInfo}) {
            $state = Slim::Utils::Prefs::preferences('plugin.state')->get('MusicArtistInfo');
        }

        $class->decision($plugins, $state);
    };

    return $result if ref($result) eq 'HASH';
    return { allowed => 0, reason => 'native_state_unavailable' };
}

1;
