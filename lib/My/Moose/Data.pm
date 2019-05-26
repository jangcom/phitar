#
# Moose role for data reduction
#
# Copyright (c) 2018-2019 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package My::Moose::Data;

use Moose::Role;
use namespace::autoclean;

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.00';
our $LAST     = '2019-01-18';
our $FIRST    = '2018-08-18';

#
# Columnar data
#

# Headings
has $_ => (
    traits  => ['Array'],
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
    handles => {
        'clear_'.$_ => 'clear',
    },
) for qw (
    col_heads
    col_subheads
);

# Separators
my %_seps = ( # (key) attribute => (val) default
    col_heads    => '|',
    col_subheads => '|',
    row          => "\n",
    col          => "\t",
    plane        => "\n\n",
    dataset      => "\n\n", # gnuplot
);

has $_.'_sep' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => $_seps{$_},
    writer  => 'set_'.$_.'_sep',
) for keys %_seps;

# Storages
has 'col_data' => (
    traits  => ['Array'],
    is      => 'rw',
    isa     => 'ArrayRef[ArrayRef|Str]',
    default => sub { [] },
    handles => {
        clear_col_data => 'clear',
    },
);

# For constructing alignment conversions
has $_ => (
    traits  => ['Array'],
    is      => 'rw',
    isa     => 'ArrayRef[Int]',
    default => sub { [] },
    handles => {
        'clear_'.$_ => 'clear',
    },
) for qw(
    col_widths
    border_widths
);

# Indices
has $_ => (
    traits  => ['Array'],
    is      => 'rw',
    isa     => 'ArrayRef',
    default => sub { [] },
    handles => {
        'clear_'.$_ => 'clear',
    },
) for qw(
    row_idx
    col_idx
    plane_idx
);

#
# Indicators
#
my %_indicators = (
    nan => 'NaN',
    eof => '#eof',
);

has $_ => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => $_indicators{$_},
    writer  => 'set_'.$_,
) for keys %_indicators;

1;