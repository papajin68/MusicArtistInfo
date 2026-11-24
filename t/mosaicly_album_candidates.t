use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Encode qw(encode);
require './Mosaicly/AlbumCandidates.pm';
require './Mosaicly/Selection.pm';
my $class = 'Plugins::MusicArtistInfo::Mosaicly::AlbumCandidates';
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
    { RaiseError => 1, PrintError => 0 });
$dbh->do("ATTACH DATABASE ':memory:' AS persistentdb");
for my $sql (
    'CREATE TABLE contributors (id INTEGER PRIMARY KEY, namesearch TEXT)',
    'CREATE TABLE albums (id INTEGER PRIMARY KEY, title BLOB, year INTEGER, artwork TEXT, contributor INTEGER, compilation INTEGER)',
    'CREATE TABLE contributor_album (role INTEGER, contributor INTEGER, album INTEGER, PRIMARY KEY(role,contributor,album))',
    'CREATE TABLE tracks (id INTEGER PRIMARY KEY, album INTEGER, audio INTEGER, content_type TEXT, urlmd5 TEXT)',
    'CREATE TABLE persistentdb.tracks_persistent (id INTEGER PRIMARY KEY, urlmd5 TEXT, playCount INTEGER)',
) { $dbh->do($sql); }
for my $id (1..4) { $dbh->do('INSERT INTO contributors VALUES (?,?)',undef,$id,"name$id"); }
for my $a (
    [10,encode('UTF-8','Straße'),2020,'00000010',1,0],
    [11,'Second',0,undef,1,0],
    [12,'Compilation',2019,'00000012',4,1],
    [13,'Custom role',2022,'00000013',2,0],
    [14,'Album as artist',2023,'00000014',3,0],
    [15,'Remote art',2024,'https://example.invalid/art',1,0],
    [16,'No primary contributor',2025,'00000016',99,0],
    [17,'No tracks',2026,'00000017',1,0],
) { $dbh->do('INSERT INTO albums VALUES (?,?,?,?,?,?)',undef,@$a); }
for my $r ([1,1,10],[5,1,10],[6,1,11],[2,1,12],[21,1,13],[5,3,14],[1,1,15],[1,1,16],[1,1,17]) {
    $dbh->do('INSERT INTO contributor_album VALUES (?,?,?)',undef,@$r);
}
for my $t ([1,10,1,'flc','a'],[2,10,1,'flc','b'],[3,10,1,'flc','c'],
           [4,10,1,'flc','d'],[5,10,1,'flc','e'],[6,10,0,'flc','f'],
           [7,10,1,'dir','g'],[8,11,1,'flc','h'],[9,10,1,'cpl','i'],
           [10,10,1,'src','j'],[11,10,1,'ssp','k'],[12,10,1,undef,'l']) {
    $dbh->do('INSERT INTO tracks VALUES (?,?,?,?,?)',undef,@$t);
}
for my $p ([1,'a',12],[2,'b',8],[3,'c',undef],[4,'d',0],[5,'f',999],
           [6,'g',999],[7,'h',0],[8,'i',999],[9,'j',999],[10,'k',999],[11,'l',999]) {
    $dbh->do('INSERT INTO persistentdb.tracks_persistent VALUES (?,?,?)',undef,@$p);
}
sub discover {
    my ($id,%extra)=@_;
    return $class->discover(contributor_id=>$id,context=>sub {
        {dbh=>$dbh,roles=>[1,2,5,6,21],va_id=>4,statistics=>1,%extra}
    });
}
sub ids { [map {$_->{album_id}} @{$_[0]{candidates}}] }
my $r=discover(1);
ok($r->{ok},'discovery success');
is_deeply(ids($r),[10,11,12,13,15,17],'native roles, distinct albums, primary contributor join');
my $a=$r->{candidates}[0];
is($a->{title},'Straße','UTF-8 title decoded');
is($a->{track_count},5,'native track eligibility, no role multiplication');
is($a->{play_count},4,'zero-filled average');
is_deeply($a->{statistics},{enabled=>1,missing_rows=>1,null_counts=>1,zero_counts=>1,positive_counts=>2},'statistics diagnostics');
is($r->{candidates}[1]{year},undef,'unknown year');
is($r->{candidates}[1]{artwork_id},undef,'missing artwork retained');
is($r->{candidates}[1]{play_count},undef,'all-zero mean unknown');
is($r->{candidates}[4]{artwork_id},undef,'remote artwork not local');
is($r->{diagnostics}{unsupported_artwork},1,'remote count');
is($r->{candidates}[5]{track_count},0,'album without eligible tracks retained');
is_deeply(ids(discover(1,roles=>[1,5,6])),[10,11,15,17],'unified role subset');
is_deeply(ids(discover(1,roles=>[21])),[13],'custom role');
is_deeply(ids(discover(4)),[12],'VA compilation without relationship');
is_deeply(ids(discover(3)),[14],'album-as-artist ordinary relationship');
is_deeply(ids(discover(2)),[],'existing contributor without albums');
is(discover(99)->{reason},'contributor_not_found','unknown contributor');
is(discover(0)->{reason},'invalid_identity','invalid ID');
my $rank='Plugins::MusicArtistInfo::Mosaicly::Selection'->rank($r->{candidates});
is($rank->[0]{album_id},17,'selection contract compatible');
$dbh->do("INSERT INTO persistentdb.tracks_persistent VALUES (20,'a',100)");
is(discover(1)->{reason},'ambiguous_statistics','duplicate persistent match fatal');
ok(discover(3)->{ok},'unrelated duplicate does not fail other contributor');
$r=discover(1,statistics=>0);
ok($r->{ok},'disabled statistics ignores duplicate');
is($r->{candidates}[0]{track_count},5,'disabled stats retains track count');
is($r->{candidates}[0]{play_count},undef,'disabled stats unknown');
$dbh->do('DELETE FROM persistentdb.tracks_persistent WHERE id=20');
$dbh->do("UPDATE persistentdb.tracks_persistent SET playCount=-1 WHERE id=1");
is(discover(1)->{reason},'invalid_statistics','negative stats fail');
$dbh->do("UPDATE persistentdb.tracks_persistent SET playCount=12 WHERE id=1");
$dbh->do('DROP TABLE persistentdb.tracks_persistent');
is(discover(1)->{reason},'native_error','enabled missing stats table fatal');
ok(discover(1,statistics=>0)->{ok},'disabled stats needs no table');
$dbh->do('DROP TABLE albums');
is(discover(1,statistics=>0)->{reason},'native_error','DB failure fatal');
done_testing();
