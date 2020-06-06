#
# Moose class for physical and physico-chemical constants
#
# Copyright (c) 2018-2020 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package Phys;

use Moose;
use namespace::autoclean;

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.00';
our $LAST     = '2020-05-03';
our $FIRST    = '2018-08-18';

has 'constants' => (
    is       => 'ro',
    isa      => 'HashRef[Num]',
    builder  => '_build_constants',
    init_arg => undef,
);

sub _build_constants {
    return {
        avogadro         => 6.022e+23,  # mol^-1
        coulomb_per_elec => 1.602e-19,
    };
}

has 'unit_delim' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Str]',
    lazy    => 1,
    builder => '_build_unit_delim',
    handles => {
        set_unit_delim => 'set',
    },
);

sub _build_unit_delim {
    return {
        lt => '(',
        rt => ')'
    };
}

__PACKAGE__->meta->make_immutable;
1;