use strict;
use warnings;
use Test::More;
use Compress::Zlib qw(compress crc32);
require './Mosaicly/NormalizedPNG.pm';
require './Mosaicly/RGB.pm';
require './Mosaicly/BMP.pm';
require './Mosaicly/Layout.pm';
my $png='Plugins::MusicArtistInfo::Mosaicly::NormalizedPNG';
my $rgb='Plugins::MusicArtistInfo::Mosaicly::RGB';
my $bmp='Plugins::MusicArtistInfo::Mosaicly::BMP';
my $layout='Plugins::MusicArtistInfo::Mosaicly::Layout';
my $sig="\x89PNG\r\n\x1a\n";
sub chunk { my ($t,$d)=@_; pack('N',length($d)).$t.$d.pack('N',crc32($t.$d)) }
sub header { chunk('IHDR',pack('NNCCCCC',@_)) }
sub fixture {
    my ($w,$h,$type,$raw)=@_;
    return $sig.header($w,$h,8,$type,0,0,0).chunk('IDAT',compress($raw)).chunk('IEND','');
}
sub reject {
    my ($data,$re,$name)=@_;
    eval {$png->decode(\$data)};
    like($@,$re,$name);
}
# Independently calculated filtered bytes for two RGBA pixels per row.
# Row A: (10,20,30,255),(100,150,200,128)
# Row B: (40,50,60,0),(200,100,50,255)
my @a=(10,20,30,255,100,150,200,128);
my @b=(40,50,60,0,200,100,50,255);
my @filtered=(
    [@b],
    [40,50,60,0,160,50,246,255],
    [30,30,30,1,100,206,106,127],
    [35,40,45,129,130,0,176,191],
    [30,30,30,1,100,206,106,255],
);
my $expected=pack('C*',10,20,30,66,91,116,32,32,32,200,100,50);
for my $f (0..4) {
    my $data=fixture(2,2,6,pack('C*',0,@a,$f,@{$filtered[$f]}));
    my ($out,$w,$h)=$png->decode(\$data);
    is($$out,$expected,"RGBA filter $f");
    is_deeply([$w,$h],[2,2],"dimensions filter $f");
}
my $ga=fixture(3,1,4,pack('C*',0,48,255,192,128,100,0));
my ($out)=$png->decode(\$ga);
is($$out,pack('C*',48,48,48,112,112,112,32,32,32),'gray alpha');
($out)=$png->decode(\$ga,pack('C3',0,64,128));
is($$out,pack('C*',48,48,48,96,128,160,0,64,128),'custom background');
my $h=header(2,2,8,6,0,0,0);
my $raw=pack('C*',0,@a,0,@b);
my $z=compress($raw);
my $end=chunk('IEND','');
my $split=$sig.$h.join('',map {chunk('IDAT',$_)} split //,$z).$end;
($out)=$png->decode(\$split);
is($$out,$expected,'one-byte IDAT chunks');
my $big=fixture(1024,1024,6,("\0".pack('C4',1,2,3,255)x1024)x1024);
($out)=$png->decode(\$big);
is(length($$out),3*1024*1024,'maximum dimensions and multi-buffer inflate');
is($$out,pack('C3',1,2,3)x(1024*1024),'maximum image pixels');
reject('bad',qr/signature/,'bad signature');
reject($sig.chunk('IDAT',$z).$end,qr/IHDR/,'missing IHDR');
reject($sig.$h.$h.chunk('IDAT',$z).$end,qr/IHDR/,'duplicate IHDR');
reject($sig.header(1025,1,8,6,0,0,0),qr/dimensions/,'oversized');
reject($sig.header(0,1,8,6,0,0,0),qr/dimensions/,'zero dimensions');
reject($sig.header(1,1,16,6,0,0,0),qr/unsupported/,'16 bit');
reject($sig.header(1,1,8,2,0,0,0),qr/unsupported/,'RGB not normalized');
reject($sig.header(1,1,8,6,0,0,1),qr/unsupported/,'interlaced');
reject($sig.$h.chunk('PLTE','abc').chunk('IDAT',$z).$end,qr/critical/,'critical chunk');
reject($sig.$h.chunk('tRNS','x').chunk('IDAT',$z).$end,qr/transparency/,'unexpected tRNS');
reject($sig.$h.chunk('IDAT',substr($z,0,2)).chunk('tEXt','a').chunk('IDAT',substr($z,2)).$end,qr/nonconsecutive/,'split IDAT ordering');
reject($sig.$h.chunk('IDAT',$z.'x').$end,qr/extra compressed/,'trailing compressed bytes');
reject($sig.$h.chunk('IDAT',$z).chunk('IDAT','x').$end,qr/extra compressed/,'trailing IDAT');
reject($sig.$h.chunk('IDAT',substr($z,0,-1)).$end,qr/IEND/,'truncated zlib');
reject($sig.$h.chunk('IDAT',compress($raw.'x')).$end,qr/inflated limit/,'extra inflated byte');
reject($sig.$h.chunk('IDAT',compress('x'x100000)).$end,qr/inflated limit/,'bounded expansion');
reject($sig.$h.chunk('IDAT',compress(substr($raw,0,-1))).$end,qr/incomplete/,'short raw');
reject(fixture(2,2,6,pack('C*',5,@a,0,@b)),qr/filter/,'bad row filter');
reject($sig.$h.chunk('IDAT',$z),qr/incomplete/,'missing IEND');
reject($sig.$h.chunk('IDAT',$z).$end.'x',qr/IEND/,'trailing PNG bytes');
my $bad=$sig.$h.chunk('IDAT',$z).$end;
substr($bad,-1,1)=chr(ord(substr($bad,-1,1))^1);
reject($bad,qr/CRC/,'bad CRC');
reject($sig.$h.pack('N',0xffffffff).'IDAT',qr/truncated|length/,'oversized chunk');
for my $case (
    [80,40,61,31,61,31,0,0],
    [80,40,61,61,61,31,0,15],
    [40,80,61,61,31,61,15,0],
    [1,16384,300,300,1,300,149,0],
    [16384,1,300,300,300,1,0,149],
    [10,10,600,600,600,600,0,0]
) {
    my @c=@$case;
    my @in=splice(@c,0,4);
    is_deeply([$rgb->fit(@in)],\@c,"fit @in");
}
my $canvas=$rgb->canvas(3,2,'abc');
my $tile='XYZ123';
$rgb->blit($canvas,3,2,\$tile,1,2,1,0);
is($$canvas,'abcXYZabcabc123abc','blit columns');
for my $args ([-1,0],[3,0],[1,1]) {
    my $before=$$canvas;
    eval {$rgb->blit($canvas,3,2,\$tile,1,2,@$args)};
    like($@,qr/outside/,'invalid blit');
    is($$canvas,$before,'invalid blit leaves canvas unchanged');
}
for my $count (1..4) {
    for my $mode ('repeat','solid') {
        my $cells=$layout->plan(cover_count=>$count,canvas_size=>65,tile_gap=>2,incomplete_grid=>$mode);
        my $dst=$rgb->canvas(65,65,'...');
        for my $c (@$cells) {
            next unless defined $c->{source_index};
            my $color=chr(65+$c->{source_index})x3;
            my $src=$rgb->canvas($c->{width},$c->{height},$color);
            $rgb->blit($dst,65,65,$src,$c->{width},$c->{height},$c->{x},$c->{y});
        }
        for my $c (@$cells) {
            my $color=defined $c->{source_index}?chr(65+$c->{source_index})x3:'...';
            is(substr($$dst,3*($c->{y}*65+$c->{x}),3),$color,"cell $count $mode");
        }
        is(substr($$dst,3*(32*65+32),3),'...',"gap $count $mode") if $count>1;
    }
}
for my $w (1..4) {
    my $top=pack('C3',1,2,3)x$w;
    my $bottom=pack('C3',4,5,6)x$w;
    my $src=$top.$bottom;
    my $b=$bmp->encode(\$src,$w,2);
    my $pad=(4-3*$w%4)%4;
    my $stride=3*$w+$pad;
    is(substr($$b,0,2),'BM','BMP signature');
    is(unpack('V',substr($$b,2,4)),54+2*$stride,'BMP file size');
    is(unpack('V',substr($$b,10,4)),54,'BMP data offset');
    is_deeply([unpack('VVVvvVV',substr($$b,14,24))],[40,$w,2,1,24,0,2*$stride],'BMP DIB header');
    is(substr($$b,54),pack('C3',6,5,4)x$w.("\0"x$pad).pack('C3',3,2,1)x$w.("\0"x$pad),'BMP bottom-up BGR and padding');
}
done_testing();
