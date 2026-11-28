package Plugins::MusicArtistInfo::PortraitSource;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(source validSource onlineEnabled initSource legacyImporterWork importerRequired);

sub validSource {
    my ($value) = @_;
    return defined($value) && !ref($value) && $value =~ /\A(?:online|mosaicly|none)\z/;
}

# Read-only scanner fallback before migration; invalid stored modes fail closed.
sub source {
    my ($prefs) = @_;
    my $value = $prefs->get('artistPortraitSource');
    return validSource($value) ? $value : 'none' if defined $value;
    my $legacy = $prefs->get('lookupArtistPictures');
    return !defined($legacy) || $legacy ? 'online' : 'none';
}

sub onlineEnabled { source($_[0]) eq 'online' }

# Keep the original importer work predicate independent of Mosaicly registration.
sub legacyImporterWork {
    my ($prefs,$serverprefs)=@_;
    return $serverprefs->get('precacheArtwork') || onlineEnabled($prefs)
        || $prefs->get('lookupCoverArt') || $prefs->get('replaceOnlineGenres');
}

sub importerRequired {
    my ($prefs,$serverprefs,$nativeArtwork)=@_;
    return 0 unless $prefs->get('runImporter');
    return legacyImporterWork($prefs,$serverprefs)
        || ($nativeArtwork && source($prefs) eq 'mosaicly');
}

# Main server only. Legacy value remains migration/rollback evidence, not authority.
sub initSource {
    my ($prefs) = @_;
    my $mode = source($prefs);
    my $old = $prefs->get('artistPortraitSource');
    $prefs->set('artistPortraitSource', $mode)
        unless defined($old) && validSource($old) && $old eq $mode;
    return $mode;
}

1;
