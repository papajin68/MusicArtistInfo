use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);

# Exercise real ranking, selection and layout, with native boundaries
# replaced by small in-memory stubs. No decoder or initialized LMS required.
BEGIN {
    for my $m (qw(AlbumCandidates ArtworkResolver Selection Layout)) {
        require "./Mosaicly/$m.pm";
        $INC{"Plugins/MusicArtistInfoMosaicly/Mosaicly/$m.pm"} = 1;
    }
    $INC{'Plugins/MusicArtistInfoMosaicly/Mosaicly/Compositor.pm'} = 1;
}
require './Mosaicly/Generator.pm';
my $g = 'Plugins::MusicArtistInfoMosaicly::Mosaicly::Generator';

my (@candidates, @retrieved, @prepared, @rendered);
my ($discover_error, $retrieve_error, $render_error);
sub candidate {
    my ($id,%extra) = @_;
    return {album_id=>$id,title=>sprintf('Album %03d',$id),
        year=>2000,artwork_id=>sprintf('%08x',$id),%extra};
}
{
    no warnings qw(redefine once);
    local *Plugins::MusicArtistInfoMosaicly::Mosaicly::Generator::_contained = sub {0};
    is($g->generate(contributor_id=>1)->{reason},
        'worker_containment_required','uncontained generation refused');
}
{
    no warnings qw(redefine once);
    local *Plugins::MusicArtistInfoMosaicly::Mosaicly::Generator::_contained = sub {1};
    local *Plugins::MusicArtistInfoMosaicly::Mosaicly::AlbumCandidates::discover = sub {
        my ($class,%a)=@_;
        return {ok=>0,reason=>$discover_error} if $discover_error;
        return {ok=>1,candidates=>\@candidates,diagnostics=>{test=>1}};
    };
    local *Plugins::MusicArtistInfoMosaicly::Mosaicly::ArtworkResolver::resolve = sub {
        my ($class,%a)=@_;
        push @retrieved,$a{album_id};
        return {ok=>0,reason=>$retrieve_error} if $retrieve_error;
        my $id=$a{album_id};
        return {ok=>1,%a,track_id=>$id,source_kind=>'external',
            content_type=>'image/jpeg',bytes=>"cover$id"};
    };
    local *Plugins::MusicArtistInfoMosaicly::Mosaicly::Compositor::variants_for_slot = sub {
        my ($class,%a)=@_;
        return [{width=>300,height=>300,slot=>$a{slot}}];
    };
    local *Plugins::MusicArtistInfoMosaicly::Mosaicly::Compositor::prepare = sub {
        my ($class,%a)=@_;
        push @prepared,\%a;
        return {ok=>0,reason=>'corrupt_image'} if $a{bytes} eq 'cover99';
        return {ok=>1,image=>$a{bytes}};
    };
    local *Plugins::MusicArtistInfoMosaicly::Mosaicly::Compositor::render = sub {
        my ($class,%a)=@_;
        push @rendered,\%a;
        die 'renderer failed' if $render_error;
        return {ok=>1,width=>600,height=>600,content_type=>'image/jpeg',bytes=>'jpeg'};
    };

    is($g->generate(contributor_id=>0)->{reason},'invalid_identity','bad identity');
    is($g->generate(contributor_id=>1,bounded_worker_progressive=>2)->{reason},
        'invalid_arguments','invalid authorization');
    for my $count (1..4) {
        @candidates=map {candidate($_)} reverse 1..$count;
        @retrieved=@prepared=@rendered=();
        my $r=$g->generate(contributor_id=>7);
        ok($r->{ok},"$count-cover orchestration");
        is($r->{contributor_id},7,'contributor identity');
        is_deeply([map {$_->{album_id}} @{$r->{sources}}],[1..$count],'ranked source identities');
        is_deeply($rendered[0]{images},[map {"cover$_"} 1..$count],'prepared images only');
        is(scalar @{$rendered[0]{layout}},$count==1?1:4,'layout geometry');
        is($r->{sources}[0]{sha256},sha256_hex('cover1'),'source digest preserved');
        ok(!exists($r->{sources}[0]{image}),'no prepared buffer in result metadata');
    }
    is_deeply($prepared[0]{source_limits},
        {bytes=>4194304,axis=>3000,pixels=>9000000},'approved limits passed');
    is($prepared[0]{bounded_worker_progressive},0,'default no progressive opt-in');
    @candidates=(candidate(99,year=>2025),candidate(1,artwork_id=>undef),candidate(2));
    my $r=$g->generate(contributor_id=>7,bounded_worker_progressive=>1);
    is_deeply([map {$_->{album_id}} @{$r->{sources}}],[2],'rejection and missing-art backfill');
    is($r->{diagnostics}{missing_artwork_count},1,'missing art counted');
    is($prepared[-1]{bounded_worker_progressive},1,'worker authorization passed');

    @candidates=map {candidate($_,artwork_id=>sprintf('%08x',$_))} 1..40;
    @retrieved=();
    $retrieve_error='source_unavailable';
    $r=$g->generate(contributor_id=>7);
    is($r->{reason},'no_usable_artwork','no render when all rejected');
    is(scalar @retrieved,32,'acquisition budget');
    is($r->{diagnostics}{candidate_budget_omitted},8,'budget omissions counted');
    $retrieve_error='artwork_changed';
    is($g->generate(contributor_id=>7)->{reason},'artwork_changed','stale retrieval fails closed');
    $retrieve_error=undef;
    $discover_error='contributor_not_found';
    is($g->generate(contributor_id=>7)->{reason},'contributor_not_found','discovery failure propagated');
    $discover_error=undef;
    # New server-to-worker boundary: describe metadata in the server,
    # then execute only the captured descriptors inside the worker.
    {
        my @described;
        local *Plugins::MusicArtistInfoMosaicly::Mosaicly::ArtworkResolver::describe = sub {
            my ($class,%a)=@_;
            push @described,$a{album_id};
            return {ok=>0,reason=>'source_unavailable'} if $a{album_id}==1;
            return {ok=>1,%a,track_id=>$a{album_id},source_kind=>'external',
                path=>"/music/$a{album_id}.jpg",file_identity=>[1,2,3,4,5]};
        };
        local *Plugins::MusicArtistInfoMosaicly::Mosaicly::ArtworkResolver::retrieve = sub {
            my ($class,$d)=@_;
            push @retrieved,$d->{album_id};
            return {ok=>1,(map {$_=>$d->{$_}} qw(album_id artwork_id track_id source_kind)),
                content_type=>'image/jpeg',bytes=>"cover$d->{album_id}"};
        };
        @candidates=map {candidate($_)} reverse 1..40;
        @retrieved=@prepared=@rendered=();
        my $job;
        {
            local *Plugins::MusicArtistInfoMosaicly::Mosaicly::Generator::_contained = sub {0};
            $job=$g->prepare_job(contributor_id=>7);
        }
        ok($job->{ok},'metadata preparation does not require worker limits');
        is_deeply(\@described,[1..32],'ranked descriptor budget');
        is(scalar @retrieved,0,'server preparation does not acquire art');
        is(scalar @prepared,0,'server preparation does not decode art');
        is($job->{diagnostics}{candidate_budget_omitted},8,'job records budget omissions');
        local *Plugins::MusicArtistInfoMosaicly::Mosaicly::AlbumCandidates::discover = sub {die 'worker must not discover'};
        local *Plugins::MusicArtistInfoMosaicly::Mosaicly::ArtworkResolver::resolve = sub {die 'worker must not resolve from DB'};
        my $result=$g->generate(contributor_id=>7,job=>$job);
        ok($result->{ok},'descriptor worker generation');
        is_deeply(\@retrieved,[2,3,4,5],'skip unavailable and stop after four');
        is_deeply([map {$_->{album_id}} @{$result->{sources}}],[2,3,4,5],
            'selected descriptors retain correct identity');
        is($g->generate(contributor_id=>8,job=>$job)->{reason},'invalid_job','wrong contributor rejected');
        my $wrong={%$job,entries=>[{%{$job->{entries}[1]},source=>{%{$job->{entries}[1]{source}},album_id=>99}}]};
        is($g->generate(contributor_id=>7,job=>$wrong)->{reason},'invalid_job','wrong source identity rejected');
        my $fatal={%$job,entries=>[{%{$job->{entries}[0]},source=>{ok=>0,reason=>'artwork_changed'}}]};
        is($g->generate(contributor_id=>7,job=>$fatal)->{reason},'artwork_changed','stale descriptor fails closed');
        my $oversized={%$job,entries=>[ @{$job->{entries}},$job->{entries}[0] ]};
        is($g->generate(contributor_id=>7,job=>$oversized)->{reason},'invalid_job','over-budget job rejected');
    }

    $render_error=1;
    is($g->generate(contributor_id=>7)->{reason},'generation_exception','render exception contained');
}
done_testing();
