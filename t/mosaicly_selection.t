use strict;
use warnings;
use utf8;
use Test::More;
use Digest::SHA qw(sha256_hex);
require './Mosaicly/Selection.pm';
my $s = 'Plugins::MusicArtistInfo::Mosaicly::Selection';
sub candidate {
    my ($id, %extra) = @_;
    return { album_id => $id, title => "Album $id", year => 2000,
        play_count => undef, artwork_id => sprintf('%08x',$id), %extra };
}
sub retrieve {
    my %a = @_;
    return { ok => 1, %a, track_id => $a{album_id}, source_kind => 'external',
        content_type => 'image/png', bytes => "bytes$a{album_id}" };
}
sub prepare { my %a = @_; return { ok => 1, image => "prepared:$a{slot}" }; }
sub run {
    my ($c, %extra) = @_;
    return $s->select(candidates => $c, retrieve => \&retrieve, prepare => \&prepare, %extra);
}
sub ids { [map { $_->{album_id} } @{$_[0]}] }
is_deeply(ids($s->rank([
    candidate(1,year=>0),candidate(2,year=>2020,play_count=>0),
    candidate(3,year=>2020,play_count=>3),candidate(4,year=>undef),
    candidate(5,year=>2021),candidate(6,year=>2020,title=>'AAA')
])),[5,3,6,2,1,4],'year, plays, title, missing year');
is_deeply(ids($s->rank([candidate(10,title=>'Straße'),candidate(2,title=>'STRASSE')])),
    [2,10],'Unicode casefold and numeric tie');
is_deeply(ids($s->rank([candidate(2),candidate(2)])),[2],'duplicate album collapsed');
eval { $s->rank([candidate(2),candidate(2,title=>'different')]) };
like($@,qr/conflicting/,'conflicting album metadata rejected');
my @calls;
my $r = run([map { candidate($_) } 1..6], retrieve => sub {
    my %a = @_; push @calls,$a{album_id}; return retrieve(@_);
});
ok($r->{ok},'success');
is_deeply(ids($r->{selected}),[1,2,3,4],'four ranked covers');
is_deeply(\@calls,[1,2,3,4],'early stop');
is($r->{selected}[0]{sha256},sha256_hex('bytes1'),'original digest');
ok(!exists($r->{selected}[0]{bytes}),'original bytes not retained');
is($r->{selected}[3]{image},'prepared:3','accepted slot passed');
$r = run([candidate(1,artwork_id=>undef),candidate(2)]);
is($r->{diagnostics}{attempted_count},1,'missing art no retrieval');
is($r->{diagnostics}{skipped}[0]{reason},'no_selected_artwork','missing art diagnostic');
$r = run([map { candidate($_) } 1..5],retrieve=>sub {
    my $v=retrieve(@_); $v->{bytes}='same' if $v->{album_id} <= 2; $v
});
is_deeply(ids($r->{selected}),[1,3,4,5],'duplicate digest backfill');
is($r->{diagnostics}{skipped}[0]{reason},'duplicate_content','duplicate reason');
$r = run([candidate(1),candidate(2,artwork_id=>'00000001')]);
is($r->{reason},'artwork_identity_conflict','same ID differing bytes fatal');
ok(!exists($r->{selected}),'fatal excludes prepared output');
$r = run([candidate(1),candidate(2,artwork_id=>'00000001')],
    prepare=>sub {{ok=>0,reason=>'corrupt_image'}});
is($r->{reason},'artwork_identity_conflict','observed rejected source identity tracked');
$r = run([candidate(1),candidate(2,artwork_id=>'00000001')],retrieve=>sub {
    my $v=retrieve(@_); $v->{bytes}='same'; $v
});
is(scalar @{$r->{selected}},1,'same ID same bytes duplicate');
for my $reason (qw(no_recorded_source unsupported_source source_unavailable)) {
    $r=run([candidate(1),candidate(2)],retrieve=>sub {
        my %a=@_; return {ok=>0,reason=>$reason} if $a{album_id}==1; retrieve(@_)
    });
    is_deeply(ids($r->{selected}),[2],"$reason backfill");
}
for my $reason (qw(invalid_identity album_not_found no_selected_artwork artwork_changed no_matching_track source_mismatch native_error)) {
    $r=run([candidate(1)],retrieve=>sub {{ok=>0,reason=>$reason}});
    is($r->{reason},$reason,"$reason fatal");
}
for my $reason (qw(empty_source unsupported_format corrupt_image source_too_large source_dimensions_exceeded source_pixel_limit native_memory_limit)) {
    $r=run([candidate(1)],prepare=>sub {{ok=>0,reason=>$reason}});
    ok($r->{ok} && !@{$r->{selected}},"$reason skip");
}
$r=run([candidate(1)],prepare=>sub {{ok=>0,reason=>'unexpected'}});
is($r->{reason},'prepare_failed','unknown prep failure fatal');
$r=run([candidate(1)],retrieve=>sub {{ok=>0,reason=>'unexpected'}});
is($r->{reason},'unknown_retrieve_failure','unknown resolver failure fatal');
$r=run([candidate(1)],retrieve=>sub {die 'backend'});
is($r->{reason},'retrieve_exception','resolver exception');
$r=run([candidate(1)],prepare=>sub {die 'backend'});
is($r->{reason},'prepare_exception','prep exception');
$r=run([candidate(1)],retrieve=>sub {my $v=retrieve(@_); $v->{album_id}=2; $v});
is($r->{reason},'invalid_retrieve_result','callback identity verified');
$r=run([candidate(1)],prepare=>sub {{ok=>1}});
is($r->{reason},'invalid_prepare_result','missing prepared data');
$r=run([candidate(1)],retrieve=>sub {undef});
is($r->{reason},'invalid_retrieve_result','undefined callback result');
$r=run([]);
ok($r->{ok} && !@{$r->{selected}},'empty candidate set');
$r=run([candidate(1)],max_covers=>0);
is($r->{reason},'invalid_arguments','invalid max');
$r=run([candidate(1,play_count=>'NaN')]);
is($r->{reason},'invalid_candidates','invalid statistics');
$r=run([map {candidate($_,artwork_id=>undef)} 1..120]);
is($r->{diagnostics}{skipped_count},120,'full skip count');
is(scalar @{$r->{diagnostics}{skipped}},100,'bounded detailed diagnostics');
done_testing();
