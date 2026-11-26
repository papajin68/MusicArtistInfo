package Plugins::MusicArtistInfo::Mosaicly::Generator;

use strict;
use warnings;
use bytes;
use Plugins::MusicArtistInfo::Mosaicly::AlbumCandidates;
use Plugins::MusicArtistInfo::Mosaicly::ArtworkResolver;
use Plugins::MusicArtistInfo::Mosaicly::Selection;
use Plugins::MusicArtistInfo::Mosaicly::Compositor;
use Plugins::MusicArtistInfo::Mosaicly::Layout;

my $discover = 'Plugins::MusicArtistInfo::Mosaicly::AlbumCandidates';
my $resolver = 'Plugins::MusicArtistInfo::Mosaicly::ArtworkResolver';
my $selection = 'Plugins::MusicArtistInfo::Mosaicly::Selection';
my $compositor = 'Plugins::MusicArtistInfo::Mosaicly::Compositor';
my $layout = 'Plugins::MusicArtistInfo::Mosaicly::Layout';

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
    my $r = eval { $class->_generate($id, $progressive) };
    return {ok=>0, reason=>'generation_exception', contributor_id=>$id}
        if $@ || !defined($r);
    return $r;
}

sub _generate {
    my ($class, $id, $progressive) = @_;
    my $profile = {canvas_size=>600, tile_gap=>0,
        incomplete_grid=>'repeat', background=>'202020'};
    my $d = $discover->discover(contributor_id=>$id);
    return {ok=>0, reason=>$d->{reason}, contributor_id=>$id}
        unless $d->{ok};

    # Keep accepted ranking and bound native acquisition attempts.
    # Missing artwork does not consume the 32-source budget.
    my $ranked = $selection->rank($d->{candidates});
    my @available = grep { defined($_->{artwork_id}) } @$ranked;
    my $available_count = scalar @available;
    splice @available, 32 if @available > 32;

    my $s = $selection->select(
        candidates=>\@available, max_covers=>4,
        retrieve=>sub { $resolver->resolve(@_) },
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
    my $diag = {
        discovery=>$d->{diagnostics}, selection=>$s->{diagnostics},
        discovered_count=>scalar(@$ranked),
        missing_artwork_count=>scalar(@$ranked)-$available_count,
        candidate_budget_omitted=>$available_count-scalar(@available),
    };
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
