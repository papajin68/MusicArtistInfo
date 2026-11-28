package Plugins::MusicArtistInfoMosaicly::Mosaicly::Selection;

use strict;
use warnings;
use feature 'fc';
use Digest::SHA qw(sha256_hex);
use Scalar::Util qw(looks_like_number);

# No LMS or imaging dependencies. Callbacks return classified result hashes.
my %retrieve_skip = map { $_ => 1 } qw(no_recorded_source unsupported_source source_unavailable);
my %prepare_skip = map { $_ => 1 } qw(empty_source unsupported_format corrupt_image source_too_large source_dimensions_exceeded source_pixel_limit native_memory_limit);
my %retrieve_fatal = map { $_ => 1 } qw(invalid_identity album_not_found no_selected_artwork artwork_changed no_matching_track source_mismatch native_error);

sub _id {
    defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[1-9][0-9]*\z/;
}

sub _scalar {
    defined($_[0]) && !ref($_[0]);
}

sub rank {
    my ($class, $candidates) = @_;
    die 'invalid candidates' unless ref($candidates) eq 'ARRAY';
    my %seen;
    my @unique;
    for my $c (@$candidates) {
        die 'invalid candidate' unless ref($c) eq 'HASH'
            && _id($c->{album_id}) && _scalar($c->{title});
        die 'invalid year' if defined($c->{year}) &&
            (ref($c->{year}) || $c->{year} !~ /\A[0-9]+\z/);
        die 'invalid play_count' if defined($c->{play_count}) &&
            (ref($c->{play_count}) || $c->{play_count} !~ /\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/
            || !looks_like_number($c->{play_count}) || "$c->{play_count}" =~ /inf|nan/i
            || $c->{play_count} > 1e100);
        die 'invalid artwork identity' if defined($c->{artwork_id}) &&
            (! _scalar($c->{artwork_id}) || $c->{artwork_id} !~ /\A[0-9a-f]{8}\z/);
        if (my $old = $seen{$c->{album_id}}) {
            for my $k (qw(title year play_count artwork_id)) {
                die 'conflicting duplicate album' if
                    defined($old->{$k}) != defined($c->{$k}) ||
                    (defined($c->{$k}) && $old->{$k} ne $c->{$k});
            }
            next;
        }
        $seen{$c->{album_id}} = $c;
        push @unique, $c;
    }
    return [sort {
        ($b->{year} // 0) <=> ($a->{year} // 0)
        || ($b->{play_count} // 0) <=> ($a->{play_count} // 0)
        || fc($a->{title}) cmp fc($b->{title})
        || length($a->{album_id}) <=> length($b->{album_id})
        || $a->{album_id} cmp $b->{album_id}
    } @unique];
}

sub _result_ok {
    my ($r) = @_;
    return ref($r) eq 'HASH' && _scalar($r->{ok}) && $r->{ok} =~ /\A[01]\z/;
}

sub select {
    my ($class, %args) = @_;
    my $diag = { candidate_count => 0, attempted_count => 0, selected_count => 0,
        skipped_count => 0, skipped => [] };
    my $fail = sub { return { ok => 0, reason => $_[0], diagnostics => $diag }; };
    my $max = exists($args{max_covers}) ? $args{max_covers} : 4;
    return $fail->('invalid_arguments') unless _scalar($max) && $max =~ /\A[1-4]\z/
        && ref($args{retrieve}) eq 'CODE' && ref($args{prepare}) eq 'CODE';
    my $ranked = eval { $class->rank($args{candidates}) };
    return $fail->('invalid_candidates') if $@ || !defined($ranked);
    $diag->{candidate_count} = scalar @$ranked;
    my (@selected, %observed, %accepted);
    my $skip = sub {
        my ($album, $reason) = @_;
        $diag->{skipped_count}++;
        # Bound detailed diagnostics independently of library size.
        push @{$diag->{skipped}}, { album_id => $album, reason => $reason }
            if @{$diag->{skipped}} < 100;
    };
    for my $c (@$ranked) {
        last if @selected >= $max;
        my ($album, $art) = @{$c}{qw(album_id artwork_id)};
        unless (defined($art)) {
            $skip->($album, 'no_selected_artwork');
            next;
        }
        $diag->{attempted_count}++;
        my $r = eval { $args{retrieve}->(album_id => $album, artwork_id => $art) };
        return $fail->('retrieve_exception') if $@;
        return $fail->('invalid_retrieve_result') unless _result_ok($r);
        unless ($r->{ok}) {
            my $reason = $r->{reason};
            return $fail->('invalid_retrieve_result') unless _scalar($reason);
            if ($retrieve_skip{$reason}) { $skip->($album, $reason); next; }
            return $fail->($retrieve_fatal{$reason} ? $reason : 'unknown_retrieve_failure');
        }
        return $fail->('invalid_retrieve_result') unless _id($r->{album_id})
            && $r->{album_id} eq $album && _scalar($r->{artwork_id})
            && $r->{artwork_id} eq $art && _id($r->{track_id})
            && _scalar($r->{bytes}) && !utf8::is_utf8($r->{bytes})
            && length($r->{bytes}) && _scalar($r->{content_type}) && length($r->{content_type})
            && _scalar($r->{source_kind}) && $r->{source_kind} =~ /\A(?:embedded|external)\z/;
        my $hash = sha256_hex($r->{bytes});
        return $fail->('artwork_identity_conflict') if exists($observed{$art}) && $observed{$art} ne $hash;
        $observed{$art} = $hash;
        if ($accepted{$hash}) { $skip->($album, 'duplicate_content'); next; }
        # The preparation callback receives only bytes and the accepted slot.
        # It owns format/resource policy and may prepare size variants by slot.
        my $p = eval { $args{prepare}->(bytes => $r->{bytes}, slot => scalar @selected) };
        return $fail->('prepare_exception') if $@;
        return $fail->('invalid_prepare_result') unless _result_ok($p);
        unless ($p->{ok}) {
            my $reason = $p->{reason};
            return $fail->('invalid_prepare_result') unless _scalar($reason);
            if ($prepare_skip{$reason}) { $skip->($album, $reason); next; }
            return $fail->('prepare_failed');
        }
        return $fail->('invalid_prepare_result') unless defined($p->{image});
        push @selected, { album_id => $album, artwork_id => $art,
            track_id => $r->{track_id}, source_kind => $r->{source_kind},
            sha256 => $hash, image => $p->{image} };
        $accepted{$hash} = 1;
        $diag->{selected_count} = scalar @selected;
    }
    return { ok => 1, selected => \@selected, diagnostics => $diag };
}

1;
