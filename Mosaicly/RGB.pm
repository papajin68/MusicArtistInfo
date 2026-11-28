package Plugins::MusicArtistInfoMosaicly::Mosaicly::RGB;
use strict;
use warnings;
use bytes;

sub _int { defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[0-9]+\z/ }
sub _dim { _int($_[0]) && $_[0]>=1 && $_[0]<=1024 }
sub _source_dim { _int($_[0]) && $_[0]>=1 && $_[0]<=16384 }

# Fit in oriented coordinates, rounding to nearest pixel (half up).
sub fit {
    my ($class,$sw,$sh,$cw,$ch)=@_;
    die 'invalid fit dimensions' unless _source_dim($sw) && _source_dim($sh) && _dim($cw) && _dim($ch);
    my ($w,$h);
    if ($sw*$ch >= $sh*$cw) {
        $w=$cw; $h=int(($sh*$cw+int($sw/2))/$sw);
    } else {
        $h=$ch; $w=int(($sw*$ch+int($sh/2))/$sh);
    }
    $w=1 if $w<1; $h=1 if $h<1;
    return ($w,$h,int(($cw-$w)/2),int(($ch-$h)/2));
}
sub canvas {
    my ($class,$w,$h,$bg)=@_;
    die 'invalid canvas dimensions' unless _dim($w) && _dim($h);
    $bg="\x20\x20\x20" unless defined $bg;
    die 'invalid background' if ref($bg) || length($bg)!=3;
    my $rgb=$bg x ($w*$h);
    return \$rgb;
}
sub blit {
    my ($class,$dst,$dw,$dh,$src,$sw,$sh,$x,$y)=@_;
    die 'invalid blit dimensions' unless _dim($dw) && _dim($dh) && _dim($sw) && _dim($sh);
    die 'invalid destination buffer' unless ref($dst) eq 'SCALAR' && length($$dst)==3*$dw*$dh;
    die 'invalid source buffer' unless ref($src) eq 'SCALAR' && length($$src)==3*$sw*$sh;
    die 'aliased buffers' if $dst==$src;
    die 'blit outside canvas' unless _int($x) && _int($y) && $x<=$dw-$sw && $y<=$dh-$sh;
    for my $r (0..$sh-1) {
        substr($$dst,3*(($y+$r)*$dw+$x),3*$sw)=substr($$src,3*$r*$sw,3*$sw);
    }
    return 1;
}
1;
