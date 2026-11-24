package Plugins::MusicArtistInfo::Mosaicly::Orientation;

use strict;
use warnings;
use bytes;

# Only JPEG APP1 / primary TIFF IFD orientation. No nested IFD traversal.
# Missing, malformed or conflicting optional metadata is treated as normal.
sub jpeg_orientation {
    my ($class, $data) = @_;
    die 'expected encoded byte scalar reference' unless ref($data) eq 'SCALAR';
    my $n = length($$data);
    return 1 unless substr($$data, 0, 2) eq "\xff\xd8";
    my ($p, $found) = (2, undef);
    while ($p < $n) {
        return 1 unless ord(substr($$data, $p++, 1)) == 255;
        $p++ while $p < $n && ord(substr($$data, $p, 1)) == 255;
        return 1 if $p >= $n;
        my $marker = ord(substr($$data, $p++, 1));
        last if $marker == 0xda || $marker == 0xd9;
        return 1 if $marker == 0 || $marker == 0xd8 || ($marker >= 0xd0 && $marker <= 0xd7);
        next if $marker == 1;
        return 1 if $n - $p < 2;
        my $len = unpack('n', substr($$data, $p, 2));
        return 1 if $len < 2 || $len > $n - $p;
        if ($marker == 0xe1 && $len >= 8 &&
            substr($$data, $p + 2, 6) eq "Exif\0\0") {
            my ($valid, $o) = _tiff_orientation($data, $p + 8, $len - 8);
            return 1 unless $valid;
            if (defined $o) {
                return 1 if defined($found) && $found != $o;
                $found = $o;
            }
        }
        $p += $len;
    }
    return $found // 1;
}

sub _tiff_orientation {
    my ($data, $base, $len) = @_;
    return (0) if $len < 8;
    my $order = substr($$data, $base, 2);
    return (0) unless $order eq 'II' || $order eq 'MM';
    my ($short, $long) = $order eq 'II' ? ('v', 'V') : ('n', 'N');
    return (0) unless unpack($short, substr($$data, $base + 2, 2)) == 42;
    my $off = unpack($long, substr($$data, $base + 4, 4));
    return (0) if $off < 8 || $off > $len - 2;
    my $count = unpack($short, substr($$data, $base + $off, 2));
    $off += 2;
    return (0) if $len - $off < 4 || $count > int(($len - $off - 4) / 12);
    my $found;
    for (1 .. $count) {
        my $p = $base + $off;
        $off += 12;
        next unless unpack($short, substr($$data, $p, 2)) == 0x0112;
        return (0) unless unpack($short, substr($$data, $p + 2, 2)) == 3
            && unpack($long, substr($$data, $p + 4, 4)) == 1;
        my $o = unpack($short, substr($$data, $p + 8, 2));
        return (0) if $o < 1 || $o > 8 || (defined($found) && $found != $o);
        $found = $o;
    }
    return (1, $found);
}

# Input and output are tightly packed, top-down RGB byte scalars.
# Only operate on bounded prepared variants, never full-size source pixels.
# Return (RGB scalar reference, oriented width, oriented height).
sub transform {
    my ($class, $rgb, $w, $h, $o) = @_;
    die 'invalid RGB dimensions' unless defined($w) && defined($h)
        && !ref($w) && !ref($h) && $w =~ /\A[0-9]+\z/ && $h =~ /\A[0-9]+\z/
        && $w >= 1 && $h >= 1 && $w <= 1024 && $h <= 1024;
    die 'invalid RGB buffer' unless ref($rgb) eq 'SCALAR' && length($$rgb) == 3 * $w * $h;
    die 'invalid orientation' unless defined($o) && !ref($o) && $o =~ /\A[1-8]\z/;
    return ($rgb, $w, $h) if $o == 1;
    my ($ow, $oh) = $o >= 5 ? ($h, $w) : ($w, $h);
    my $out = '';
    for my $y (0 .. $oh - 1) {
        if ($o == 4) {
            $out .= substr($$rgb, ($h - 1 - $y) * $w * 3, $w * 3);
            next;
        }
        for my $x (0 .. $ow - 1) {
            my ($sx, $sy) =
                $o == 2 ? ($w - 1 - $x, $y) :
                $o == 3 ? ($w - 1 - $x, $h - 1 - $y) :
                $o == 5 ? ($y, $x) :
                $o == 6 ? ($y, $h - 1 - $x) :
                $o == 7 ? ($w - 1 - $y, $h - 1 - $x) :
                          ($w - 1 - $y, $x);
            $out .= substr($$rgb, 3 * ($sy * $w + $sx), 3);
        }
    }
    return (\$out, $ow, $oh);
}

1;
