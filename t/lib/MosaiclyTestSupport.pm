package MosaiclyTestSupport;
use strict;
use warnings;
use Exporter 'import';
use File::Basename qw(dirname);
use File::Spec;
use Test::More ();
use Compress::Zlib qw(compress crc32);
use MIME::Base64 qw(decode_base64);

our @EXPORT_OK = qw(
    load_native bounded_progressive_enabled
    chunk make_png transparent_gif source_bmp
    sample_rgb variant_pixel near_color decode_jpeg
    quadrant_jpeg insert_exif
);

# Native suites skip only if Image::Scale itself is absent. An installed
# module with a missing dependency, broken XS loader, or other error fails.
# Production Mosaicly load failures must also remain visible.
sub load_native {
    unless (eval { require Image::Scale; 1 }) {
        my $error = $@;
        if ($error =~ /\ACan't locate Image\/Scale\.pm in \@INC\b/) {
            Test::More::plan(skip_all => 'Native Image::Scale unavailable');
        }
        die $error;
    }

    my $root = File::Spec->rel2abs(
        File::Spec->catdir(dirname(__FILE__), '..', '..')
    );
    for my $module (qw(Layout RGB BMP NormalizedPNG Orientation Compositor)) {
        my $file = File::Spec->catfile($root, 'Mosaicly', "$module.pm");
        require $file;
        $INC{"Plugins/MusicArtistInfoMosaicly/Mosaicly/$module.pm"} = $file;
    }
}

# The opt-in is a caller assertion that an external timeout is in force.
# Additionally require the established hard/soft Linux address-space cap
# before allowing the native progressive decoder to omit memory_limit.
sub bounded_progressive_enabled {
    return 0 unless ($ENV{MOSAICLY_TEST_BOUNDED_PROGRESSIVE} // '') eq '1';
    open my $fh, '<', '/proc/self/limits'
        or die "Progressive test requires verifiable external process limits: $!";
    my ($soft, $hard);
    while (<$fh>) {
        if (/^Max address space\s+(\S+)\s+(\S+)/) {
            ($soft, $hard) = ($1, $2);
            last;
        }
    }
    close $fh;
    die "Progressive test requires soft and hard address-space limits <= 256 MiB\n"
        unless defined($soft) && defined($hard)
            && $soft =~ /\A[0-9]+\z/ && $hard =~ /\A[0-9]+\z/
            && $soft <= 268435456 && $hard <= 268435456;
    return 1;
}

my $rgb = 'Plugins::MusicArtistInfoMosaicly::Mosaicly::RGB';
my $bmp = 'Plugins::MusicArtistInfoMosaicly::Mosaicly::BMP';
my $png = 'Plugins::MusicArtistInfoMosaicly::Mosaicly::NormalizedPNG';

sub chunk {
    my ($tag,$data) = @_;

    return pack('N',length($data))
        . $tag
        . $data
        . pack('N',crc32($tag.$data));
}

sub make_png {
    my ($w,$h,$depth,$type,$raw,$extra,$interlace) = @_;

    return "\x89PNG\r\n\x1a\n"
        . chunk('IHDR',pack(
            'NNCCCCC',
            $w,$h,$depth,$type,0,0,$interlace // 0
        ))
        . ($extra // '')
        . chunk('IDAT',compress($raw))
        . chunk('IEND','');
}

sub transparent_gif {
    return decode_base64(
        'R0lGODlhEAAQAIEAAOAgQCDQYAAAAAAAACH5BAEAAAEALAAAAAAQABAAQAg2AAEIHCgwgMGDBgkSRIhQ4UCGBx0WhBhAIgCKFSVitLhRI0WOHz1CBDlSJEOSJ002VBmRpcGAADs='
    );
}

sub source_bmp {
    my ($w, $h, $color) = @_;

    my $buf = $rgb->canvas(
        $w, $h, pack('C3', @$color)
    );

    return $bmp->encode($buf, $w, $h);
}

sub sample_rgb {
    my ($buf, $w, $x, $y) = @_;

    return [
        unpack(
            'C3',
            substr($$buf, 3 * ($y * $w + $x), 3)
        )
    ];
}

sub variant_pixel {
    my ($v, $x, $y) = @_;
    return sample_rgb($v->{rgb}, $v->{width}, $x, $y);
}

sub near_color {
    my ($actual,$expected,$label,$tolerance) = @_;

    $tolerance //= 5;

    my $ok = 1;

    for my $i (0..2) {
        $ok = 0
            if abs($actual->[$i]-$expected->[$i])
                > $tolerance;
    }

    Test::More::ok($ok,$label);

    Test::More::diag(
        "Actual=".join(',',@$actual)
        ." expected=".join(',',@$expected)
    ) unless $ok;
}

sub decode_jpeg {
    my ($bytes, $size) = @_;

    my $im = Image::Scale->new(\$bytes)
        or die "JPEG constructor failed\n";

    $im->resize_gm({
        width        => $size,
        height       => $size,
        keep_aspect  => 0,
        memory_limit => 64 * 1024 * 1024,
    }) or die "JPEG decode failed\n";

    my $normalized = $im->as_png();

    undef $im;

    return $png->decode(\$normalized);
}

# Independent quadrant fixture; deliberately does not use Mosaicly's BMP encoder.
my @colors = (
    [224, 32, 32],
    [32, 208, 32],
    [32, 32, 224],
    [224, 224, 32],
);

sub make_bmp {
    my ($w, $h) = @_;

    my $stride = ($w * 3 + 3) & ~3;
    my $pixels = '';

    for my $y (reverse 0 .. $h - 1) {
        my $row = '';

        for my $x (0 .. $w - 1) {
            my $index =
                ($y >= $h / 2 ? 2 : 0) +
                ($x >= $w / 2 ? 1 : 0);

            $row .= pack(
                'C3',
                reverse @{$colors[$index]}
            );
        }

        $pixels .= $row .
            ("\0" x ($stride - length($row)));
    }

    return
        pack('a2VvvV',
            'BM', 54 + length($pixels), 0, 0, 54)
        .
        pack('V3v2V6',
            40, $w, $h, 1, 24,
            0, length($pixels), 0, 0, 0, 0)
        .
        $pixels;
}

sub quadrant_jpeg {
    my ($w, $h) = @_;

    my $bmp = make_bmp($w, $h);

    my $img = Image::Scale->new(\$bmp)
        or die "BMP constructor failed\n";

    $img->resize_gm({
        width        => $w,
        height       => $h,
        memory_limit => 64 * 1024 * 1024,
    }) or die "BMP resize failed\n";

    my $jpeg = $img->as_jpeg(100);

    die "Invalid generated JPEG\n"
        unless defined($jpeg)
        && substr($jpeg, 0, 2) eq "\xff\xd8";

    return $jpeg;
}

sub insert_exif {
    my ($jpeg, $orientation) = @_;

    my $tiff =
        'II'
        . pack('vV', 42, 8)
        . pack('v', 1)
        . pack('vvVvv',
            0x0112, 3, 1, $orientation, 0)
        . pack('V', 0);

    my $payload = "Exif\0\0" . $tiff;

    return
        substr($jpeg, 0, 2)
        . "\xff\xe1"
        . pack('n', length($payload) + 2)
        . $payload
        . substr($jpeg, 2);
}

1;
