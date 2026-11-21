use strict;
use warnings;
use Test::More;

require './Mosaicly/Layout.pm';
my $layout = 'Plugins::MusicArtistInfo::Mosaicly::Layout';

sub indices {
    my ($cells) = @_;
    return [ map { $_->{source_index} } @$cells ];
}

is_deeply(indices($layout->plan(cover_count => 1)), [0], 'one cover fills canvas');
is_deeply(indices($layout->plan(cover_count => 2)), [0, 1, 1, 0], 'two covers repeat diagonally');
is_deeply(indices($layout->plan(cover_count => 2, incomplete_grid => 'solid')),
    [0, undef, undef, 1], 'two covers with solid alternate tiles');
is_deeply(indices($layout->plan(cover_count => 3)), [0, 1, 2, 0], 'three covers repeat first at bottom-right');
is_deeply(indices($layout->plan(cover_count => 3, incomplete_grid => 'solid')),
    [0, 1, 2, undef], 'three covers with solid bottom-right');
is_deeply(indices($layout->plan(cover_count => 4)), [0, 1, 2, 3], 'four covers in order');
is_deeply(indices($layout->plan(cover_count => 4, incomplete_grid => 'solid')),
    [0, 1, 2, 3], 'mode does not change four-cover layout');

is_deeply($layout->plan(cover_count => 1, canvas_size => 101),
    [{ source_index => 0, x => 0, y => 0, width => 101, height => 101 }],
    'one cover uses entire canvas and ignores gap');

is_deeply($layout->plan(cover_count => 4, canvas_size => 101, tile_gap => 2), [
    { source_index => 0, x => 0,  y => 0,  width => 49, height => 49 },
    { source_index => 1, x => 51, y => 0,  width => 50, height => 49 },
    { source_index => 2, x => 0,  y => 51, width => 49, height => 50 },
    { source_index => 3, x => 51, y => 51, width => 50, height => 50 },
], 'odd canvas dimensions match Python geometry');

is_deeply($layout->plan(cover_count => 4, canvas_size => 100, tile_gap => 0), [
    { source_index => 0, x => 0,  y => 0,  width => 50, height => 50 },
    { source_index => 1, x => 50, y => 0,  width => 50, height => 50 },
    { source_index => 2, x => 0,  y => 50, width => 50, height => 50 },
    { source_index => 3, x => 50, y => 50, width => 50, height => 50 },
], 'no-gap geometry matches Python');

for my $bad (undef, 0, 5, -1, '2.0', [], {}) {
    my %args = (cover_count => $bad);
    eval { $layout->plan(%args) };
    like($@, qr/cover_count/, 'invalid cover count is rejected');
}
for my $bad (undef, 0, 63, 8193, '64.5', []) {
    eval { $layout->plan(cover_count => 2, canvas_size => $bad) };
    like($@, qr/canvas_size/, 'invalid canvas dimension is rejected');
}
for my $bad (undef, -1, 25, '2.3', []) {
    eval { $layout->plan(cover_count => 2, canvas_size => 100, tile_gap => $bad) };
    like($@, qr/tile_gap/, 'invalid gap is rejected');
}
for my $bad (undef, 'stretch', '') {
    eval { $layout->plan(cover_count => 2, incomplete_grid => $bad) };
    like($@, qr/incomplete_grid/, 'invalid grid mode is rejected');
}

done_testing();
