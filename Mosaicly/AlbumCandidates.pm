package Plugins::MusicArtistInfo::Mosaicly::AlbumCandidates;

use strict;
use warnings;
use Encode qw(decode FB_CROAK);

sub _id {
    defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[1-9][0-9]*\z/;
}

sub _rows {
    my ($dbh, $sql, @bind) = @_;
    my $rows = $dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    die 'database query failed' unless defined($rows) && !$dbh->err;
    return $rows;
}

# Native adapter: never call variousArtistsObject(), which can write.
sub _native_context {
    require Slim::Schema;
    require Slim::Schema::Contributor;
    require Slim::Utils::Prefs;
    require Slim::Music::Info;
    require Slim::Utils::Text;
    my $dbh = Slim::Schema->dbh;
    my $prefs = Slim::Utils::Prefs::preferences('server');
    my @types = $prefs->get('useUnifiedArtistsList')
        ? Slim::Schema::Contributor->activeContributorRoles(1)
        : Slim::Schema::Contributor->contributorRoles();
    my @roles = map { Slim::Schema::Contributor->typeToRole($_) } @types;
    my $name = Slim::Utils::Text::ignoreCase(Slim::Music::Info::variousArtistString(), 1);
    my $va = _rows($dbh, 'SELECT id FROM contributors WHERE namesearch = ?', $name);
    die 'ambiguous Various Artists identity' if @$va > 1;
    return { dbh => $dbh, roles => \@roles,
        va_id => @$va ? $va->[0]{id} : undef,
        statistics => main::STATISTICS() ? 1 : 0 };
}

# Keyset pagination over committed, unassigned native contributor identities.
# The role policy is shared with album discovery; no directory-name grouping.
sub eligible_limit {
    my $ctx=_native_context();
    my ($max)=$ctx->{dbh}->selectrow_array('SELECT COALESCE(MAX(id),0) FROM contributors');
    die 'artist limit query failed' if $ctx->{dbh}->err || !defined($max);
    return $max;
}
sub eligible_page {
    my ($class,$after,$limit,$size)=@_;
    die 'invalid page bounds' unless defined($after) && $after=~/\A[0-9]+\z/
        && defined($limit) && $limit=~/\A[0-9]+\z/ && _id($size) && $size<=32;
    my $ctx=_native_context();
    my @roles=@{$ctx->{roles}};
    die 'invalid contributor roles' if grep {!_id($_)} @roles;
    my $filter=@roles ? ' AND ca.role IN ('.join(',',map {'?'} @roles).')' : '';
    my $sql="SELECT c.id FROM contributors c WHERE c.id>? AND c.id<=?
        AND c.portrait IS NULL AND c.portraitid IS NULL
        AND (c.id IN (SELECT ca.contributor FROM contributor_album ca
            WHERE ca.contributor>? AND ca.contributor<=?$filter)";
    my @bind=($after,$limit,$after,$limit,@roles);
    if (defined $ctx->{va_id}) {
        $sql.=' OR c.id=?';
        push @bind,$ctx->{va_id};
    }
    $sql.=') ORDER BY c.id LIMIT ?';
    push @bind,$size;
    my $rows=_rows($ctx->{dbh},$sql,@bind);
    return [map {$_->{id}} @$rows];
}
sub discover {
    my ($class, %args) = @_;
    return { ok => 0, reason => 'invalid_identity' } unless _id($args{contributor_id});
    # A context callback is a test seam; the default uses initialized LMS.
    my $context = exists($args{context}) ? $args{context} : \&_native_context;
    return { ok => 0, reason => 'invalid_context' } unless ref($context) eq 'CODE';
    my $r = eval { $class->_discover($args{contributor_id}, $context->()) };
    return { ok => 0, reason => 'native_error' } if $@ || !defined($r);
    return $r;
}

sub _discover {
    my ($class, $id, $ctx) = @_;
    die 'invalid native context' unless ref($ctx) eq 'HASH' && $ctx->{dbh}
        && ref($ctx->{roles}) eq 'ARRAY' && defined($ctx->{statistics})
        && $ctx->{statistics} =~ /\A[01]\z/
        && (!defined($ctx->{va_id}) || _id($ctx->{va_id}));
    my $dbh = $ctx->{dbh};
    my $exists = _rows($dbh, 'SELECT id FROM contributors WHERE id = ?', $id);
    return { ok => 0, reason => 'contributor_not_found' } unless @$exists;
    my %seen;
    my @roles = grep { !$seen{$_}++ } @{$ctx->{roles}};
    die 'invalid contributor roles' if grep { !_id($_) } @roles;
    my ($membership, @bind);
    my $membership_join = '';
    if (defined($ctx->{va_id}) && $id eq $ctx->{va_id}) {
        $membership = 'a.compilation = 1';
    } else {
        # Explicit deduplication avoids the SQLite 3.51 EXISTS-to-JOIN regression.
        my $role_filter = 'contributor = ?';
        push @bind, $id;
        if (@roles) {
            $role_filter .= ' AND role IN (' . join(',', map {'?'} @roles) . ')';
            push @bind, @roles;
        }
        $membership_join = "JOIN (SELECT DISTINCT album FROM contributor_album WHERE $role_filter) ca ON ca.album = a.id";
        $membership = '1 = 1';
    }

    # Native albums query joins the primary contributor. Native titles query
    # includes audio tracks except cpl/src/ssp/dir. No player library filter.
    my $sql = qq{
        WITH eligible AS (
            SELECT a.id, a.title, a.year, a.artwork
            FROM albums a JOIN contributors c ON c.id = a.contributor
            $membership_join
            WHERE $membership
        ), eligible_tracks AS (
            SELECT t.id, t.album, t.urlmd5
            FROM eligible e JOIN tracks t ON t.album = e.id
            WHERE t.audio = 1 AND t.content_type NOT IN ('cpl','src','ssp','dir')
        )
    };
    if ($ctx->{statistics}) {
        # Collapse per-track first; duplicate persistent matches are detected,
        # never allowed to multiply the album denominator.
        $sql .= q{
            , per_track AS (
                SELECT t.id, t.album, COUNT(p.id) AS matches,
                       MAX(p.playCount) AS plays
                FROM eligible_tracks t
                LEFT JOIN persistentdb.tracks_persistent p ON p.urlmd5 = t.urlmd5
                GROUP BY t.id, t.album
            ), stats AS (
                SELECT album, COUNT(*) AS track_count,
                    SUM(CASE WHEN matches > 1 THEN 1 ELSE 0 END) AS ambiguous,
                    SUM(CASE WHEN matches = 0 THEN 1 ELSE 0 END) AS missing_rows,
                    SUM(CASE WHEN matches = 1 AND plays IS NULL THEN 1 ELSE 0 END) AS null_counts,
                    SUM(CASE WHEN plays = 0 THEN 1 ELSE 0 END) AS zero_counts,
                    SUM(CASE WHEN plays > 0 THEN 1 ELSE 0 END) AS positive_counts,
                    SUM(CASE WHEN plays IS NOT NULL AND
                        (typeof(plays) NOT IN ('integer','real') OR plays < 0)
                        THEN 1 ELSE 0 END) AS invalid_counts,
                    AVG(COALESCE(plays,0)) AS mean_plays
                FROM per_track GROUP BY album
            )
            SELECT e.*, s.* FROM eligible e LEFT JOIN stats s ON s.album = e.id
            ORDER BY e.id
        };
    } else {
        $sql .= q{
            , stats AS (SELECT album, COUNT(*) AS track_count
                        FROM eligible_tracks GROUP BY album)
            SELECT e.*, s.track_count FROM eligible e
                LEFT JOIN stats s ON s.album = e.id ORDER BY e.id
        };
    }
    my $rows = _rows($dbh, $sql, @bind);
    my @candidates;
    my $skipped_titles = 0;
    my $unsupported_artwork = 0;
    my %album_seen;
    for my $r (@$rows) {
        return { ok => 0, reason => 'duplicate_album_rows' } if $album_seen{$r->{id}}++;
        return { ok => 0, reason => 'ambiguous_statistics' } if ($r->{ambiguous} // 0) > 0;
        return { ok => 0, reason => 'invalid_statistics' } if ($r->{invalid_counts} // 0) > 0;
        my $title = $r->{title} // '';
        $title = decode('UTF-8', $title, FB_CROAK) unless utf8::is_utf8($title);
        $title =~ s/\A\s+|\s+\z//g;
        # Python preferred raw title, falling back to album only if absent.
        # Native album fallback normally uses the same title (possibly disc suffix).
        unless (length($title)) { $skipped_titles++; next; }
        my $art = $r->{artwork};
        if (!defined($art) || $art eq '' || $art eq '0') {
            $art = undef;
        } elsif ($art =~ /\Ahttps?:\/\//i) {
            $unsupported_artwork++;
            $art = undef;
        } elsif ($art !~ /\A[0-9a-f]{8}\z/) {
            return { ok => 0, reason => 'invalid_artwork_identity' };
        }
        my $year = $r->{year};
        $year = undef if !defined($year) || $year eq '' || $year eq '0';
        die 'invalid year' if defined($year) && $year !~ /\A[0-9]+\z/;
        my $stats = { enabled => 0 + $ctx->{statistics} };
        if ($ctx->{statistics}) {
            for my $k (qw(missing_rows null_counts zero_counts positive_counts)) {
                $stats->{$k} = 0 + ($r->{$k} // 0);
            }
        }
        push @candidates, {
            album_id => $r->{id}, title => $title, artwork_id => $art,
            year => $year, track_count => 0 + ($r->{track_count} // 0),
            play_count => $r->{positive_counts} ? 0 + $r->{mean_plays} : undef,
            statistics => $stats,
        };
    }
    return { ok => 1, candidates => \@candidates,
        diagnostics => { skipped_empty_titles => $skipped_titles,
            unsupported_artwork => $unsupported_artwork, statistics_enabled => 0 + $ctx->{statistics} } };
}

1;
