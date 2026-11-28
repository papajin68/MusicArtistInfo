package Plugins::MusicArtistInfo::Mosaicly::Resource;
use strict;
use warnings;
use Errno qw(ENOENT);

# Provisional Linux MVP admission: retain two worker address-space budgets
# in host available memory and under every visible cgroup-v2 memory limit.
# This is a pressure heuristic, not a memory reservation or an OOM guarantee.
use constant HEADROOM => 512*1024*1024;
sub _deny { +{ok=>0,reason=>$_[0]} }

sub _read {
    my ($path)=@_;
    open my $fh,'<',$path or return;
    my $bytes='';
    my $cap=$path eq '/proc/self/mountinfo' ? 262144 : 16384;
    while (length($bytes)<=$cap) {
        my $n=read($fh,my $chunk,4096);
        return unless defined $n;
        last unless $n;
        $bytes.=$chunk;
    }
    return unless close($fh) && length($bytes)<=$cap;
    return $bytes;
}
sub _absent {
    local $!;
    my @st=lstat($_[0]);
    return !@st && $! == ENOENT;
}
sub _uint {
    my ($v)=@_;
    return unless defined($v) && $v =~ /\A\s*([0-9]{1,19})\s*\z/;
    return 0+$1;
}
sub _limit {
    my ($v)=@_;
    return 'max' if defined($v) && $v =~ /\A\s*max\s*\z/;
    return _uint($v);
}
sub _pressure {
    my ($v)=@_;
    return unless defined $v;
    my ($some)=$v =~ /^some avg10=([0-9]+(?:\.[0-9]+)?)\s/m;
    my ($full)=$v =~ /^full avg10=([0-9]+(?:\.[0-9]+)?)\s/m;
    return unless defined($some) && defined($full);
    return $some<1 && $full==0 ? 1 : 0;
}
sub _safe_path {
    my ($p)=@_;
    return defined($p) && $p =~ m{\A/(?:[A-Za-z0-9_.@:-]+(?:/[A-Za-z0-9_.@:-]+)*)?\z}
        && $p !~ m{(?:\A|/)\.{1,2}(?:/|\z)};
}

sub check {
    my ($class,%a)=@_;
    return _deny('unsupported_platform') unless $^O eq 'linux' || $a{read};
    my $read=$a{read} || \&_read;
    my $absent=$a{absent} || \&_absent;
    my $mem=$read->('/proc/meminfo');
    my ($available)=defined($mem) ? $mem =~ /^MemAvailable:\s+([0-9]{1,12})\s+kB\s*$/m : ();
    return _deny('host_memory_unknown') unless defined $available;
    return _deny('host_memory_low') if $available*1024<HEADROOM;
    my $pressure=_pressure($read->('/proc/pressure/memory'));
    return _deny('host_pressure_unknown') unless defined $pressure;
    return _deny('host_memory_pressure') unless $pressure;

    my $groups=$read->('/proc/self/cgroup');
    my @group=defined($groups) ? $groups =~ /^0::([^\r\n]+)$/mg : ();
    return _deny('cgroup_unavailable') unless @group==1 && _safe_path($group[0]);
    # Only the ordinary unified mount is supported for this MVP. Account
    # for a namespace-relative root or a mount rooted at a host subtree.
    my $mounts=$read->('/proc/self/mountinfo');
    my @roots=defined($mounts) ?
        $mounts =~ /^\d+ \d+ \d+:\d+ (\S+) \/sys\/fs\/cgroup \S+(?: [^ \r\n]+)* - cgroup2 \S+ \S+$/mg : ();
    return _deny('cgroup_mount_unknown') unless @roots==1 && _safe_path($roots[0]);
    my ($root,$path)=($roots[0],$group[0]);
    if ($root ne '/' && $path ne '/') {
        return _deny('cgroup_path_unknown') unless $path eq $root || index($path,$root.'/')==0;
        $path=substr($path,length($root)) || '/';
    }
    my $base='/sys/fs/cgroup';
    my $dir=$base.($path eq '/' ? '' : $path);
    while (1) {
        my $current=_uint($read->("$dir/memory.current"));
        my $max=_limit($read->("$dir/memory.max"));
        my $high=_limit($read->("$dir/memory.high"));
        if (!defined($current) || !defined($max) || !defined($high)) {
            # The actual unified root has no memory controller limits.
            # Do not accept partial/malformed readings or missing nonroot files.
            my $controllers=$read->("$dir/cgroup.controllers");
            return _deny('cgroup_memory_unknown') unless $dir eq $base && $root eq '/'
                && defined($controllers) && $controllers =~ /(?:\A|\s)memory(?:\s|\z)/
                && $absent->("$dir/memory.current") && $absent->("$dir/memory.max")
                && $absent->("$dir/memory.high");
        } else {
            for my $bound ($max,$high) {
                return _deny('cgroup_memory_low') if $bound ne 'max' && $bound-$current<HEADROOM;
            }
            my $p=_pressure($read->("$dir/memory.pressure"));
            return _deny('cgroup_pressure_unknown') unless defined $p;
            return _deny('cgroup_memory_pressure') unless $p;
        }
        last if $dir eq $base;
        $dir =~ s{/[^/]+\z}{};
    }
    return {ok=>1,reason=>'ready'};
}
1;
