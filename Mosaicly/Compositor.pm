package Plugins::MusicArtistInfo::Mosaicly::Compositor;
use strict;
use warnings;
use bytes;
use Image::Scale;
use Plugins::MusicArtistInfo::Mosaicly::Layout;
use Plugins::MusicArtistInfo::Mosaicly::RGB;
use Plugins::MusicArtistInfo::Mosaicly::BMP;
use Plugins::MusicArtistInfo::Mosaicly::NormalizedPNG;
use Plugins::MusicArtistInfo::Mosaicly::Orientation;

my $layout='Plugins::MusicArtistInfo::Mosaicly::Layout';
my $rgb='Plugins::MusicArtistInfo::Mosaicly::RGB';
my $bmp='Plugins::MusicArtistInfo::Mosaicly::BMP';
my $png='Plugins::MusicArtistInfo::Mosaicly::NormalizedPNG';
my $orient='Plugins::MusicArtistInfo::Mosaicly::Orientation';
use constant SOURCE_BYTES => 64*1024*1024;
use constant SOURCE_DIM => 16384;
use constant SOURCE_PIXELS => 67108864;
use constant NATIVE_LIMIT => 512*1024*1024;
use constant RETAINED_LIMIT => 16*1024*1024;
use constant JPEG_LIMIT => 8*1024*1024;

sub _failure { return {ok=>0,reason=>$_[0]} }
sub _int { defined($_[0]) && !ref($_[0]) && $_[0]=~/\A[0-9]+\z/ }
sub _dim { _int($_[0]) && $_[0]>=1 && $_[0]<=1024 }
sub _profile {
    my ($p)=@_;
    $p={} unless defined $p;
    die 'invalid compositor profile' unless ref($p) eq 'HASH';
    my %v=(canvas_size=>600,tile_gap=>0,incomplete_grid=>'repeat',background=>'202020',%$p);
    die 'invalid compositor canvas size' unless _dim($v{canvas_size});
    die 'invalid compositor background' unless defined($v{background}) && !ref($v{background})
        && $v{background}=~/\A[0-9a-fA-F]{6}\z/;
    $v{background}=lc($v{background});
    $layout->plan(cover_count=>1,map {$_=>$v{$_}} qw(canvas_size tile_gap incomplete_grid));
    return \%v;
}
sub _format {
    my ($s)=@_;
    return 'jpeg' if substr($$s,0,2) eq "\xff\xd8";
    return 'png' if substr($$s,0,8) eq "\x89PNG\r\n\x1a\n";
    return 'gif' if substr($$s,0,6)=~/\AGIF8[79]a\z/;
    return 'bmp' if substr($$s,0,2) eq 'BM';
    return;
}
# Identify progressive JPEG SOF before SOS; never retry unknown failures
# with memory_limit removed.
sub _progressive {
    my ($s)=@_;
    my ($p,$n)=(2,length($$s));
    while ($p<$n) {
        return 0 unless substr($$s,$p++,1) eq "\xff";
        $p++ while $p<$n && substr($$s,$p,1) eq "\xff";
        return 0 if $p>=$n;
        my $m=ord(substr($$s,$p++,1));
        return 0 if $m==0xda || $m==0xd9;
        next if $m==1;
        return 0 if $m==0 || $m==0xd8 || ($m>=0xd0 && $m<=0xd7) || $n-$p<2;
        my $l=unpack('n',substr($$s,$p,2));
        return 0 if $l<2 || $l>$n-$p;
        return 1 if $m==0xc2 || $m==0xca;
        $p+=$l;
    }
    return 0;
}
sub variants_for_slot {
    my ($class,%args)=@_;
    my $p=_profile($args{profile});
    my $slot=$args{slot};
    my $max=$args{max_covers}//4;
    die 'invalid slot' unless _int($slot) && _int($max) && $max>=1 && $max<=4 && $slot<$max;
    my (%seen,@out);
    for my $n ($slot+1..$max) {
        for my $c (@{$layout->plan(cover_count=>$n,map {$_=>$p->{$_}} qw(canvas_size tile_gap incomplete_grid))}) {
            next unless defined($c->{source_index}) && $c->{source_index}==$slot;
            my $key=$c->{width}.'x'.$c->{height};
            push @out,{width=>$c->{width},height=>$c->{height}} unless $seen{$key}++;
        }
    }
    return \@out;
}
# Native 0.14 can throw a buffer error on truncated source headers.
# Classify only known malformed-input exceptions; unexpected errors stay fatal.
sub _open_source {
    my ($bytes)=@_;
    my $im=eval { Image::Scale->new($bytes) };
    if ($@) {
        return undef if $@ =~ /\Abuffer_consume: buffer error(?: at |\n|\z)/;
        die $@;
    }
    return $im;
}
sub _resize {
    my ($im,$method,$opts)=@_;
    my $ok=eval {$im->$method($opts)};
    if ($@) {
        return _failure('native_memory_limit') if $@ =~ /Image::Scale memory_limit exceeded/;
        die $@;
    }
    return $ok ? {ok=>1} : _failure('corrupt_image');
}
sub prepare {
    my ($class,%args)=@_;
    my $p=_profile($args{profile});
    my $v=$args{variants};
    die 'invalid variants' unless ref($v) eq 'ARRAY' && @$v>=1 && @$v<=5;
    my (%requested,$budget);
    $budget=0;
    for my $c (@$v) {
        die 'invalid variant' unless ref($c) eq 'HASH' && _dim($c->{width}) && _dim($c->{height})
            && $c->{width}<=$p->{canvas_size} && $c->{height}<=$p->{canvas_size};
        my $k=$c->{width}.'x'.$c->{height};
        $budget+=3*$c->{width}*$c->{height} unless $requested{$k}++;
    }
    die 'variant budget exceeded' if $budget>RETAINED_LIMIT;
    my $bytes=$args{bytes};
    die 'expected encoded bytes' if defined($bytes) && (ref($bytes) || utf8::is_utf8($bytes));
    return _failure('empty_source') unless defined($bytes) && length($bytes);
    # Optional stricter caller policy; never permit relaxing defensive caps.
    my $limits = $args{source_limits} // {};
    die 'invalid source limits' unless ref($limits) eq 'HASH';
    my %caps = (bytes=>SOURCE_BYTES, axis=>SOURCE_DIM, pixels=>SOURCE_PIXELS);
    for my $key (keys %$limits) {
        die 'invalid source limit' unless exists($caps{$key})
            && _int($limits->{$key}) && $limits->{$key}>=1
            && $limits->{$key}<=$caps{$key};
        $caps{$key}=$limits->{$key};
    }
    return _failure('source_too_large') if length($bytes)>$caps{bytes};
    my $format=_format(\$bytes);
    return _failure('unsupported_format') unless $format;
    my $progressive=$format eq 'jpeg' && _progressive(\$bytes);
    # Caller MUST actually enforce process memory and time limits.
    # Do not enable in production before worker isolation is implemented.
    return _failure('native_memory_limit') if $progressive && !$args{bounded_worker_progressive};
    my $o=$format eq 'jpeg'?$orient->jpeg_orientation(\$bytes):1;
    my $im=_open_source(\$bytes);
    return _failure('corrupt_image') unless $im;
    my ($sw,$sh)=($im->width,$im->height);
    return _failure('corrupt_image') unless _int($sw) && _int($sh) && $sw && $sh;
    return _failure('source_dimensions_exceeded') if $sw>$caps{axis} || $sh>$caps{axis};
    return _failure('source_pixel_limit') if $sw*$sh>$caps{pixels};
    my ($ow,$oh)=$o>=5?($sh,$sw):($sw,$sh);
    my (%variants,%fitted);
    my $bg=pack('H6',$p->{background});
    # Floating-point GM produces visible high-contrast RGB and alpha
    # artifacts on the tested native Image::Scale 0.14 platform.
    # Use fixed-point GM consistently for all source formats.
    my $method='resize_gm_fixed_point';
    for my $c (@$v) {
        my ($cw,$ch)=@$c{qw(width height)};
        my $key=$cw.'x'.$ch;
        next if exists $variants{$key};
        my ($w,$h,$x,$y)=$rgb->fit($ow,$oh,$cw,$ch);
        my $fitkey=$w.'x'.$h;
        my $pixels=$fitted{$fitkey};
        unless ($pixels) {
            $im ||= _open_source(\$bytes);
            return _failure('corrupt_image') unless $im;
            my ($rw,$rh)=$o>=5?($h,$w):($w,$h);
            my %opts=(width=>$rw,height=>$rh,keep_aspect=>0,ignore_exif=>1);
            $opts{memory_limit}=NATIVE_LIMIT unless $progressive;
            my $r=_resize($im,$method,\%opts);
            return $r unless $r->{ok};
            my $normalized=$im->as_png();
            undef $im;
            die 'native PNG output missing' unless defined($normalized) && length($normalized);
            my ($buf,$nw,$nh)=$png->decode(\$normalized,$bg);
            die 'native resize dimensions mismatch' unless $nw==$rw && $nh==$rh;
            ($pixels,$nw,$nh)=$orient->transform($buf,$nw,$nh,$o);
            die 'oriented dimensions mismatch' unless $nw==$w && $nh==$h;
            $fitted{$fitkey}=$pixels;
        }
        $variants{$key}={rgb=>$pixels,width=>$w,height=>$h,x=>$x,y=>$y};
    }
    return {ok=>1,image=>{background=>$p->{background},variants=>\%variants}};
}
sub render {
    my ($class,%args)=@_;
    my $p=_profile($args{profile});
    my $images=$args{images};
    die 'invalid prepared images' unless ref($images) eq 'ARRAY' && @$images>=1 && @$images<=4;
    my $plan=$layout->plan(cover_count=>scalar(@$images),map {$_=>$p->{$_}} qw(canvas_size tile_gap incomplete_grid));
    my $cells=$args{layout};
    die 'invalid layout' unless ref($cells) eq 'ARRAY' && @$cells==@$plan;
    for my $i (0..$#$plan) {
        die 'invalid layout cell' unless ref($cells->[$i]) eq 'HASH';
        for my $k (qw(source_index x y width height)) {
            my ($a,$b)=($cells->[$i]{$k},$plan->[$i]{$k});
            die 'layout does not match profile' if defined($a)!=defined($b) || (defined($a) && (ref($a)||$a ne $b));
        }
    }
    my (%seen,$total);
    $total=0;
    for my $image (@$images) {
        die 'invalid prepared image' unless ref($image) eq 'HASH' && ($image->{background}//'') eq $p->{background}
            && ref($image->{variants}) eq 'HASH';
        for my $v (values %{$image->{variants}}) {
            die 'invalid prepared variant' unless ref($v) eq 'HASH' && _dim($v->{width}) && _dim($v->{height});
            my $buf=$v->{rgb};
            die 'invalid RGB buffer' unless ref($buf) eq 'SCALAR' && length($$buf)==3*$v->{width}*$v->{height};
            $total+=length($$buf) unless $seen{$buf}++;
            die 'retained RGB budget exceeded' if $total>RETAINED_LIMIT;
        }
    }
    my $size=$p->{canvas_size};
    my $canvas=$rgb->canvas($size,$size,pack('H6',$p->{background}));
    for my $c (@$plan) {
        next unless defined $c->{source_index};
        my $key=$c->{width}.'x'.$c->{height};
        my $v=$images->[$c->{source_index}]{variants}{$key};
        die 'missing prepared variant' unless $v;
        my ($w,$h)=@$v{qw(width height)};
        die 'prepared variant exceeds cell' if $w>$c->{width} || $h>$c->{height};
        my ($x,$y)=(int(($c->{width}-$w)/2),int(($c->{height}-$h)/2));
        die 'invalid prepared offsets' unless _int($v->{x}) && _int($v->{y}) && $v->{x}==$x && $v->{y}==$y;
        $rgb->blit($canvas,$size,$size,$v->{rgb},$w,$h,$c->{x}+$x,$c->{y}+$y);
    }
    my $encoded=$bmp->encode($canvas,$size,$size);
    undef $canvas;
    my $im=Image::Scale->new($encoded) or die 'native BMP constructor failed';
    my $r=_resize($im,'resize_gm',{width=>$size,height=>$size,keep_aspect=>0,memory_limit=>NATIVE_LIMIT});
    die 'native BMP conversion failed' unless $r->{ok};
    my $jpeg=$im->as_jpeg(92);
    undef $im;
    die 'invalid final JPEG' unless defined($jpeg) && length($jpeg)<=JPEG_LIMIT && substr($jpeg,0,2) eq "\xff\xd8"
        && substr($jpeg,-2) eq "\xff\xd9";
    my $verify=Image::Scale->new(\$jpeg) or die 'final JPEG header rejected';
    die 'final JPEG dimensions mismatch' unless $verify->width==$size && $verify->height==$size;
    return {ok=>1,bytes=>$jpeg,content_type=>'image/jpeg',width=>$size,height=>$size};
}
1;
