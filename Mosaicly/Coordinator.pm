package Plugins::MusicArtistInfo::Mosaicly::Coordinator;

use strict;
use warnings;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_RDONLY O_NOFOLLOW O_NONBLOCK);
use File::Path qw(remove_tree);
use Cwd qw(abs_path);
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use Plugins::MusicArtistInfo::Mosaicly::Process;

# One reserved directory per configured private root. A leftover directory
# after a server crash blocks admission; do not guess that its worker died.
# Lyrion owns scheduling and calls poll from its normal timer/event loop.
my $process = 'Plugins::MusicArtistInfo::Mosaicly::Process';
my $json = JSON::PP->new->utf8->canonical->max_depth(16);

sub _fail { +{ok=>0,reason=>$_[0]} }

sub new {
    my ($class,%args)=@_;
    my ($root,$lib,$script,$includes,$perl)=@args{qw(root library worker includes perl)};
    die 'unsupported worker platform' unless $process->supported;
    for my $p ($root,$lib,$script,$perl) {
        die 'invalid runtime path' unless defined($p) && !ref($p)
            && $p =~ m{\A/} && $p !~ /\0/;
    }
    die 'invalid private root' unless -d $root && !-l $root
        && abs_path($root) eq $root;
    my @st=stat($root);
    die 'private root ownership or permissions' unless $st[4]==$>
        && ($st[2]&0777)==0700;
    die 'invalid runtime' unless -d $lib && -f $script && -f $perl && -x _
        && -x '/usr/bin/timeout' && -x '/usr/bin/prlimit';
    die 'invalid include paths' unless ref($includes) eq 'ARRAY'
        && !grep { !defined($_) || ref($_) || !m{\A/} || /\0/ || !-d $_ } @$includes;
    return bless {
        dir=>"$root/active", library=>$lib, worker=>$script,
        includes=>[@$includes], perl=>$perl,
    },$class;
}

sub busy {
    my ($self)=@_;
    return !!($self->{active} || -e $self->{dir} || -l $self->{dir});
}

sub _write_job {
    my ($path,$bytes)=@_;
    sysopen my $fh,$path,O_WRONLY|O_CREAT|O_EXCL,0600 or die "create job: $!";
    binmode $fh or die "binmode: $!";
    print {$fh} $bytes or die "write job: $!";
    close $fh or die "close job: $!";
}

sub _read_bounded {
    my ($path,$limit)=@_;
    sysopen my $fh,$path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK or die "open output: $!";
    binmode $fh or die "binmode: $!";
    my @st=stat($fh);
    die 'invalid output file' unless @st && -f _ && $st[4]==$>
        && ($st[2]&0777)==0600 && $st[7]>0 && $st[7]<=$limit;
    my $bytes='';
    while (length($bytes)<=$limit) {
        my $n=read($fh,my $chunk,8192);
        die "read output: $!" unless defined $n;
        last unless $n;
        $bytes.=$chunk;
    }
    close $fh or die "close output: $!";
    die 'output size changed' unless length($bytes)==$st[7];
    return $bytes;
}

sub _cleanup {
    my ($self)=@_;
    my $errors;
    remove_tree($self->{dir},{safe=>1,error=>\$errors});
    return !@$errors && !-e $self->{dir} && !-l $self->{dir};
}

# Accept only a server-prepared descriptor job. This method does no native
# artwork acquisition. The production caller must gate on scan lifecycle
# and resource admission before preparing and starting a job.
sub start {
    my ($self,$job)=@_;
    return _fail('busy') if $self->busy;
    return _fail('invalid_job') unless ref($job) eq 'HASH'
        && ($job->{ok}//0) eq '1' && !ref($job->{contributor_id}) && ($job->{contributor_id}//'') =~ /\A[1-9][0-9]*\z/
        && ref($job->{entries}) eq 'ARRAY' && @{$job->{entries}}<=32
        && ref($job->{diagnostics}) eq 'HASH';
    my $bytes=eval {$json->encode($job)};
    return _fail('invalid_job') if $@ || !defined($bytes) || length($bytes)>262144;
    return _fail('reservation_failed') unless mkdir($self->{dir},0700);
    my $written=eval { _write_job("$self->{dir}/job.json",$bytes); 1 };
    if (!$written) {
        return _fail('cleanup_failed') unless $self->_cleanup;
        return _fail('job_write_failed');
    }
    my $r=eval {
        $process->launch(
            directory=>$self->{dir},log=>"$self->{dir}/worker.log",
            argv=>[
                '/usr/bin/timeout','-k','5s','60s',
                '/usr/bin/prlimit','--as=268435456','--core=0',
                '--fsize=8388608','--',
                $self->{perl},(map {"-I$_"} @{$self->{includes}}),
                $self->{worker},$self->{dir},$self->{library},
            ]);
    };
    if ($@ || !$r || !$r->{ok}) {
        # A launch exception is not proof that no child exists. Preserve
        # the reservation in that case, rather than risk overlapping work.
        return _fail('launch_unresolved') if $@ || !$r;
        return _fail('cleanup_failed') unless $self->_cleanup;
        return _fail($r->{reason});
    }
    $self->{active}={
        process=>$r->{process}, job=>$json->decode($bytes),
        job_sha256=>sha256_hex($bytes),
    };
    return {ok=>1};
}

sub _validate {
    my ($self,$active)=@_;
    my $r=$json->decode(_read_bounded("$self->{dir}/result.json",65536));
    my $job=$active->{job};
    die 'result correlation mismatch' unless ref($r) eq 'HASH'
        && ($r->{job_sha256}//'') eq $active->{job_sha256}
        && ($r->{contributor_id}//'') eq $job->{contributor_id}
        && defined($r->{ok}) && !ref($r->{ok}) && $r->{ok}=~/\A[01]\z/;
    return _fail('generation_failed') unless $r->{ok};
    die 'invalid portrait metadata' unless ($r->{width}//0)==600
        && ($r->{height}//0)==600 && ($r->{content_type}//'') eq 'image/jpeg'
        && ref($r->{sources}) eq 'ARRAY' && @{$r->{sources}}>=1
        && @{$r->{sources}}<=4;
    my %expected=map { $_->{candidate}{album_id}=>$_->{source} } @{$job->{entries}};
    my (%albums,%hashes);
    for my $s (@{$r->{sources}}) {
        die 'invalid selected source' unless ref($s) eq 'HASH';
        my $d=$expected{$s->{album_id}//''};
        die 'unexpected selected source' unless $d && $d->{ok}
            && !$albums{$s->{album_id}}++
            && ($s->{sha256}//'') =~ /\A[0-9a-f]{64}\z/
            && !$hashes{$s->{sha256}}++;
        for my $k (qw(album_id artwork_id track_id source_kind)) {
            die 'source identity mismatch' unless defined($s->{$k})
                && defined($d->{$k}) && $s->{$k} eq $d->{$k};
        }
    }
    my $jpeg=_read_bounded("$self->{dir}/portrait.jpg",8*1024*1024);
    die 'portrait checksum mismatch' unless length($jpeg)==($r->{jpeg_bytes}//0)
        && sha256_hex($jpeg) eq ($r->{jpeg_sha256}//'')
        && substr($jpeg,0,2) eq "\xff\xd8" && substr($jpeg,-2) eq "\xff\xd9";
    # Publisher still owns live metadata revalidation and conditional
    # registration. No image decoding or live DB access in this method.
    return {ok=>1,job=>$job,result=>$r,bytes=>$jpeg};
}

sub poll {
    my ($self)=@_;
    my $a=$self->{active} or return {state=>'idle'};
    my $p=$a->{process}->poll;
    return $p if $p->{state} eq 'running' || $p->{state} eq 'unresolved';
    delete $self->{active};
    if ($p->{state} ne 'exited' || !defined($p->{exit_code}) || $p->{exit_code}>=124) {
        # A killed or externally reaped timeout wrapper, or an ambiguous
        # reserved timeout/exec/signal exit code, is not evidence
        # that its descendant is gone. Retain the directory and block
        # new jobs pending explicit recovery; never publish its result.
        return {state=>'complete',ok=>0,reason=>'termination_unverified',process=>$p};
    }
    my $out;
    if ($p->{exit_code}==0) {
        $out=eval {$self->_validate($a)};
        $out=_fail('invalid_result') if $@ || !$out;
    } else {
        $out=_fail('worker_exit');
    }
    return {state=>'complete',ok=>0,reason=>'cleanup_failed',process=>$p}
        unless $self->_cleanup;
    return {state=>'complete',%$out,process=>$p};
}

1;
