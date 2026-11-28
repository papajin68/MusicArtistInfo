package Plugins::MusicArtistInfoMosaicly::Mosaicly::Generator;

use strict;
use warnings;
use bytes;
use Plugins::MusicArtistInfoMosaicly::Mosaicly::AlbumCandidates;
use Plugins::MusicArtistInfoMosaicly::Mosaicly::ArtworkResolver;
use Plugins::MusicArtistInfoMosaicly::Mosaicly::Selection;
use Plugins::MusicArtistInfoMosaicly::Mosaicly::Layout;

my $discover = 'Plugins::MusicArtistInfoMosaicly::Mosaicly::AlbumCandidates';
my $resolver = 'Plugins::MusicArtistInfoMosaicly::Mosaicly::ArtworkResolver';
my $selection = 'Plugins::MusicArtistInfoMosaicly::Mosaicly::Selection';
my $compositor = 'Plugins::MusicArtistInfoMosaicly::Mosaicly::Compositor';
my $layout = 'Plugins::MusicArtistInfoMosaicly::Mosaicly::Layout';

# Internal worker entry point, never a server-event-loop API. The caller
# must enforce external timeout, process isolation and single-worker
# admission. Check actual hard/soft AS and core limits before acquisition.
sub _contained {
    open my $fh, '<', '/proc/self/limits' or return 0;
    my ($as, $core);
    while (<$fh>) {
        $as = $1 eq '268435456' && $2 eq '268435456'
            if /^Max address space\s+(\S+)\s+(\S+)/;
        $core = $1 eq '0' && $2 eq '0'
            if /^Max core file size\s+(\S+)\s+(\S+)/;
    }
    close $fh or return 0;
    return $as && $core;
}

sub generate {
    my ($class, %args) = @_;
    my $id = $args{contributor_id};
    return {ok=>0, reason=>'invalid_identity'} unless defined($id)
        && !ref($id) && $id =~ /\A[1-9][0-9]*\z/;
    my $progressive = $args{bounded_worker_progressive} // 0;
    return {ok=>0, reason=>'invalid_arguments'} if ref($progressive)
        || $progressive !~ /\A[01]\z/;
    return {ok=>0, reason=>'worker_containment_required'}
        unless _contained();
    my $r = eval {
        require Plugins::MusicArtistInfoMosaicly::Mosaicly::Compositor;
        if (exists $args{job}) {
            $class->_generate_job($id, $progressive, $args{job});
        } else {
            $class->_generate($id, $progressive);
        }
    };
    return {ok=>0, reason=>'generation_exception', contributor_id=>$id}
        if $@ || !defined($r);
    return $r;
}

# Shared ranking/budget policy. Only the server-side preparation step
# needs the initialized library when using the fresh-process worker.
sub _candidates {
    my ($d) = @_;
    my $ranked = $selection->rank($d->{candidates});
    my @available = grep { defined($_->{artwork_id}) } @$ranked;
    my $available_count = scalar @available;
    splice @available, 32 if @available > 32;
    return (\@available, {
        discovery=>$d->{diagnostics},
        discovered_count=>scalar(@$ranked),
        missing_artwork_count=>scalar(@$ranked)-$available_count,
        candidate_budget_omitted=>$available_count-scalar(@available),
    });
}

# Initialized server: capture metadata only, not artwork or native images.
sub prepare_job {
    my ($class,%args) = @_;
    my $id = $args{contributor_id};
    return {ok=>0,reason=>'invalid_identity'} unless defined($id)
        && !ref($id) && $id =~ /\A[1-9][0-9]*\z/;
    my $job = eval {
        my $d = $discover->discover(contributor_id=>$id);
        if (!$d->{ok}) {
            +{ok=>0,reason=>$d->{reason},contributor_id=>$id};
        } else {
            my ($candidates,$diag) = _candidates($d);
            my @entries;
            for my $c (@$candidates) {
                my $source = $resolver->describe(
                    album_id=>$c->{album_id},artwork_id=>$c->{artwork_id});
                # Keep failures in ranking order: Selection decides whether
                # to skip or fail, and need not visit lower-ranked entries.
                push @entries, {candidate=>$c,source=>$source};
            }
            +{ok=>1,contributor_id=>$id,entries=>\@entries,diagnostics=>$diag};
        }
    };
    return {ok=>0,reason=>'job_preparation_exception',contributor_id=>$id}
        if $@ || !defined($job);
    return $job;
}

sub _generate_job {
    my ($class,$id,$progressive,$job) = @_;
    my $invalid = {ok=>0,reason=>'invalid_job',contributor_id=>$id};
    return $invalid unless ref($job) eq 'HASH' && ($job->{ok}//0) eq '1'
        && defined($job->{contributor_id}) && !ref($job->{contributor_id})
        && $job->{contributor_id} eq $id && ref($job->{entries}) eq 'ARRAY'
        && @{$job->{entries}}<=32 && ref($job->{diagnostics}) eq 'HASH';
    my (@candidates,%sources);
    for my $entry (@{$job->{entries}}) {
        return $invalid unless ref($entry) eq 'HASH'
            && ref($entry->{candidate}) eq 'HASH' && ref($entry->{source}) eq 'HASH';
        my ($c,$d) = @$entry{qw(candidate source)};
        my ($album,$art) = @$c{qw(album_id artwork_id)};
        return $invalid unless defined($album) && !ref($album) && $album =~ /\A[1-9][0-9]*\z/
            && defined($art) && !ref($art) && $art =~ /\A[0-9a-f]{8}\z/
            && !exists($sources{$album})
            && defined($d->{ok}) && !ref($d->{ok}) && $d->{ok} =~ /\A[01]\z/;
        return $invalid if $d->{ok} && (($d->{album_id}//'') ne $album
            || ($d->{artwork_id}//'') ne $art);
        $sources{$album}=$d;
        push @candidates,$c;
    }
    return $class->_compose($id,$progressive,\@candidates,$job->{diagnostics},sub {
        my %a = @_;
        my $d = $sources{$a{album_id}};
        return $d unless $d->{ok};
        return $resolver->retrieve($d);
    });
}

# Retained initialized-runtime entry point for existing bounded callers.
sub _generate {
    my ($class, $id, $progressive) = @_;
    my $d = $discover->discover(contributor_id=>$id);
    return {ok=>0, reason=>$d->{reason}, contributor_id=>$id}
        unless $d->{ok};
    my ($candidates,$diag) = _candidates($d);
    return $class->_compose($id,$progressive,$candidates,$diag,
        sub { $resolver->resolve(@_) });
}

sub _compose {
    my ($class,$id,$progressive,$candidates,$base_diag,$retrieve) = @_;
    my $profile = {canvas_size=>600, tile_gap=>0,
        incomplete_grid=>'repeat', background=>'202020'};
    my $s = $selection->select(
        candidates=>$candidates, max_covers=>4,
        retrieve=>$retrieve,
        prepare=>sub {
            my %p = @_;
            # Progressive opt-in is a worker assertion of external timeout
            # in addition to the verified limits. Compositor identifies
            # progressive JPEGs and preserves native limits for other input.
            return $compositor->prepare(
                profile=>$profile, bytes=>$p{bytes},
                variants=>$compositor->variants_for_slot(
                    profile=>$profile, slot=>$p{slot}, max_covers=>4),
                source_limits=>{bytes=>4*1024*1024, axis=>3000, pixels=>9000000},
                bounded_worker_progressive=>$progressive,
            );
        },
    );
    my $diag = { %$base_diag, selection=>$s->{diagnostics} };
    return {ok=>0, reason=>$s->{reason}, contributor_id=>$id, diagnostics=>$diag}
        unless $s->{ok};
    my $selected = $s->{selected};
    return {ok=>0, reason=>'no_usable_artwork', contributor_id=>$id, diagnostics=>$diag}
        unless @$selected;
    my $plan = $layout->plan(cover_count=>scalar(@$selected),
        map { $_=>$profile->{$_} } qw(canvas_size tile_gap incomplete_grid));
    my $out = $compositor->render(profile=>$profile, layout=>$plan,
        images=>[map {$_->{image}} @$selected]);
    return {ok=>0, reason=>'invalid_render_result', contributor_id=>$id, diagnostics=>$diag}
        unless $out->{ok} && $out->{width}==600 && $out->{height}==600
        && $out->{content_type} eq 'image/jpeg' && defined($out->{bytes})
        && !ref($out->{bytes}) && !utf8::is_utf8($out->{bytes})
        && length($out->{bytes}) && length($out->{bytes})<=8*1024*1024;
    my @sources = map {
        my $entry = $_;
        +{ map { $_=>$entry->{$_} } qw(album_id artwork_id track_id source_kind sha256) }
    } @$selected;
    return { %$out, contributor_id=>$id, sources=>\@sources, diagnostics=>$diag };
}

1;
