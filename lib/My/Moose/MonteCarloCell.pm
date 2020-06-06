#
# Moose class for PHITS cells
#
# Copyright (c) 2018-2020 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package MonteCarloCell;

use Moose;
use Moose::Util::TypeConstraints;
use namespace::autoclean;

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.00';
our $LAST     = '2020-05-03';
our $FIRST    = '2018-08-18';

# Cell identification items
# The two attributes below are required,
# but 'required => 1' have intentionally been removed
# for the structural consistency of phitar.
# They are now populated in the init() routine of phitar.
has $_ => (
    is     => 'ro',
    writer => 'set_'.$_,
) for qw(
    flag
    cell_mat
);

# Ratio between material density and elemental density
# - For real targets used in experiments
my($_ratio_min, $_ratio_max) = (0, 1);
subtype 'My::Moose::MonteCarloCell::DensRatio'
    => as 'Num'
    => where { $_ >= $_ratio_min and $_ <= $_ratio_max }
    => message {
        printf(
            "\n\n%s\n[%s] not allowed. Valid range: [%s,%s].\n%s\n\n",
            ('-' x 70),
            $_,
            $_ratio_min,
            $_ratio_max,
            ('-' x 70),
        );
    };

has 'dens_ratio' => (
    is      => 'ro',
    isa     => 'My::Moose::MonteCarloCell::DensRatio',
    lazy    => 1,
    default => 1.0000,
    writer  => 'set_dens_ratio',
);

my %_cell_storages = (
    cell_mats_list => sub { {} },  # List of available materials
    cell_props     => sub { {} },  # Storage for MC cell properties
);

has $_ => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    default => $_cell_storages{$_},
    handles => {
        'set_'.$_ => 'set',
    },
) for keys %_cell_storages;

# Geometries to be iterated
has 'iter_geoms' => (
    is  => 'rw',
    isa => 'ArrayRef',
);
sub set_iter_geoms {
    my $self = shift;
    $self->iter_geoms(\@_);
    return;
}

#
# Storages for fixed geometries
#
my %_geoms = (  # (key) attribute => (val) default
    mass             => 0,    # g
    vol              => 0,    # cm^3
    area             => 0,    # cm^2
    beam_ent         => 0.0,  # cm
    height_fixed     => 0.1,
    radius_fixed     => 1.0,
    bot_radius_fixed => 0.15,
    top_radius_fixed => 0.60,
    gap_fixed        => 0.15,
    # Those written to the PHITS input files
    height           => 0.1,
    radius           => 1.0,
    bot_radius       => 0.15,
    top_radius       => 0.60,
    gap              => 0.15,
    # Only for aluminum wrap
    thickness_fixed  => 0.0012,  # 12 um
    thickness        => 0.0012,
);
has $_ => (
    is      => 'ro',
    isa     => 'Num',
    default => $_geoms{$_},
    lazy    => 1,
    writer  => 'set_'.$_,
) for keys %_geoms;

#
# Storages for varying geometries
#
my @_v_geoms = qw (
    heights_of_int
    radii_of_int
    bot_radii_of_int
    top_radii_of_int
    gaps_of_int
);

# Attributes
has $_ => (
    is      => 'rw',
    isa     => 'ArrayRef[Num]',
    default => sub { [] },
) for @_v_geoms;

# Setters
sub set_heights_of_int {
    my $self = shift;
    @{$self->heights_of_int} = @{$_[0]} if defined $_[0];
    return;
}
sub set_radii_of_int {
    my $self = shift;
    @{$self->radii_of_int} = @{$_[0]} if defined $_[0];
    return;
}
sub set_bot_radii_of_int {
    my $self = shift;
    @{$self->bot_radii_of_int} = @{$_[0]} if defined $_[0];
    return;
}
sub set_top_radii_of_int {
    my $self = shift;
    @{$self->top_radii_of_int} = @{$_[0]} if defined $_[0];
    return;
}
sub set_gaps_of_int {
    my $self = shift;
    @{$self->gaps_of_int} = @{$_[0]} if defined $_[0];
    return;
}

__PACKAGE__->meta->make_immutable;
1;