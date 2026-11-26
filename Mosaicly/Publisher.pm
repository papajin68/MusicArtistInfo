package Plugins::MusicArtistInfo::Mosaicly::Publisher;

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Temp qw(tempfile);
use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK O_WRONLY O_CREAT O_EXCL);
use Digest::SHA qw(sha256_hex);
use JSON::PP;

my $json = JSON::PP->new->canonical->utf8;
sub _fail { +{ok=>0,reason=>$_[0]} }

# The initialized caller supplies a lifecycle guard tied to the preparation
# epoch. It must reject intervening scans and disabled source modes.
sub new {
    my ($class,%a)=@_;
    my $root=$a{root};
    die 'invalid portrait directory' unless defined($root) && !ref($root)
        && -d $root && !-l $root && abs_path($root) eq $root;
    my @st=stat($root);
    die 'invalid portrait directory permissions' unless $st[4]==$>
        && ($st[2]&0777)==0700;
    die 'missing lifecycle guard' unless ref($a{current}) eq 'CODE';
    return bless {root=>$root,current=>$a{current}},$class;
}

sub _native {
    require Slim::Schema;
    require Slim::Music::Artwork;
    require Slim::Utils::Misc;
    require Slim::Utils::Unicode;
    require Plugins::MusicArtistInfo::LocalArtwork;
    require Plugins::MusicArtistInfo::Mosaicly::AlbumCandidates;
    require Plugins::MusicArtistInfo::Mosaicly::ArtworkResolver;
    return Slim::Schema->dbh;
}

sub _artist {
    my ($dbh,$id)=@_;
    my $row=$dbh->selectrow_hashref(
        'SELECT id,name,portrait,portraitid FROM contributors WHERE id=?',
        undef,$id);
    die 'artist query failed' if $dbh->err;
    return $row;
}

# Capture exact committed name before generation, without artwork reads.
sub identity {
    my ($self,$id)=@_;
    return unless defined($id) && !ref($id) && $id =~ /\A[1-9][0-9]*\z/;
    my $row=_artist(_native(),$id);
    return unless $row && defined($row->{name})
        && !defined($row->{portrait}) && !defined($row->{portraitid});
    return {id=>$id,name=>$row->{name}};
}

sub _local {
    my ($id,$name)=@_;
    return Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
        artist_id=>$id,artist=>Slim::Utils::Unicode::utf8decode($name),
        rawUrl=>1,force=>1});
}

sub _sources_current {
    my ($id,$job,$result)=@_;
    my $d=Plugins::MusicArtistInfo::Mosaicly::AlbumCandidates->discover(
        contributor_id=>$id);
    return unless $d->{ok};
    my %live=map {$_->{album_id}=>$_->{artwork_id}} @{$d->{candidates}};
    my %old=map {$_->{candidate}{album_id}=>$_->{source}} @{$job->{entries}};
    for my $s (@{$result->{sources}}) {
        my $album=$s->{album_id};
        return unless defined($live{$album}) && $live{$album} eq $s->{artwork_id};
        my $fresh=Plugins::MusicArtistInfo::Mosaicly::ArtworkResolver->describe(
            album_id=>$album,artwork_id=>$s->{artwork_id});
        return unless $fresh->{ok} && $old{$album}
            && $json->encode($fresh) eq $json->encode($old{$album});
    }
    return 1;
}

sub _matches {
    my ($path,$bytes)=@_;
    sysopen my $fh,$path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK or return;
    binmode $fh or return;
    my @st=stat($fh);
    return unless @st && -f _ && $st[4]==$> && $st[7]==length($bytes);
    my $actual='';
    while (length($actual)<=length($bytes)) {
        my $n=read($fh,my $chunk,8192);
        return unless defined $n;
        last unless $n;
        $actual.=$chunk;
    }
    close $fh or return;
    return $actual eq $bytes;
}

# Same-directory temporary file, followed by an atomic no-clobber hard link.
# A deterministic filename permits safe reuse of a complete orphan.
sub _publish_file {
    my ($root,$path,$bytes)=@_;
    return _matches($path,$bytes) if -e $path || -l $path;
    my ($fh,$tmp)=tempfile('.publish-XXXXXXXX',DIR=>$root,UNLINK=>0);
    my $ok=eval {
        binmode $fh or die 'binmode';
        print {$fh} $bytes or die 'write';
        close $fh or die 'close';
        link($tmp,$path) || _matches($path,$bytes) or die 'publish';
        1;
    };
    close $fh if defined fileno($fh);
    unlink $tmp or return;
    return $ok;
}

sub publish {
    my ($self,%a)=@_;
    my $r=eval { $self->_publish(%a) };
    return _fail('publication_exception') if $@ || !defined($r);
    return $r;
}

sub _publish {
    my ($self,%a)=@_;
    my ($identity,$out)=@a{qw(identity output)};
    return _fail('invalid_result') unless ref($identity) eq 'HASH'
        && defined($identity->{id}) && $identity->{id}=~/\A[1-9][0-9]*\z/
        && defined($identity->{name}) && ref($out) eq 'HASH'
        && $out->{ok} && ($out->{state}//'') eq 'complete'
        && ($out->{process}{state}//'') eq 'exited'
        && defined($out->{process}{exit_code}) && $out->{process}{exit_code}==0;
    my ($id,$name)=@$identity{qw(id name)};
    my ($job,$result,$bytes)=@$out{qw(job result bytes)};
    return _fail('invalid_result') unless ref($job) eq 'HASH'
        && ref($result) eq 'HASH' && $result->{ok}
        && ($job->{contributor_id}//'') eq $id
        && ($result->{contributor_id}//'') eq $id
        && ($result->{job_sha256}//'') eq sha256_hex($json->encode($job))
        && ref($result->{sources}) eq 'ARRAY'
        && @{$result->{sources}}>=1 && @{$result->{sources}}<=4
        && defined($bytes) && !ref($bytes) && !utf8::is_utf8($bytes)
        && length($bytes)<=8*1024*1024
        && length($bytes)==($result->{jpeg_bytes}//0)
        && sha256_hex($bytes) eq ($result->{jpeg_sha256}//'')
        && substr($bytes,0,2) eq "\xff\xd8" && substr($bytes,-2) eq "\xff\xd9";
    return _fail('stale_job') unless $self->{current}->();
    my $dbh=_native();
    my $row=_artist($dbh,$id);
    return _fail('stale_artist') unless $row && defined($row->{name}) && $row->{name} eq $name;
    my $path="$self->{root}/$id-$result->{jpeg_sha256}.jpg";
    my $url=Slim::Utils::Misc::fileURLFromPath($path);
    # Duplicate invocation is harmless; do not alter existing associations.
    if (defined($row->{portrait}) || defined($row->{portraitid})) {
        return _fail('already_assigned');
    }
    return _fail('publication_pending') if -e "$self->{root}/.pending" || -l "$self->{root}/.pending";
    return _fail('local_artwork') if _local($id,$name);
    return _fail('stale_sources') unless _sources_current($id,$job,$result);
    return _fail('stale_job') unless $self->{current}->();
    # Retain a fail-closed reservation if publication or registration is ambiguous.
    # Persistent single reservation: a crash cannot allow repeated orphan creation.
    sysopen my $reservation,"$self->{root}/.pending",O_WRONLY|O_CREAT|O_EXCL,0600
        or return _fail('publication_pending');
    print {$reservation} "$id $result->{jpeg_sha256}\n" or die 'reservation write';
    close $reservation or die 'reservation close';
    return _fail('file_publication_failed') unless _publish_file($self->{root},$path,$bytes);
    my $portraitid=Slim::Music::Artwork->generateImageId($url);
    return _fail('invalid_portrait_id') unless defined($portraitid)
        && $portraitid =~ /\A[0-9a-f]{8}\z/;
    # Never bind an ID already used for a different URL.
    my ($collision)=$dbh->selectrow_array(
        'SELECT COUNT(*) FROM contributors WHERE portraitid=? AND (portrait IS NULL OR portrait<>?)',
        undef,$portraitid,$url);
    die 'collision query failed' if $dbh->err || !defined($collision);
    return _fail('portrait_id_collision') if $collision;
    return _fail('stale_job') unless $self->{current}->();
    my $n=$dbh->do(
        'UPDATE contributors SET portrait=?,portraitid=? WHERE id=? AND name=? AND portrait IS NULL AND portraitid IS NULL',
        undef,$url,$portraitid,$id,$name);
    die 'registration failed' unless defined($n) && !$dbh->err;
    return _fail('association_changed') unless $n==1;
    unlink "$self->{root}/.pending" or return _fail('reservation_cleanup_failed');
    return {ok=>1,contributor_id=>$id,portrait=>$url,portraitid=>$portraitid};
}

1;
