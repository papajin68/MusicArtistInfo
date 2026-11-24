use strict;
use warnings;
use Test::More;
use FindBin;
require "$FindBin::Bin/../Mosaicly/ArtworkResolver.pm";

# Mock only the native boundary. No LMS bootstrap or real DB is involved.
our (%state, @calls);
BEGIN { $INC{'Slim/Schema.pm'} = __FILE__; $INC{'Slim/Music/Artwork.pm'} = __FILE__; }
{
    package Slim::Schema;
    sub dbh { bless {}, 'MockDB' }
    sub rs { die 'wrong resultset' unless $_[1] eq 'Track'; bless {}, 'MockRS' }
    package MockDB;
    sub selectrow_arrayref {
        my ($self, $sql, $attr, @bind) = @_;
        push @main::calls, ['sql', $sql, @bind];
        if ($sql eq 'SELECT artwork FROM albums WHERE id = ?') {
            die 'DB failure' if $main::state{db_throw};
            return $main::state{album};
        }
        if ($sql eq 'SELECT id, cover, url FROM tracks WHERE album = ? AND coverid = ? ORDER BY id LIMIT 1') {
            return $main::state{row};
        }
        die 'unexpected SQL';
    }
    sub err { $main::state{db_err} }
    package MockRS;
    sub find { push @main::calls, ['find', $_[1]]; return $main::state{track} }
    package MockTrack;
    sub cover { $_[0]{cover} }
    sub url { $_[0]{url} }
    sub path { $_[0]{path} }
    sub remote { $_[0]{remote} }
    sub audio { $_[0]{audio} }
    sub coverid { die 'must not call mutating coverid getter' }
    sub coverArt { die 'must not call discovery' }
    sub update { die 'must not update database' }
    package Slim::Music::Artwork;
    sub _readCoverArtTags {
        push @main::calls, ['embedded', $_[2]];
        die 'native extraction failed' if $main::state{throw};
        return @{$main::state{embedded}};
    }
    sub getImageContentAndType {
        push @main::calls, ['external', $_[1]];
        die 'native read failed' if $main::state{throw};
        return @{$main::state{external}};
    }
    sub readCoverArt { die 'must not rediscover' }
    sub _readCoverArtFiles { die 'must not search filesystem' }
}
my $class = 'Plugins::MusicArtistInfo::Mosaicly::ArtworkResolver';
my $art = '7993d16a';
sub reset_state {
    @calls = ();
    %state = (album => [$art], row => [2142, '4', 'file:///music/test.flac'],
        track => bless({cover=>'4',url=>'file:///music/test.flac',path=>'/music/test.flac',audio=>1,remote=>0}, 'MockTrack'),
        embedded => ['ABCD','image/jpeg',4], external => ['WXYZ','image/png']);
}
sub resolve { $class->resolve(album_id => 1564, artwork_id => $art, @_) }
sub failure {
    my ($expected,$name,@args)=@_;
    is_deeply(resolve(@args), {ok=>0,reason=>$expected}, $name);
}
sub native_calls { return [grep { $_->[0] eq 'embedded' || $_->[0] eq 'external' } @calls] }
reset_state();
is_deeply(resolve(), {ok=>1,album_id=>1564,artwork_id=>$art,track_id=>2142,source_kind=>'embedded',bytes=>'ABCD',content_type=>'image/jpeg'}, 'embedded result');
is_deeply(native_calls(), [['embedded','/music/test.flac']], 'embedded uses only native tag reader');
is_deeply($calls[0], ['sql','SELECT artwork FROM albums WHERE id = ?',1564], 'album identity bound');
is_deeply($calls[1], ['sql','SELECT id, cover, url FROM tracks WHERE album = ? AND coverid = ? ORDER BY id LIMIT 1',1564,$art], 'deterministic album-scoped selection');
reset_state(); $state{row}[1]='/music/Folder.jpg';
is_deeply(resolve(), {ok=>1,album_id=>1564,artwork_id=>$art,track_id=>2142,source_kind=>'external',bytes=>'WXYZ',content_type=>'image/png'}, 'external result');
is_deeply(native_calls(), [['external','/music/Folder.jpg']], 'only committed external path read');
ok(!grep($_->[0] eq 'find', @calls), 'external needs no track ORM lookup');
reset_state(); failure('invalid_identity','invalid album',album_id=>0); is(scalar @calls,0,'invalid input does not query');
reset_state(); failure('invalid_identity','invalid artwork ID',artwork_id=>'bad');
reset_state(); failure('invalid_identity','undefined artwork ID',artwork_id=>undef);
reset_state(); $state{album}=undef; failure('album_not_found','album missing');
reset_state(); $state{album}=[undef]; failure('no_selected_artwork','album artwork NULL');
reset_state(); $state{album}=['0']; failure('no_selected_artwork','album artwork zero');
reset_state(); $state{album}=['12345678']; failure('artwork_changed','changed album selection'); is_deeply(native_calls(),[],'stale ID never retrieves');
reset_state(); $state{row}=undef; failure('no_matching_track','no matching track');
for my $cover (undef,'','0','00') { reset_state(); $state{row}[1]=$cover; failure('no_recorded_source','missing or zero cover'); }
reset_state(); $state{track}=undef; failure('source_unavailable','track object missing');
reset_state(); $state{track}{cover}='5'; failure('source_mismatch','ORM cover differs from committed row');
reset_state(); $state{track}{url}='file:///other.flac'; failure('source_mismatch','ORM URL differs from committed row');
reset_state(); $state{embedded}=[]; failure('source_unavailable','embedded unavailable despite available external'); is_deeply(native_calls(),[['embedded','/music/test.flac']],'no external fallback');
reset_state(); $state{embedded}=['ABCDE','image/jpeg',5]; failure('source_mismatch','embedded length changed');
reset_state(); $state{embedded}=['ABCD','image/jpeg',5]; failure('source_mismatch','native length inconsistent');
reset_state(); $state{row}[1]='/music/missing.jpg'; $state{external}=[]; failure('source_unavailable','external unavailable despite available embedded'); is_deeply(native_calls(),[['external','/music/missing.jpg']],'no embedded fallback');
reset_state(); $state{throw}=1; failure('native_error','embedded native exception');
reset_state(); $state{row}[1]='/music/Folder.jpg'; $state{throw}=1; failure('native_error','external native exception');
reset_state(); $state{db_throw}=1; failure('native_error','database exception');
reset_state(); $state{db_err}=1; failure('native_error','database error without exception');
reset_state(); $state{embedded}=['ABCD','application/octet-stream',4]; is(resolve()->{content_type},'application/octet-stream','unknown MIME preserved');
reset_state(); $state{embedded}=['ABCD',undef,4]; failure('native_error','missing MIME');
reset_state(); $state{row}[2]='https://remote/track'; failure('unsupported_source','remote track URL'); is_deeply(native_calls(),[],'remote rejected before reader');
reset_state(); $state{row}[1]='https://remote/image.jpg'; failure('unsupported_source','remote cover URL');
reset_state(); $state{track}{remote}=1; failure('unsupported_source','remote track object');
reset_state(); $state{track}{audio}=0; failure('unsupported_source','non-audio track');
reset_state(); my $first=resolve(); is_deeply(resolve(),$first,'repeated calls deterministic');
done_testing();
