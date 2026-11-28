package Plugins::MusicArtistInfo::Mosaicly::ScanClient;
use strict;
use warnings;

my ($credentials,$claimed,$ack,$installed);

sub rpc {
    my ($operation,$field)=@_;
    return 0 unless $credentials;
    my $ok=eval {
        require LWP::UserAgent;
        require HTTP::Request;
        require JSON::XS;
        require Slim::Utils::Prefs;
        my $prefs=Slim::Utils::Prefs::preferences('server');
        my $port=$prefs->get('httpport') || 9000;
        my $req=HTTP::Request->new(POST=>"http://127.0.0.1:$port/jsonrpc.js");
        $req->header('Content-Type'=>'application/json');
        if (my $user=$prefs->get('username')) {
            $req->authorization_basic($user,$prefs->get('password'));
        }
        $req->content(JSON::XS::encode_json({
            id=>2,method=>'slim.request',
            params=>['',['mai_mosaicly_session',$operation,@$credentials]],
        }));
        my $ua=LWP::UserAgent->new(timeout=>3,max_redirect=>0);
        my $response=$ua->request($req);
        die 'RPC failure' unless $response->is_success;
        my $decoded=JSON::XS::decode_json($response->content);
        die 'invalid response' unless ref($decoded->{result}) eq 'HASH';
        my $value=$decoded->{result}{$field};
        defined($value) && "$value" eq '1';
    };
    return $ok ? 1 : 0;
}

sub init {
    return if $installed;
    my $bootstrap=delete $ENV{MOSAICLY_SESSION_V2};
    return unless defined($bootstrap)
        && $bootstrap =~ /\A([a-f0-9]{32}):([1-9][0-9]{0,9}):([a-f0-9]{64})\z/;
    $credentials=[$1,$2,$3];
    undef $bootstrap;
    $claimed=rpc('claim','claimed');
    unless ($claimed) { undef $credentials; return }
    require Slim::Utils::SQLiteHelper;
    my $original=Slim::Utils::SQLiteHelper->can('afterScan') or return;
    no warnings 'redefine';
    *Slim::Utils::SQLiteHelper::afterScan=sub {
        my $context=wantarray;
        my (@result,$result);
        if ($context) { @result=$original->(@_) }
        elsif (defined $context) { $result=$original->(@_) }
        else { $original->(@_) }
        $ack=rpc('ack','success') if $claimed;
        return @result if $context;
        return $result if defined $context;
        return;
    };
    $installed=1;
}

sub shutdown {
    rpc('verify','authorized') if $installed && $claimed && $ack;
    undef $credentials;
    $claimed=$ack=0;
}

1;
