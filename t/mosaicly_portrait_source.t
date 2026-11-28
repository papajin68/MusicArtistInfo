use strict;
use warnings;
use Test::More;
require './PortraitSource.pm';
{
    package TestPrefs;
    sub new { my ($class, %values) = @_; bless {values=>\%values, writes=>0}, $class }
    sub get { $_[0]{values}{$_[1]} }
    sub set { $_[0]{values}{$_[1]}=$_[2]; ++$_[0]{writes} }
}
for my $case (
    [{}, 'online'],
    [{lookupArtistPictures=>1}, 'online'],
    [{lookupArtistPictures=>0}, 'none'],
    [{lookupArtistPictures=>''}, 'none'],
    [{artistPortraitSource=>'online',lookupArtistPictures=>0}, 'online'],
    [{artistPortraitSource=>'mosaicly',lookupArtistPictures=>1}, 'mosaicly'],
    [{artistPortraitSource=>'none',lookupArtistPictures=>1}, 'none'],
    [{artistPortraitSource=>'invalid',lookupArtistPictures=>1}, 'none'],
    [{artistPortraitSource=>'',lookupArtistPictures=>1}, 'none'],
) {
    my ($values,$expected)=@$case;
    my $prefs=TestPrefs->new(%$values);
    is(Plugins::MusicArtistInfo::PortraitSource::source($prefs),$expected,'read policy');
    is($prefs->{writes},0,'read-only scanner policy');
    is(!!Plugins::MusicArtistInfo::PortraitSource::onlineEnabled($prefs),!!($expected eq 'online'),'online gate');
    is(Plugins::MusicArtistInfo::PortraitSource::initSource($prefs),$expected,'migration');
    is($prefs->get('artistPortraitSource'),$expected,'stored authoritative mode');
    my $writes=$prefs->{writes};
    Plugins::MusicArtistInfo::PortraitSource::initSource($prefs);
    is($prefs->{writes},$writes,'idempotent migration');
    is($prefs->get('lookupArtistPictures'),$values->{lookupArtistPictures},'legacy value untouched');
}
for my $v ('online','mosaicly','none') {
    ok(Plugins::MusicArtistInfo::PortraitSource::validSource($v),'valid mode');
}
for my $v (undef,'','ONLINE','0',[],{}, "online\n") {
    ok(!Plugins::MusicArtistInfo::PortraitSource::validSource($v),'invalid mode rejected');
}
# Pure registration predicate: the real scanner uses this after local folder registration.
for my $case (
    ['mosaicly',1,1,{}, {},1,0],
    ['mosaicly',1,0,{}, {},0,0],
    ['mosaicly',0,1,{}, {},0,0],
    ['none',1,1,{}, {},0,0],
    ['invalid',1,1,{}, {},0,0],
    ['online',1,1,{}, {},1,1],
    ['none',1,1,{lookupCoverArt=>1}, {},1,1],
    ['none',1,1,{replaceOnlineGenres=>1}, {},1,1],
    ['none',1,1,{}, {precacheArtwork=>1},1,1],
    ['mosaicly',1,1,{lookupCoverArt=>1}, {},1,1],
    ['online',0,1,{}, {},0,1],
) {
    my ($mode,$run,$native,$extra,$server,$required,$work)=@$case;
    my $prefs=TestPrefs->new(artistPortraitSource=>$mode,runImporter=>$run,%$extra);
    my $serverprefs=TestPrefs->new(%$server);
    is(!!Plugins::MusicArtistInfo::PortraitSource::importerRequired($prefs,$serverprefs,$native),
        !!$required,"importer registration $mode/$run/$native");
    is(!!Plugins::MusicArtistInfo::PortraitSource::legacyImporterWork($prefs,$serverprefs),
        !!$work,"legacy work $mode/$run/$native");
}
done_testing;
