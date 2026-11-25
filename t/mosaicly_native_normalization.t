use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use MosaiclyTestSupport qw(load_native make_png variant_pixel quadrant_jpeg insert_exif);

load_native();

my $c = 'Plugins::MusicArtistInfo::Mosaicly::Compositor';

my @colors = (
    [224, 32, 32],
    [32, 208, 32],
    [32, 32, 224],
    [224, 224, 32],
);

my @labels = qw(R G B Y);

my %expected = (
    1 => 'RGBY',
    2 => 'GRYB',
    3 => 'YBGR',
    4 => 'BYRG',
    5 => 'RBGY',
    6 => 'BRYG',
    7 => 'YGBR',
    8 => 'GYRB',
);

sub classify {
    my ($r, $g, $b) = @_;

    my ($best, $distance);

    for my $i (0 .. $#colors) {
        my ($cr, $cg, $cb) = @{$colors[$i]};

        my $d =
            ($r - $cr)**2 +
            ($g - $cg)**2 +
            ($b - $cb)**2;

        if (!defined($distance) || $d < $distance) {
            ($best, $distance) = ($i, $d);
        }
    }

    return '?' if $distance > 2500;
    return $labels[$best];
}

sub quadrants {
    my ($w, $h, $bpp, $rows) = @_;
    my $result = '';

    for my $yf (0.25, 0.75) {
        for my $xf (0.25, 0.75) {
            my $x = int($w * $xf);
            my $y = int($h * $yf);

            die "Pixel sample out of bounds\n"
                unless $x >= 0 && $x < $w
                && $y >= 0 && $y < $h;

            my ($r, $g, $b) = unpack(
                'C3',
                substr($rows->[$y], $x * $bpp, 3)
            );

            $result .= classify($r, $g, $b);
        }
    }

    return $result;
}

# Production-size EXIF orientation

for my $case (
    [600, 600, 600],
    [1200, 1200, 600],
    [1200, 1200, 300],
    [2400, 2400, 300],
    [1200, 600, 600],
    [600, 1200, 600],
) {
    my ($sw, $sh, $size) = @$case;

    my $base = quadrant_jpeg($sw, $sh);

    for my $o (1 .. 8) {
        my $jpeg = insert_exif($base, $o);

        my $p = $c->prepare(
            bytes => $jpeg,
            variants => [
                {width => $size, height => $size},
            ],
        );

        my $label = "${sw}x${sh} -> $size EXIF=$o";

        ok($p->{ok}, "$label prepared");

        next unless $p->{ok};

        my $v = $p->{image}{variants}{"${size}x${size}"};

        my ($w, $h) = @$v{qw(width height)};

        my ($ew, $eh) = ($size, $size);

        if ($sw != $sh) {
            my $landscape = $sw > $sh;

            $landscape = !$landscape if $o >= 5;

            if ($landscape) {
                $eh = int($size / 2);
            }
            else {
                $ew = int($size / 2);
            }
        }

        is_deeply(
            [$w, $h],
            [$ew, $eh],
            "$label dimensions"
        );

        my @rows;

        for my $y (0 .. $h - 1) {
            push @rows, substr(
                ${$v->{rgb}},
                $y * $w * 3,
                $w * 3
            );
        }

        is(
            quadrants($w, $h, 3, \@rows),
            $expected{$o},
            "$label orientation"
        );
    }
}

# Native transparency workaround
sub alpha_fixture {
    my ($alpha) = @_;

    my $row =
        pack('C4', 224,32,64,255) x 300
        . pack('C4', 32,208,96,$alpha) x 300;

    my $raw = ("\0" . $row) x 600;

    return make_png(600,600,8,6,$raw);
}

for my $alpha (0,128,255) {
    my $source = alpha_fixture($alpha);

    my $p = $c->prepare(
        bytes => $source,
        variants => [
            {width=>300,height=>300},
        ],
    );

    ok($p->{ok}, "Alpha $alpha prepared");

    next unless $p->{ok};

    my $v = $p->{image}{variants}{'300x300'};

    is_deeply(
        variant_pixel($v,75,150),
        [224,32,64],
        "Alpha $alpha opaque interior"
    );

    my $expected_rgb = [
        map {
            int(
                ($_ * $alpha
                + 32 * (255-$alpha)
                + 127) / 255
            )
        } (32,208,96)
    ];

    is_deeply(
        variant_pixel($v,225,150),
        $expected_rgb,
        "Alpha $alpha flattened interior"
    );

    # Severe dark holes or bright spikes should not occur
    # several pixels away from this simple boundary.
    is_deeply(
        variant_pixel($v,145,150),
        [224,32,64],
        "Alpha $alpha stable opaque edge"
    );

    is_deeply(
        variant_pixel($v,154,150),
        $expected_rgb,
        "Alpha $alpha stable opposite edge"
    );
}

done_testing();
