package Plugins::MusicArtistInfoMosaicly::Mosaicly::NormalizedPNG;
use strict;
use warnings;
use bytes;
use Compress::Raw::Zlib qw(Z_OK Z_STREAM_END Z_BUF_ERROR MAX_WBITS crc32);

# Restricted internal interchange, not a general source-image decoder.
# Returns (packed RGB scalar reference, width, height); invalid input dies.
sub decode {
    my ($class, $png, $bg) = @_;
    die 'invalid PNG buffer' unless ref($png) eq 'SCALAR';
    $bg = "\x20\x20\x20" unless defined $bg;
    die 'invalid background' if ref($bg) || length($bg) != 3;
    die 'invalid PNG signature' unless substr($$png,0,8) eq "\x89PNG\r\n\x1a\n";
    die 'PNG encoded limit' if length($$png) > 8*1024*1024;
    my ($w,$h,$bpp,$stride,$limit,$z,$ended,$seen,$closed,$done);
    my ($p,$raw) = (8,'');
    while ($p < length($$png)) {
        die 'truncated PNG chunk' if length($$png)-$p < 12;
        my $n = unpack('N',substr($$png,$p,4));
        die 'invalid PNG chunk length' if $n > length($$png)-$p-12;
        my $tag = substr($$png,$p+4,4);
        die 'invalid PNG chunk name' unless $tag =~ /\A[A-Za-z]{2}[A-Z][A-Za-z]\z/;
        my $data = substr($$png,$p+8,$n);
        die 'PNG CRC mismatch' unless crc32($data,crc32($tag)) == unpack('N',substr($$png,$p+8+$n,4));
        $p += $n+12;
        die 'IHDR must be first' unless defined($w) || $tag eq 'IHDR';
        if ($tag eq 'IHDR') {
            die 'invalid IHDR' if defined($w) || $n != 13;
            my ($depth,$type,$comp,$filter,$interlace);
            ($w,$h,$depth,$type,$comp,$filter,$interlace)=unpack('NNCCCCC',$data);
            die 'PNG dimensions exceeded' unless $w>=1 && $h>=1 && $w<=1024 && $h<=1024;
            die 'unsupported normalized PNG' unless $depth==8 && ($type==4 || $type==6)
                && !$comp && !$filter && !$interlace;
            $bpp = $type==4 ? 2 : 4;
            $stride=$w*$bpp;
            $limit=$h*($stride+1);
            my $status;
            ($z,$status)=Compress::Raw::Zlib::Inflate->new(
                -WindowBits=>MAX_WBITS, -LimitOutput=>1, -Bufsize=>8192,
                -ConsumeInput=>1, -AppendOutput=>0);
            die 'inflate initialization failed' unless $status==Z_OK;
        } elsif ($tag eq 'IDAT') {
            die 'nonconsecutive IDAT' if $closed;
            $seen=1;
            die 'extra compressed data' if $ended && length($data);
            while (!$ended) {
                my $before=length($data);
                my $out='';
                my $status=$z->inflate($data,$out);
                die 'PNG inflated limit' if length($raw)+length($out)>$limit;
                $raw.=$out;
                if ($status==Z_STREAM_END) {
                    $ended=1;
                    die 'extra compressed data' if length($data);
                    last;
                }
                die 'invalid PNG deflate stream' unless $status==Z_OK || $status==Z_BUF_ERROR;
                last if !length($data) && !length($out);
                die 'inflate made no progress' if $before==length($data) && !length($out);
            }
        } elsif ($tag eq 'IEND') {
            die 'invalid IEND' unless !$n && $seen && $ended && $p==length($$png);
            $done=1;
            last;
        } else {
            die 'unsupported critical PNG chunk' if $tag =~ /\A[A-Z]/;
            die 'unexpected transparency chunk' if $tag eq 'tRNS';
            $closed=1 if $seen;
        }
    }
    die 'incomplete normalized PNG' unless $done && length($raw)==$limit;
    my @bg=unpack('C3',$bg);
    my @prev=(0)x$stride;
    my $rgb='';
    for my $y (0..$h-1) {
        my $pos=$y*($stride+1);
        my $f=ord(substr($raw,$pos,1));
        die 'invalid PNG row filter' if $f>4;
        my @row=unpack('C*',substr($raw,$pos+1,$stride));
        if ($f) {
            for my $i (0..$#row) {
                my $a=$i>=$bpp?$row[$i-$bpp]:0;
                my $b=$prev[$i];
                my $c=$i>=$bpp?$prev[$i-$bpp]:0;
                my $pred=$f==1?$a:$f==2?$b:$f==3?int(($a+$b)/2):_paeth($a,$b,$c);
                $row[$i]=($row[$i]+$pred)&255;
            }
        }
        for (my $i=0;$i<$stride;$i+=$bpp) {
            my $a=$row[$i+$bpp-1];
            my @c=$bpp==4?@row[$i..$i+2]:($row[$i])x3;
            $rgb.= $a==255?pack('C3',@c):$a==0?$bg:
                pack('C3',map {int(($c[$_]*$a+$bg[$_]*(255-$a)+127)/255)} 0..2);
        }
        @prev=@row;
    }
    return (\$rgb,$w,$h);
}
sub _paeth {
    my ($a,$b,$c)=@_;
    my $p=$a+$b-$c;
    my ($pa,$pb,$pc)=map {abs($p-$_)} ($a,$b,$c);
    return $pa<=$pb && $pa<=$pc?$a:$pb<=$pc?$b:$c;
}
1;
