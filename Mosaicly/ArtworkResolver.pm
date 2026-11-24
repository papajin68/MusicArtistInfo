package Plugins::MusicArtistInfo::Mosaicly::ArtworkResolver;

use strict;
use warnings;

sub _failure { return { ok => 0, reason => $_[0] }; }

# Retrieve the committed selection, never discover replacement artwork.
sub resolve {
    my ($class, %args) = @_;
    my ($album, $artwork) = @args{qw(album_id artwork_id)};
    return _failure('invalid_identity') unless defined($album)
        && !ref($album) && $album =~ /\A[1-9][0-9]*\z/
        && defined($artwork) && !ref($artwork)
        && $artwork =~ /\A[0-9a-f]{8}\z/;

    my $result = eval { $class->_resolve($album, $artwork) };
    return _failure('native_error') if $@ || !defined($result);
    return $result;
}

sub _resolve {
    my ($class, $album, $artwork) = @_;
    require Slim::Schema;
    require Slim::Music::Artwork;
    my $dbh = Slim::Schema->dbh;
    my $row = $dbh->selectrow_arrayref(
        'SELECT artwork FROM albums WHERE id = ?', undef, $album);
    die 'album query failed' if $dbh->err;
    return _failure('album_not_found') unless $row;
    return _failure('no_selected_artwork') unless $row->[0];
    return _failure('artwork_changed') unless $row->[0] eq $artwork;

    $row = $dbh->selectrow_arrayref(
        'SELECT id, cover, url FROM tracks WHERE album = ? AND coverid = ? ORDER BY id LIMIT 1',
        undef, $album, $artwork);
    die 'track query failed' if $dbh->err;
    return _failure('no_matching_track') unless $row;
    my ($id, $cover, $url) = @$row;
    return _failure('no_recorded_source') unless defined($cover) && length($cover) && $cover !~ /\A0+\z/;
    return _failure('unsupported_source') unless defined($url) && $url =~ /\Afile:\/\//i;

    my ($bytes, $type, $kind, $length);
    if ($cover =~ /\A[0-9]+\z/) {
        $kind = 'embedded';
        my $track = Slim::Schema->rs('Track')->find($id);
        return _failure('source_unavailable') unless $track;
        return _failure('source_mismatch') unless defined($track->cover)
            && $track->cover eq $cover && defined($track->url) && $track->url eq $url;
        return _failure('unsupported_source') if $track->remote || !$track->audio;
        return _failure('native_error') unless Slim::Music::Artwork->can('_readCoverArtTags');
        ($bytes, $type, $length) = Slim::Music::Artwork->_readCoverArtTags($track, $track->path);
        return _failure('source_unavailable') unless defined($bytes) && length($bytes);
        return _failure('source_mismatch') unless defined($length)
            && $length =~ /\A[0-9]+\z/ && $length == $cover && length($bytes) == $cover;
    } else {
        $kind = 'external';
        # The native API expects a filesystem path, not a network or file URL.
        return _failure('unsupported_source') if $cover =~ /\A[a-z][a-z0-9+.-]*:\/\//i;
        ($bytes, $type) = Slim::Music::Artwork->getImageContentAndType($cover);
        return _failure('source_unavailable') unless defined($bytes) && length($bytes);
    }
    return _failure('native_error') unless defined($type) && length($type);
    return { ok => 1, album_id => $album, artwork_id => $artwork,
        track_id => $id, source_kind => $kind, bytes => $bytes, content_type => $type };
}

1;
