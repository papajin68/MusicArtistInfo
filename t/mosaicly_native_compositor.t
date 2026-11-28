use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use MosaiclyTestSupport qw(load_native source_bmp sample_rgb decode_jpeg quadrant_jpeg insert_exif);
use Digest::SHA qw(sha256_hex);

load_native();

my $c = 'Plugins::MusicArtistInfoMosaicly::Mosaicly::Compositor';
my $layout = 'Plugins::MusicArtistInfoMosaicly::Mosaicly::Layout';

diag("Perl: $^V");
diag("Image::Scale: $Image::Scale::VERSION");

my @colors = (
    [224, 32, 32],
    [32, 208, 32],
    [32, 32, 224],
    [224, 224, 32],
);

# Preserve the validated smoke diagnostic's JPEG color tolerance.
sub near_color { MosaiclyTestSupport::near_color(@_, 8) }

# Default variant planning

is_deeply(
    $c->variants_for_slot(slot => 0),
    [
        {width => 600, height => 600},
        {width => 300, height => 300},
    ],
    'first slot supports full canvas and tile'
);

for my $slot (1 .. 3) {
    is_deeply(
        $c->variants_for_slot(slot => $slot),
        [{width => 300, height => 300}],
        "slot $slot supports tile only"
    );
}

# Complete mosaic generation
my %hashes;

for my $size (600, 601) {
    for my $mode ('repeat', 'solid') {

        my $profile = {
            canvas_size     => $size,
            tile_gap        => $size == 601 ? 2 : 0,
            incomplete_grid => $mode,
            background      => '202020',
        };

        my @images;

        for my $slot (0 .. 3) {
            my $source = source_bmp(
                80, 80, $colors[$slot]
            );

            my $variants = $c->variants_for_slot(
                slot    => $slot,
                profile => $profile,
            );

            my $p = $c->prepare(
                bytes    => $$source,
                profile  => $profile,
                variants => $variants,
            );

            BAIL_OUT(
                "Preparation failed: "
                . ($p->{reason} // 'unknown')
            ) unless $p->{ok};

            ok($p->{ok}, "Prepare $size $mode slot $slot");

            push @images, $p->{image};
        }

        for my $count (1 .. 4) {
            my $cells = $layout->plan(
                cover_count     => $count,
                canvas_size     => $size,
                tile_gap        => $profile->{tile_gap},
                incomplete_grid => $mode,
            );

            my @selected = @images[0 .. $count - 1];

            my $r = $c->render(
                images  => \@selected,
                layout  => $cells,
                profile => $profile,
            );

            my $label = "$size $mode $count covers";

            ok($r->{ok}, "$label generated");

            is(
                $r->{content_type},
                'image/jpeg',
                "$label content type"
            );

            is_deeply(
                [$r->{width}, $r->{height}],
                [$size, $size],
                "$label output dimensions"
            );

            my ($buf, $w, $h) =
                decode_jpeg($r->{bytes}, $size);

            is_deeply(
                [$w, $h],
                [$size, $size],
                "$label decoded dimensions"
            );

            for my $cell (@$cells) {
                my $x = $cell->{x}
                    + int($cell->{width} / 2);

                my $y = $cell->{y}
                    + int($cell->{height} / 2);

                my $expected =
                    defined($cell->{source_index})
                    ? $colors[$cell->{source_index}]
                    : [32,32,32];

                near_color(
                    sample_rgb($buf, $w, $x, $y),
                    $expected,
                    "$label cell $x,$y"
                );
            }

            $hashes{$size}{$mode}{$count} = sha256_hex($r->{bytes});
        }
    }
}

# One and four covers have identical layouts across modes. Two and three
# covers differ with these distinct synthetic colors and background.
for my $size (600, 601) {
    for my $count (1 .. 4) {
        my $label = "$size $count covers repeat/solid JPEG hashes";
        my ($repeat, $solid) = (
            $hashes{$size}{repeat}{$count},
            $hashes{$size}{solid}{$count},
        );
        if ($count == 1 || $count == 4) {
            is($repeat, $solid, "$label identical");
        } else {
            isnt($repeat, $solid, "$label distinct");
        }
    }
}

# Rectangular containment

my $source = source_bmp(80, 40, $colors[0]);

my $p = $c->prepare(
    bytes => $$source,
    variants => [
        {width => 600, height => 600},
        {width => 300, height => 300},
    ],
);

BAIL_OUT("Rectangular preparation failed")
    unless $p->{ok};

my $v = $p->{image}{variants}{'600x600'};

is_deeply(
    [@$v{qw(width height x y)}],
    [600,300,0,150],
    'landscape fits without stretching or cropping'
);

$v = $p->{image}{variants}{'300x300'};

is_deeply(
    [@$v{qw(width height x y)}],
    [300,150,0,75],
    'landscape tile geometry'
);

my $r = $c->render(
    images => [$p->{image}],
    layout => $layout->plan(cover_count => 1),
);

my ($buf, $w, $h) =
    decode_jpeg($r->{bytes}, 600);

near_color(
    sample_rgb($buf,$w,300,75),
    [32,32,32],
    'upper letterbox'
);

near_color(
    sample_rgb($buf,$w,300,300),
    $colors[0],
    'centered source artwork'
);

near_color(
    sample_rgb($buf,$w,300,525),
    [32,32,32],
    'lower letterbox'
);

# Repeated generation determinism
{
    my $source = insert_exif(
        quadrant_jpeg(1200,600),6
    );

    my @hashes;

    for my $iteration (1 .. 3) {
        my $p = $c->prepare(
            bytes => $source,
            variants => [
                {width=>600,height=>600},
            ],
        );

        BAIL_OUT("Determinism preparation failed")
            unless $p->{ok};

        my $r = $c->render(
            images => [$p->{image}],
            layout => $layout->plan(cover_count=>1),
        );

        ok($r->{ok}, "Generation $iteration");

        push @hashes, sha256_hex($r->{bytes});
    }

    is($hashes[1],$hashes[0],'Second generation identical');
    is($hashes[2],$hashes[0],'Third generation identical');
}

done_testing();
