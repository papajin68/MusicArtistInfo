use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use MosaiclyTestSupport qw(load_native source_bmp);
use Scalar::Util qw(refaddr);

load_native();

my $c = 'Plugins::MusicArtistInfo::Mosaicly::Compositor';
my $layout = 'Plugins::MusicArtistInfo::Mosaicly::Layout';

my $source = source_bmp(80,80,[224,32,64]);
my $variants = [
    {width=>600,height=>600},
    {width=>300,height=>300},
];

sub prepare_source {
    return $c->prepare(
        bytes=>$$source,
        variants=>$variants,
        @_,
    );
}

# Encoded source limit

{
    my $oversized = 'x' x (64*1024*1024+1);

    is_deeply(
        $c->prepare(
            bytes=>$oversized,
            variants=>$variants,
        ),
        {ok=>0,reason=>'source_too_large'},
        'Encoded source over 64 MiB rejected'
    );
}

# Native memory-limit classification

{
    no warnings 'redefine';

    local *Image::Scale::resize_gm_fixed_point = sub {
        die "Image::Scale memory_limit exceeded "
            . "(wanted to allocate 536870913 bytes)\n";
    };

    is_deeply(
        prepare_source(),
        {ok=>0,reason=>'native_memory_limit'},
        'Known native allocation exception classified'
    );
}

# Unexpected exception propagation

{
    no warnings qw(redefine once);

    local *Image::Scale::new = sub {
        die "Injected unexpected constructor exception\n";
    };

    eval { prepare_source() };

    like(
        $@,
        qr/Injected unexpected constructor exception/,
        'Unexpected constructor exception remains fatal'
    );
}

{
    no warnings 'redefine';

    local *Image::Scale::resize_gm_fixed_point = sub {
        die "Injected unexpected resize exception\n";
    };

    eval { prepare_source() };

    like(
        $@,
        qr/Injected unexpected resize exception/,
        'Unexpected resize exception remains fatal'
    );
}

# Atomic multi-variant preparation

{
    no warnings 'redefine';

    my $original =
        \&Image::Scale::resize_gm_fixed_point;

    my $calls = 0;

    local *Image::Scale::resize_gm_fixed_point = sub {
        ++$calls;

        return 0 if $calls == 2;

        return $original->(@_);
    };

    my $p = prepare_source();

    is($calls,2,'Both variant resizes attempted');

    is_deeply(
        $p,
        {ok=>0,reason=>'corrupt_image'},
        'Second variant failure rejects whole source'
    );

    ok(
        !exists($p->{image}),
        'No partially prepared image returned'
    );
}

# Prepared image variant reuse

{
    no warnings 'redefine';

    my $original =
        \&Image::Scale::resize_gm_fixed_point;

    my $calls = 0;

    local *Image::Scale::resize_gm_fixed_point = sub {
        ++$calls;
        return $original->(@_);
    };

    # Square source fits to 300x300 in both cells.
    my $p = prepare_source(
        variants=>[
            {width=>300,height=>300},
            {width=>300,height=>301},
            {width=>300,height=>300},
        ],
    );

    BAIL_OUT("Reuse preparation failed")
        unless $p->{ok};

    is($calls,1,'Only one native resize required');

    my $v = $p->{image}{variants};

    is(
        scalar(keys %$v),
        2,
        'Two unique cell variants retained'
    );

    is(
        refaddr($v->{'300x300'}{rgb}),
        refaddr($v->{'300x301'}{rgb}),
        'Identical fitted RGB buffer shared'
    );

    is_deeply(
        [@{$v->{'300x301'}}{qw(width height x y)}],
        [300,300,0,0],
        'Odd vertical padding correctly positioned'
    );
}

# Invalid render contracts

my $p = prepare_source();

BAIL_OUT("Render contract fixture preparation failed")
    unless $p->{ok};

my $image = $p->{image};

my $cells = $layout->plan(
    cover_count=>1
);

{
    my $invalid = [
        {%{$cells->[0]},x=>1}
    ];

    eval {
        $c->render(
            images=>[$image],
            layout=>$invalid,
        );
    };

    like(
        $@,
        qr/layout does not match profile/,
        'Modified layout rejected'
    );
}

{
    my $invalid = {
        %$image,
        variants=>{},
    };

    eval {
        $c->render(
            images=>[$invalid],
            layout=>$cells,
        );
    };

    like(
        $@,
        qr/missing prepared variant/,
        'Missing image variant rejected'
    );
}

{
    my $invalid = {
        %$image,
        background=>'ffffff',
    };

    eval {
        $c->render(
            images=>[$invalid],
            layout=>$cells,
        );
    };

    like(
        $@,
        qr/invalid prepared image/,
        'Mismatched background rejected'
    );
}

{
    my $invalid = {
        %$image,
        variants=>{
            %{$image->{variants}},
            '600x600'=>{
                %{$image->{variants}{'600x600'}},
                x=>1,
            },
        },
    };

    eval {
        $c->render(
            images=>[$invalid],
            layout=>$cells,
        );
    };

    like(
        $@,
        qr/invalid prepared offsets/,
        'Invalid prepared placement rejected'
    );
}

# Recovery after injected failures

my $r = $c->render(
    images=>[$image],
    layout=>$cells,
);

ok($r->{ok},'Valid rendering still successful');

is(
    $r->{content_type},
    'image/jpeg',
    'Valid JPEG content type'
);

done_testing();
