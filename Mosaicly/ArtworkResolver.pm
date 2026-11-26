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


# Capture metadata in the initialized server. No artwork bytes acquired.
sub describe {
    my ($class, %args) = @_;
    my ($album,$artwork) = @args{qw(album_id artwork_id)};
    return _failure('invalid_identity') unless defined($album)
        && !ref($album) && $album =~ /\A[1-9][0-9]*\z/
        && defined($artwork) && !ref($artwork)
        && $artwork =~ /\A[0-9a-f]{8}\z/;
    my $r = eval { $class->_describe($album,$artwork) };
    return _failure('native_error') if $@ || !defined($r);
    return $r;
}

sub _describe {
    my ($class,$album,$artwork) = @_;
    require Slim::Schema;
    my $dbh = Slim::Schema->dbh;
    my $row = $dbh->selectrow_arrayref(
        'SELECT artwork FROM albums WHERE id = ?', undef, $album);
    die 'album query failed' if $dbh->err;
    return _failure('album_not_found') unless $row;
    return _failure('no_selected_artwork') unless $row->[0];
    return _failure('artwork_changed') unless $row->[0] eq $artwork;
    $row = $dbh->selectrow_arrayref(
        'SELECT id, cover, url FROM tracks WHERE album = ? AND coverid = ? ORDER BY id LIMIT 1',
        undef,$album,$artwork);
    die 'track query failed' if $dbh->err;
    return _failure('no_matching_track') unless $row;
    my ($id,$cover,$url) = @$row;
    return _failure('no_recorded_source') unless defined($cover) && length($cover) && $cover !~ /\A0+\z/;
    return _failure('unsupported_source') unless defined($url) && $url =~ /\Afile:\/\//i;
    my $d = {ok=>1, album_id=>$album, artwork_id=>$artwork, track_id=>$id};
    if ($cover =~ /\A[0-9]+\z/) {
        my $track = Slim::Schema->rs('Track')->find($id);
        return _failure('source_unavailable') unless $track;
        return _failure('source_mismatch') unless defined($track->cover)
            && $track->cover eq $cover && defined($track->url) && $track->url eq $url;
        return _failure('unsupported_source') if $track->remote || !$track->audio;
        my $type = Slim::Schema->contentType($track);
        return _failure('unsupported_source') unless defined($type) && $type =~ /\A[a-z0-9]+\z/;
        @$d{qw(source_kind path audio_type cover_length)} = ('embedded',$track->path,$type,$cover);
    } else {
        return _failure('unsupported_source') if $cover =~ /\A[a-z][a-z0-9+.-]*:\/\//i;
        @$d{qw(source_kind path)} = ('external',$cover);
    }
    return _failure('unsupported_source') unless defined($d->{path})
        && !ref($d->{path}) && length($d->{path}) && $d->{path} !~ /\0/;
    # Capture file identity without reading artwork; compare again before
    # and after worker acquisition and at registration.
    my @st = stat($d->{path});
    return _failure('source_unavailable') unless @st && -f _;
    $d->{file_identity} = [@st[0,1,7,9,10]];
    return $d;
}

sub _same_file {
    my ($d) = @_;
    my @st = stat($d->{path});
    return @st && -f _ && join(':',@st[0,1,7,9,10]) eq join(':',@{$d->{file_identity}});
}

# Only called by the contained Generator worker. Never resolve alternatives.
sub retrieve {
    my ($class,$d) = @_;
    return _failure('invalid_identity') unless ref($d) eq 'HASH'
        && ($d->{ok}//0) eq '1'
        && ($d->{album_id}//'') =~ /\A[1-9][0-9]*\z/
        && ($d->{track_id}//'') =~ /\A[1-9][0-9]*\z/
        && ($d->{artwork_id}//'') =~ /\A[0-9a-f]{8}\z/
        && ($d->{source_kind}//'') =~ /\A(?:embedded|external)\z/
        && defined($d->{path}) && !ref($d->{path}) && $d->{path} =~ m{\A/}
        && $d->{path} !~ /\0/
        && ref($d->{file_identity}) eq 'ARRAY' && @{$d->{file_identity}}==5
        && !grep { !defined($_) || ref($_) || $_ !~ /\A[0-9]+\z/ } @{$d->{file_identity}};
    my $r = eval { $class->_retrieve($d) };
    return _failure('native_error') if $@ || !defined($r);
    return $r;
}

sub _retrieve {
    my ($class,$d) = @_;
    return _failure('source_mismatch') unless _same_file($d);
    # Reject oversized recorded sources before native acquisition. External
    # size comes from stat; embedded length is the committed cover value.
    # Selection recognizes unsupported_source as a skippable source.
    return _failure('unsupported_source') if $d->{source_kind} eq 'external'
        && $d->{file_identity}[2]>4*1024*1024;
    require Slim::Music::Artwork;
    my ($bytes,$type);
    if ($d->{source_kind} eq 'embedded') {
        return _failure('invalid_identity') unless ($d->{audio_type}//'') =~ /\A[a-z0-9]+\z/
            && ($d->{cover_length}//'') =~ /\A[1-9][0-9]*\z/;
        return _failure('unsupported_source') if $d->{cover_length}>4*1024*1024;
        require Slim::Formats;
        my $format = Slim::Formats->classForFormat($d->{audio_type});
        return _failure('unsupported_source') unless $format;
        return _failure('native_error') unless Slim::Formats->loadTagFormatForType($d->{audio_type});
        return _failure('unsupported_source') unless $format->can('getCoverArt');
        $bytes = $format->getCoverArt($d->{path});
        return _failure('source_unavailable') unless defined($bytes) && length($bytes);
        $type = Slim::Music::Artwork->_imageContentType(\$bytes);
        return _failure('source_mismatch') unless length($bytes)==$d->{cover_length};
    } else {
        ($bytes,$type) = Slim::Music::Artwork->getImageContentAndType($d->{path});
        return _failure('source_unavailable') unless defined($bytes) && length($bytes);
    }
    return _failure('source_mismatch') unless _same_file($d);
    return _failure('native_error') unless defined($type) && length($type);
    return {ok=>1, (map {$_=>$d->{$_}} qw(album_id artwork_id track_id source_kind)),
        bytes=>$bytes, content_type=>$type};
}

1;
