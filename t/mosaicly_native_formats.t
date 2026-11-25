use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use MosaiclyTestSupport qw(load_native bounded_progressive_enabled chunk make_png transparent_gif variant_pixel near_color);
use MIME::Base64 qw(decode_base64);
use Digest::SHA qw(sha256_hex);

load_native();

my $c = 'Plugins::MusicArtistInfo::Mosaicly::Compositor';
my $layout = 'Plugins::MusicArtistInfo::Mosaicly::Layout';

my $progressive = decode_base64(<<'BASE64');
/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoH
BwYIDAoMDAsLCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQME
BAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU
FBQUFBQUFBQUFBQUFBT/wgARCABQAFADASIAAhEBAxEB/8QAFwABAQEBAAAAAAAA
AAAAAAAAAAYIB//EABkBAQADAQEAAAAAAAAAAAAAAAAFBwgGCf/aAAwDAQACEAMQ
AAABixymgAF7BXsdRoRtHAQQ6PcYC9gr2Oo0I2jgIJIL40xXpAV97xPYtb8jyZ1l
W3I8mdZGOhueRAbFx1sXP8sGf5UDHQ9AOUAbFx1sXP8ALBn+VA//xAAUEAEAAAAA
AAAAAAAAAAAAAABg/9oACAEBAAEFAkn/xAArEQAAAgUKBwAAAAAAAAAAAAAAFgQQ
EROiByBCRGNkgsLh4gMFEiFRYnH/2gAIAQMBAT8BVKbU8eSbKbU8eRZzu8W0HO7
xbRz/AIppddnbtvs3qZ88ArW0OoK1tDqtBpTUGkv/xAAtEQAAAQUPBQAAAAAAAAAA
AAAABBAREhYBBQYHFSBCRGJkg6GiwuITIkFRYf/aAAgBAgEBPwExZRmllE7C3nTy
DC3nTyEMXrZ3od6663hCEK/XfYlGzmJRs5njXqWJsmxr1LE2H//EABQQAQAAAAAA
AAAAAAAAAAAAAGD/2gAIAQEABj8CSf/EABQQAQAAAAAAAAAAAAAAAAAAAGD/2gAIAQ
EAAT8hSf/aAAwDAQACAAMAAAAQCCV//CCV/wDzz3f/AP33z3333z33/8QAHREAAgEE
AwAAAAAAAAAAAAAAEcEgECEwQXGB8P/aAAgBAwEBPxDIREXqcdI5k6F4Kq3Fbr//
xAAfEQABAwMFAAAAAAAAAAAAAAARIMHwABDxITBBYXH/2gAIAQIBAT8Qs4yXGSZz
XV2nyBydI4VHDbVf/8QAFBABAAAAAAAAAAAAAAAAAAAAYP/aAAgBAQABPxBJ/9k=
BASE64

my $cmyk = decode_base64(
    '/9j/7gAOQWRvYmUAZAAAAAAA/9sAQwACAQEBAQECAQEBAgICAgIEAwICAgIFBAQDBAYFBgYGBQYGBgcJCAYHCQcGBggLCAkKCgoKCgYICwwLCgwJCgoK/8AAFAgAEAAQBEMRAE0RAFkRAEsRAP/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/aAA4EQwBNAFkASwAAPwD9/K/n/r+f+v38oooooooooooor//Z'
);

sub prepare_source {
    my ($bytes,%extra) = @_;

    return $c->prepare(
        bytes => $bytes,
        variants => [{width=>300,height=>300}],
        %extra,
    );
}

sub inspect_source {
    my ($name,$bytes,$left,$right,%extra) = @_;

    my $p = $c->prepare(
        bytes => $bytes,
        variants => [
            {width=>600,height=>600},
            {width=>300,height=>300},
        ],
        %extra,
    );

    ok($p->{ok},"$name prepared");

    unless ($p->{ok}) {
        diag("Reason: ".($p->{reason}//'unknown'));
        return;
    }

    my $v = $p->{image}{variants}{'300x300'};

    is_deeply(
        [@$v{qw(width height)}],
        [300,300],
        "$name dimensions"
    );

    near_color(
        variant_pixel($v,75,75),
        $left,
        "$name left interior"
    ) if defined $left;

    near_color(
        variant_pixel($v,225,75),
        $right,
        "$name right interior"
    ) if defined $right;

    my $r = $c->render(
        images => [$p->{image}],
        layout => $layout->plan(cover_count=>1),
    );

    ok($r->{ok},"$name rendered");

    is(
        $r->{content_type},
        'image/jpeg',
        "$name JPEG content type"
    );

    return $p;
}

# Progressive JPEG

is(
    sha256_hex($progressive),
    '0b0fa3767c3ece262c084c5ce9b1da0a2b48a26ab3844124408cb6e9d5a07448',
    'Progressive fixture fingerprint'
);

is_deeply(
    prepare_source($progressive),
    {ok=>0,reason=>'native_memory_limit'},
    'Progressive JPEG rejected without bounded worker'
);

SKIP: {
    skip 'Progressive decode requires external timeout and address-space bounds', 6
        unless bounded_progressive_enabled();
    inspect_source(
        'Progressive JPEG',
        $progressive,
        [224,32,32],
        [32,208,32],
        bounded_worker_progressive=>1,
    );
}

# Alternate JPEG and GIF formats

inspect_source(
    'CMYK JPEG',
    $cmyk,
    [255,0,0],
    [255,0,0],
);

my $gif_prepared = inspect_source(
    'Transparent GIF',
    transparent_gif(),
    undef,
    undef,
);
if ($gif_prepared) {
    my $v = $gif_prepared->{image}{variants}{'300x300'};
    is_deeply(variant_pixel($v,75,150), [224,32,64], 'GIF opaque interior');
    is_deeply(variant_pixel($v,225,150), [32,32,32], 'GIF transparent interior flattened');
}

# Grayscale PNG

my $gray_row = pack('C',48)x8 . pack('C',192)x8;
my $gray_raw = ("\0".$gray_row)x16;

inspect_source(
    '8-bit grayscale PNG',
    make_png(16,16,8,0,$gray_raw),
    [48,48,48],
    [192,192,192],
);


my $gray16_row =
    pack('n',0x3030)x8
    . pack('n',0xc0c0)x8;

my $gray16_raw = ("\0".$gray16_row)x16;

inspect_source(
    '16-bit grayscale PNG',
    make_png(16,16,16,0,$gray16_raw),
    [48,48,48],
    [192,192,192],
);

# Indexed PNG with transparency

my $palette =
    chunk('PLTE',pack('C6',224,32,64,32,208,96))
    . chunk('tRNS',pack('C2',255,0));

my $indexed_row = ("\0"x8).("\1"x8);
my $indexed_raw = ("\0".$indexed_row)x16;

inspect_source(
    'Indexed transparent PNG',
    make_png(16,16,8,3,$indexed_raw,$palette),
    [224,32,64],
    [32,32,32],
);

# Adam7 interlaced PNG

# Construct each Adam7 pass from the same known
# 16x16 two-color source image.

my @passes = (
    [0,0,8,8],
    [4,0,8,8],
    [0,4,4,8],
    [2,0,4,4],
    [0,2,2,4],
    [1,0,2,2],
    [0,1,1,2],
);

my $interlaced = '';

for my $pass (@passes) {
    my ($sx,$sy,$dx,$dy) = @$pass;

    for (my $y=$sy;$y<16;$y+=$dy) {
        $interlaced .= "\0";

        for (my $x=$sx;$x<16;$x+=$dx) {
            $interlaced .= $x<8
                ? pack('C3',224,32,64)
                : pack('C3',32,208,96);
        }
    }
}

inspect_source(
    'Adam7 interlaced PNG',
    make_png(16,16,8,2,$interlaced,'',1),
    [224,32,64],
    [32,208,96],
);

# Malformed source classification

for my $case (
    ['Empty','', 'empty_source'],
    ['Unsupported','not an image','unsupported_format'],
    ['Truncated JPEG',"\xff\xd8\xff",'corrupt_image'],
    ['Truncated PNG',"\x89PNG\r\n\x1a\n",'corrupt_image'],
    ['Truncated GIF','GIF89a','corrupt_image'],
    ['Truncated BMP','BM','corrupt_image'],
) {
    my ($name,$bytes,$reason) = @$case;

    my $r = eval { prepare_source($bytes) };

    if ($@) {
        fail("$name classified without exception");
        diag("Unexpected exception: $@");
        next;
    }

    is_deeply(
        $r,
        {ok=>0,reason=>$reason},
        "$name classified"
    );
}

# Resource-limit classification

# Valid signatures and IHDR structures with deliberately
# excessive declared dimensions. No large decoded buffers.

for my $case (
    [16385,16,'source_dimensions_exceeded'],
    [8193,8193,'source_pixel_limit'],
) {
    my ($w,$h,$reason) = @$case;

    my $source = make_png(
        $w,$h,8,2,"\0"
    );

    my $r = eval { prepare_source($source) };

    if ($@) {
        fail("${w}x${h} classified without exception");
        diag("Unexpected exception: $@");
        next;
    }

    is_deeply(
        $r,
        {ok=>0,reason=>$reason},
        "${w}x${h} resource rejection"
    );
}

# Invalid internal arguments

for my $case (
    [
        'Oversized canvas',
        sub {
            $c->variants_for_slot(
                slot=>0,
                profile=>{canvas_size=>1025}
            );
        },
        qr/canvas size/
    ],
    [
        'Invalid slot',
        sub {
            $c->variants_for_slot(slot=>4);
        },
        qr/invalid slot/
    ],
    [
        'Invalid background',
        sub {
            $c->variants_for_slot(
                slot=>0,
                profile=>{background=>'invalid'}
            );
        },
        qr/background/
    ],
    [
        'Oversized variant',
        sub {
            $c->prepare(
                bytes=>$progressive,
                variants=>[{width=>601,height=>600}]
            );
        },
        qr/invalid variant/
    ],
    [
        'Empty render image list',
        sub {
            $c->render(images=>[],layout=>[]);
        },
        qr/invalid prepared images/
    ],
) {
    my ($name,$callback,$expected) = @$case;

    eval { $callback->() };

    like($@,$expected,$name);
}

done_testing();
