use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use JSON::PP;
use Digest::SHA qw(sha256_hex);

require "$FindBin::Bin/../Mosaicly/Publisher.pm";
my $class='Plugins::MusicArtistInfo::Mosaicly::Publisher';

# Unit-test seams only; initialized Lyrion integration is separate.
{
    package PublisherTestDB;
    sub err { 0 }
    sub selectrow_hashref { +{%{$_[0]{row}}} }
    sub selectrow_array { $_[0]{collision} }
    sub do {
        my ($self,$sql,$attr,$url,$pid,$id,$name)=@_;
        die 'file missing before association' unless -f substr($url,7);
        return '0E0' if $self->{reject};
        @{$self->{row}}{qw(portrait portraitid)}=($url,$pid);
        return 1;
    }
    package Slim::Utils::Misc;
    sub fileURLFromPath { 'file://'.$_[0] }
    package Slim::Music::Artwork;
    sub generateImageId { 'abcd1234' }
}

my ($db,$current,$local,$sources);
{
    no warnings 'redefine';
    local *Plugins::MusicArtistInfo::Mosaicly::Publisher::_native=sub {$db};
    local *Plugins::MusicArtistInfo::Mosaicly::Publisher::_local=sub {$local};
    local *Plugins::MusicArtistInfo::Mosaicly::Publisher::_sources_current=sub {$sources};
    my $json=JSON::PP->new->canonical->utf8;
    my $job={ok=>1,contributor_id=>1,entries=>[],diagnostics=>{}};
    my $bytes="\xff\xd8test\xff\xd9";
    my $result={ok=>1,contributor_id=>1,job_sha256=>sha256_hex($json->encode($job)),
        jpeg_bytes=>length($bytes),jpeg_sha256=>sha256_hex($bytes),
        sources=>[{album_id=>2,artwork_id=>'12345678'}]};
    my $out={state=>'complete',ok=>1,process=>{state=>'exited',exit_code=>0},
        job=>$job,result=>$result,bytes=>$bytes};
    sub fixture {
        $db=bless {row=>{id=>1,name=>'Artist',portrait=>undef,portraitid=>undef},
            collision=>0},'PublisherTestDB';
        ($current,$local,$sources)=(1,0,1);
        my $root=abs_path(tempdir(CLEANUP=>1));
        return ($class->new(root=>$root,current=>sub {$current}),$root);
    }
    my ($p,$root)=fixture();
    my $identity=$p->identity(1);
    is_deeply($identity,{id=>1,name=>'Artist'},'capture identity');
    my $r=$p->publish(identity=>$identity,output=>$out);
    ok($r->{ok},'successful initial publication');
    is($db->{row}{portraitid},'abcd1234','native ID associated');
    my $file=substr($db->{row}{portrait},7);
    open my $fh,'<:raw',$file or die $!;
    is(do {local $/; <$fh>},$bytes,'published complete bytes');
    close $fh;
    ok(!-e "$root/.pending",'reservation cleared');
    is($p->publish(identity=>$identity,output=>$out)->{reason},'already_assigned','duplicate harmless');
    for my $case (qw(stale_job stale_artist local_artwork stale_sources invalid_result)) {
        ($p,$root)=fixture();
        $current=0 if $case eq 'stale_job';
        $db->{row}{name}='Changed' if $case eq 'stale_artist';
        $local=1 if $case eq 'local_artwork';
        $sources=0 if $case eq 'stale_sources';
        my %candidate=%$out;
        $candidate{bytes}='changed' if $case eq 'invalid_result';
        is($p->publish(identity=>$identity,output=>\%candidate)->{reason},$case,"reject $case");
        ok(!-e "$root/.pending","no reservation for $case");
        ok(!defined($db->{row}{portrait}),"no association for $case");
    }
    ($p,$root)=fixture();
    $db->{reject}=1;
    is($p->publish(identity=>$identity,output=>$out)->{reason},'association_changed','truthy zero rows rejected');
    ok(-f "$root/.pending",'failed association retains marker');
    my $fresh=$class->new(root=>$root,current=>sub {1});
    is($fresh->publish(identity=>$identity,output=>$out)->{reason},'publication_pending','restart blocks unresolved publication');
    ok(!defined($db->{row}{portrait}),'no association on zero rows');
    ($p,$root)=fixture();
    $db->{collision}=1;
    is($p->publish(identity=>$identity,output=>$out)->{reason},'portrait_id_collision','native ID collision rejected');
    ok(!defined($db->{row}{portrait}),'no collision association');
    ($p,$root)=fixture();
    my $path="$root/1-$result->{jpeg_sha256}.jpg";
    open my $bad,'>:raw',$path or die $!;
    print {$bad} 'existing';
    close $bad;
    is($p->publish(identity=>$identity,output=>$out)->{reason},'file_publication_failed','existing different bytes rejected');
    open $bad,'<:raw',$path or die $!;
    is(do {local $/; <$bad>},'existing','no clobber');
    close $bad;
    ($p,$root)=fixture();
    $path="$root/1-$result->{jpeg_sha256}.jpg";
    open my $same,'>:raw',$path or die $!;
    print {$same} $bytes;
    close $same;
    ok($p->publish(identity=>$identity,output=>$out)->{ok},'complete identical orphan reusable');
}
done_testing;
