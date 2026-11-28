package Plugins::MusicArtistInfoMosaicly::Mosaicly::BMP;
use strict;
use warnings;
use bytes;

# Windows BITMAPINFOHEADER, uncompressed 24-bit BGR, bottom-up.
sub encode {
    my ($class,$rgb,$w,$h)=@_;
    die 'invalid BMP dimensions' unless defined($w) && defined($h)
        && !ref($w) && !ref($h) && $w =~ /\A[0-9]+\z/ && $h =~ /\A[0-9]+\z/
        && $w>=1 && $h>=1 && $w<=1024 && $h<=1024;
    die 'invalid RGB buffer' unless ref($rgb) eq 'SCALAR' && length($$rgb)==3*$w*$h;
    my $stride=3*$w;
    my $padding=(4-$stride%4)%4;
    my $size=($stride+$padding)*$h;
    my $bmp=pack('a2VvvV','BM',54+$size,0,0,54)
        .pack('VVVvvVVVVVV',40,$w,$h,1,24,0,$size,0,0,0,0);
    for (my $y=$h-1;$y>=0;$y--) {
        my $row=substr($$rgb,$y*$stride,$stride);
        $row =~ s/(.)(.)(.)/$3$2$1/gs;
        $bmp.=$row.("\0"x$padding);
    }
    return \$bmp;
}
1;
