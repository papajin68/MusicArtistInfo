package Plugins::MusicArtistInfoMosaicly::Mosaicly::Runtime;
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);
use Errno qw(ENOENT);

# Do not silently select a fresh root when an old reservation exists.
# The temporary location is stable for a given cache and effective UID.
sub _private_dir {
    my ($path) = @_;
    if (!-e $path && !-l $path) {
        mkdir($path,0700) or die 'create runtime directory';
        chmod(0700,$path) or die 'runtime directory chmod';
    }
    my @st=lstat($path);
    die 'unsafe runtime directory' unless @st && -d _ && !-l _
        && $st[4]==$> && ($st[2]&07777)==0700
        && abs_path($path) eq $path;
    return $path;
}

# Persistent ownership is independent of the transient workspace and source
# preference. Any existing entry, including a symlink, blocks admission.
sub ownershipPath {
    my ($class,$cache)=@_;
    die 'ownership parent unavailable' unless defined($cache) && !ref($cache) && length($cache);
    my $root=abs_path($cache);
    die 'ownership parent unavailable' unless $root && -d $root;
    return File::Spec->catdir($root,'.mai_mosaicly_worker_active');
}

sub ownershipClear {
    my ($class,$path)=@_;
    return 0 unless defined($path) && !ref($path);
    my ($parent)= $path =~ m{\A(.+)/\.mai_mosaicly_worker_active\z};
    return 0 unless defined($parent) && -d $parent && abs_path($parent) eq $parent;
    local $!;
    my @st=lstat($path);
    return !@st && $! == ENOENT ? 1 : 0;
}

sub paths {
    my ($class,%a)=@_;
    my $cache=abs_path($a{cache} // '');
    my $tmp=abs_path($a{temporary} // File::Spec->tmpdir);
    die 'runtime parent unavailable' unless $cache && -d $cache && $tmp && -d $tmp;
    my $jobs=_private_dir(File::Spec->catdir($tmp,
        'mai-mosaicly-'.$>.'-'.sha256_hex($cache)));
    my $portraits=_private_dir(File::Spec->catdir($cache,'mai_mosaicly_portraits'));
    die 'runtime roots overlap' if $jobs eq $portraits;
    # Verify the actual transient filesystem's required mode, not its vendor.
    my ($fh,$probe)=tempfile('.mode-XXXXXXXX',DIR=>$jobs,UNLINK=>0);
    my $ok=eval {
        chmod(0600,$probe) or die 'worker file chmod';
        my @st=stat($fh);
        die 'worker file permissions' unless @st && -f _
            && $st[4]==$> && ($st[2]&07777)==0600;
        1;
    };
    my $closed=close($fh);
    my $removed=unlink($probe);
    die 'transient storage incompatible' unless $ok && $closed && $removed;
    return {jobs=>$jobs,portraits=>$portraits,ownership=>$class->ownershipPath($cache)};
}

1;
