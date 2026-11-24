use strict;
use warnings;
use Test::More;
require './Mosaicly/Orientation.pm';
my $c = 'Plugins::MusicArtistInfo::Mosaicly::Orientation';

sub app1 {
    my ($payload) = @_;
    return "\xff\xe1" . pack('n', length($payload)+2) . $payload;
}
sub exif {
    my ($order, @values) = @_;
    my ($s,$l) = $order eq 'II' ? ('v','V') : ('n','N');
    return "Exif\0\0".$order.pack($s,42).pack($l,8)
        .pack($s,scalar @values)
        .join('',map {pack($s,0x112).pack($s,3).pack($l,1).pack($s,$_)."\0\0"} @values)
        .pack($l,0);
}
sub orient {
    my $jpeg = "\xff\xd8".join('', @_)."\xff\xd9";
    return $c->jpeg_orientation(\$jpeg);
}
for my $order ('II','MM') {
    for my $o (1..8) {
        is(orient(app1(exif($order,$o))),$o,"$order orientation $o");
    }
}
is(orient(),1,'missing EXIF');
is(orient(app1('unrelated APP1'), app1(exif('MM',6))),6,'skip unrelated APP1');
is(orient(app1(exif('II',6,6))),6,'consistent repeated tag');
is(orient(app1(exif('II',6,8))),1,'conflicting tags');
is(orient(app1(exif('II',6)),app1(exif('MM',8))),1,'conflicting APP1');
is(orient(app1(exif('II',6)),app1(exif('MM',6))),6,'consistent APP1');
for my $o (0,9,65535) {is(orient(app1(exif('II',$o))),1,"invalid value $o")}
my $good = exif('II',6);
for my $n (6..length($good)-1) {
    is(orient(app1(substr($good,0,$n))),1,"truncated EXIF $n");
}
for my $off (0,7,0xffffffff) {
    my $bad=$good; substr($bad,10,4)=pack('V',$off);
    is(orient(app1($bad)),1,"invalid IFD offset $off");
}
for my $pair ([16,pack('v',4)],[18,pack('V',2)],[14,pack('v',65535)]) {
    my $bad=$good;
    # TIFF count at payload offset 14, entry type at 18, count at 20.
    my $offset=$pair->[0]==16 ? 18 : $pair->[0]==18 ? 20 : 14;
    substr($bad,$offset,length($pair->[1]))=$pair->[1];
    is(orient(app1($bad)),1,"invalid IFD field $offset");
}
is(orient("\xff\xe1\xff\xff"),1,'invalid segment length');
is(orient("\xff\xda".app1(exif('II',6))),1,'stop before entropy data');
my $non='not JPEG'; is($c->jpeg_orientation(\$non),1,'non JPEG');

# Each pixel has three different channels. 3x2 asymmetric source:
# A B C
# D E F
my %expected=(1=>'ABCDEF',2=>'CBAFED',3=>'FEDCBA',4=>'DEFABC',
              5=>'ADBECF',6=>'DAEBFC',7=>'FCEBDA',8=>'CFBEAD');
my %pixel=map {$_=>pack('C3',ord($_),ord($_)+1,ord($_)+2)} 'A'..'F';
my $rgb=join('',@pixel{'A'..'F'});
for my $o (1..8) {
    my ($out,$w,$h)=$c->transform(\$rgb,3,2,$o);
    is($$out,join('',map {$pixel{$_}} split //,$expected{$o}),"exact pixels $o");
    is_deeply([$w,$h],$o>=5?[2,3]:[3,2],"dimensions $o");
    is($rgb,join('',@pixel{'A'..'F'}),"source unchanged $o");
    is($out,\$rgb,'identity reuses buffer') if $o==1;
}
for my $o (0,9,undef) {
    eval {$c->transform(\$rgb,3,2,$o)};
    like($@,qr/invalid orientation/,'reject invalid transform orientation');
}
eval {$c->transform(\$rgb,2,2,1)};
like($@,qr/invalid RGB buffer/,'reject mismatched buffer');
eval {$c->transform(\$rgb,1025,2,1)};
like($@,qr/invalid RGB dimensions/,'reject oversized variant');
done_testing();
