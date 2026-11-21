package Plugins::MusicArtistInfo::Mosaicly::Layout;

use strict;
use warnings;

# Pure geometry: no LMS modules, image libraries, filesystem or scanner state.
# The renderer is responsible for fitting source artwork within each cell
# without stretching or cropping it.

sub plan {
    my ($class, %args) = @_;

    my $count = $args{cover_count};
    die 'cover_count must be an integer between 1 and 4'
        unless defined($count) && !ref($count) && $count =~ /\A[1-4]\z/;

    my $size = exists $args{canvas_size} ? $args{canvas_size} : 600;
    die 'canvas_size must be an integer between 64 and 8192'
        unless defined($size) && !ref($size) && $size =~ /\A[0-9]+\z/ && $size >= 64 && $size <= 8192;

    my $gap = exists $args{tile_gap} ? $args{tile_gap} : 2;
    die 'tile_gap must be a nonnegative integer smaller than canvas_size / 4'
        unless defined($gap) && !ref($gap) && $gap =~ /\A[0-9]+\z/ && $gap < $size / 4;

    my $mode = exists $args{incomplete_grid} ? $args{incomplete_grid} : 'repeat';
    die "incomplete_grid must be 'repeat' or 'solid'"
        unless defined($mode) && !ref($mode) && ($mode eq 'repeat' || $mode eq 'solid');

    if ($count == 1) {
        return [ { source_index => 0, x => 0, y => 0, width => 0 + $size, height => 0 + $size } ];
    }

    my @source_indices;
    if ($count == 2) {
        @source_indices = $mode eq 'repeat' ? (0, 1, 1, 0) : (0, undef, undef, 1);
    }
    elsif ($count == 3) {
        @source_indices = (0, 1, 2, $mode eq 'repeat' ? 0 : undef);
    }
    else {
        @source_indices = (0, 1, 2, 3);
    }

    # Match the reference Python compose() algorithm for odd dimensions.
    my $left  = int(($size - $gap) / 2);
    my $right = $size - $gap - $left;
    my @rectangles = (
        [0, 0, $left, $left],
        [$left + $gap, 0, $right, $left],
        [0, $left + $gap, $left, $right],
        [$left + $gap, $left + $gap, $right, $right],
    );

    my @cells;
    for my $i (0 .. 3) {
        my ($x, $y, $width, $height) = @{ $rectangles[$i] };
        push @cells, {
            source_index => $source_indices[$i],
            x => $x, y => $y, width => $width, height => $height,
        };
    }
    return \@cells;
}

1;
