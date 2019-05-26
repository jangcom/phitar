#
# Moose class for yield calculation
#
# Copyright (c) 2018-2019 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package Yield;

use Moose;
use Moose::Util::TypeConstraints;
use namespace::autoclean;

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.00';
our $LAST     = '2019-05-23';
our $FIRST    = '2019-01-04';

has 'Ctrls' => (
    is      => 'ro',
    isa     => 'Yield::Ctrls',
    lazy    => 1,
    default => sub { Yield::Ctrls->new() },
);

has 'FileIO' => (
    is      => 'ro',
    isa     => 'Yield::FileIO',
    lazy    => 1,
    default => sub { Yield::FileIO->new() },
);

has 'calc_rn_yield' => ( # Return value of calc_rn_yield() will be copy-pasted
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    default => sub { {} },
    handles => {
        set_calc_rn_yield   => 'set',
        clear_calc_rn_yield => 'clear',
    },
);

# Columnar array for reduce_data()
has 'columnar_arr' => (
    traits  => ['Array'],
    is      => 'ro',
    isa     => 'ArrayRef',
    lazy    => 1,
    default => sub { [] },
    handles => {
        add_columnar_arr   => 'push',
        clear_columnar_arr => 'clear',
    },
);

# Storage for calculation conditions
my($_ratio_min, $_ratio_max) = (0, 1);
subtype 'My::Moose::Yield::Fraction'
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

my %_calc_conds = (
    react_nucl_enri_lev => {
        isa  => 'My::Moose::Yield::Fraction',
        dflt => 0.09744, # Mo-100 natural abundance (amount fraction)
    },
    avg_beam_curr => {
        isa  => 'Num',
        dflt => 1.0, # uA
    }, 
    end_of_irr => {
        isa  => 'Num|Str',
        dflt => 10/60, # Hour
    }, 
    num_of_nrg_bins => {
        isa  => 'Num',
        dflt => 1_000,
    },
);

has $_ => (
    is      => 'ro',
    isa     => $_calc_conds{$_}{isa},
    lazy    => 1,
    default => $_calc_conds{$_}{dflt},
    writer  => 'set_'.$_,
) for keys %_calc_conds;

# Yield units
my %_yield_units = map { $_ => 1 } qw(
    Bq
    kBq
    MBq
    GBq
    TBq
    uCi
    mCi
    Ci
);

subtype 'My::Moose::Yield::YieldUnits'
    => as 'Str'
    => where { exists $_yield_units{$_} }
    => message {
        printf(
            "\n\n%s\n[%s] is not an allowed value.".
            "\nPlease input one of these: [%s]\n%s\n\n",
            ('-' x 70), $_,
            join(', ', sort keys %_yield_units), ('-' x 70),
        )
    };

has 'unit' => (
    is      => 'ro',
    isa     => 'My::Moose::Yield::YieldUnits',
    lazy    => 1,
    default => 'Bq',
    writer  => 'set_unit',
);

#
# gnuplot smoothing algorithms for microscopic xs data interpolation
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !!! 2019/01/28 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !!! Do not use mcsplines which, although useful for conserving !!!!!!!!!!!!!!!
# !!! the convexity of the original curve, distorts the number of energy bins. !
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#
my %_micro_xs_interp_algos = map { $_ => 1 } qw(
    csplines
    acsplines
);

subtype 'My::Moose::Yield::MicroXsInterpAlgos'
    => as 'Str'
    => where { exists $_micro_xs_interp_algos{$_} }
    => message {
        printf(
            "\n\n%s\n[%s] is not an allowed value.".
            "\nPlease input one of these: [%s]\n%s\n\n",
            ('-' x 70), $_,
            join(', ', sort keys %_micro_xs_interp_algos), ('-' x 70),
        )
    };

has 'micro_xs_interp_algo' => (
    is      => 'ro',
    isa     => 'My::Moose::Yield::MicroXsInterpAlgos',
    lazy    => 1,
    default => 'csplines',
    writer  => 'set_micro_xs_interp_algo',
);

__PACKAGE__->meta->make_immutable;
1;


package Yield::Ctrls;

use Moose;
use namespace::autoclean;
with 'My::Moose::Ctrls';

# Additional switches
my %_additional_switches = (
    pwm_switch => 'off',
);

has $_ => (
    is      => 'ro',
    isa     => 'My::Moose::Ctrls::OnOff',
    lazy    => 1,
    default => $_additional_switches{$_},
    writer  => 'set_'.$_,
) for keys %_additional_switches;

__PACKAGE__->meta->make_immutable;
1;


package Yield::FileIO;

use Moose;
use namespace::autoclean;
with 'My::Moose::FileIO';

my %_additional_attrs = ( # (key) attribute, (val) default
    micro_xs_dir => 'xs',
    micro_xs_dat => 'tendl2014_mo100_gn_mf3_t4.dat',
);

has $_ => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => $_additional_attrs{$_},
    writer  => 'set_'.$_,
) for keys %_additional_attrs;

__PACKAGE__->meta->make_immutable;
1;