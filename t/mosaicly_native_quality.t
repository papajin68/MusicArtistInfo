use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use MosaiclyTestSupport qw(load_native);
use Digest::SHA qw(sha256_hex);

load_native();

my $c='Plugins::MusicArtistInfoMosaicly::Mosaicly::Compositor';
my $bmp='Plugins::MusicArtistInfoMosaicly::Mosaicly::BMP';
my $png='Plugins::MusicArtistInfoMosaicly::Mosaicly::NormalizedPNG';

my $row=join '', map { my $v=int($_/50)%2 ? 255 : 0; pack('C3',$v,$v,$v) } 0..499;
my $pixels=$row x 500;
my $encoded=$bmp->encode(\$pixels,500,500);
my $im=Image::Scale->new($encoded) or BAIL_OUT('BMP open failed');
$im->resize_gm({width=>500,height=>500,keep_aspect=>0})
    or BAIL_OUT('BMP conversion failed');
my $jpeg=$im->as_jpeg(100);
undef $im;
undef $encoded;
undef $pixels;

for my $target (300,600) {
    my $reference=Image::Scale->new(\$jpeg) or BAIL_OUT('JPEG open failed');
    $reference->resize_gm_fixed_point({
        width=>$target,height=>$target,keep_aspect=>0,ignore_exif=>1,
    }) or BAIL_OUT('Fixed-point resize failed');
    my $normalized=$reference->as_png();
    my ($fixed,$w,$h)=$png->decode(\$normalized,pack('C3',32,32,32));
    my $p=$c->prepare(bytes=>$jpeg,variants=>[{width=>$target,height=>$target}]);
    ok($p->{ok},"$target compositor prepared");
    BAIL_OUT('Preparation failed') unless $p->{ok};
    my $actual=$p->{image}{variants}{"${target}x${target}"}{rgb};
    is(sha256_hex($$actual),sha256_hex($$fixed),"$target matches fixed-point reference");
    my ($chromatic,$inverted)=(0,0);
    for my $y (0..$target-1) {
        for my $x (0..$target-1) {
            my ($r,$g,$b)=unpack('C3',substr($$actual,3*($y*$target+$x),3));
            ++$chromatic if $r!=$g || $g!=$b;
            my $sx=($x+0.5)*500/$target;
            my $band=int($sx/50);
            my $position=$sx-50*$band;
            next if $position<5 || $position>45;
            ++$inverted if ($band%2 ? $r<128 : $r>127);
        }
    }
    is($chromatic,0,"$target grayscale preserved");
    is($inverted,0,"$target interior luminance preserved");
}
done_testing();
