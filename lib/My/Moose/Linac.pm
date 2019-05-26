#
# Moose class for electron linear accelerators
#
# Copyright (c) 2018-2019 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package Linac;

use Moose;
use namespace::autoclean;
use feature qw(say);

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.00';
our $LAST     = '2019-01-01';
our $FIRST    = '2018-08-16';

has 'rf_power_source' => (
    is      => 'ro',
    isa     => 'Linac::rfPowerSource',
    lazy    => 1,
    default => sub { Linac::rfPowerSource->new() },
);

# Linac parameters with plain setters
my %_params_w_plain_setters = (
    name           => 'Electron linear accelerator',
    peak_beam_nrg  => 0,
    peak_beam_curr => 0,
);

has $_ => (
    is      => 'ro',
    isa     => 'Str|Num',
    lazy    => 1,
    default => $_params_w_plain_setters{$_},
    writer  => 'set_'.$_,
) for keys %_params_w_plain_setters;

# Linac parameters "newly defined" setters
has $_ => (
    is  => 'rw',
    isa => 'Num',
) for qw(
    peak_beam_power
    avg_beam_curr
    avg_beam_power
);

sub set_peak_beam_power {
    my $self = shift;
    
    $self->peak_beam_power(
        $self->peak_beam_nrg
        * $self->peak_beam_curr
    );
    
    return;
}

sub set_avg_beam_curr {
    my $self = shift;
    
    $self->avg_beam_curr(
        $self->peak_beam_curr
        * $self->rf_power_source->duty_cycle
    );
    
    return;
}

sub set_avg_beam_power {
    my $self = shift;
    
    $self->avg_beam_power(
        $self->peak_beam_nrg
        * $self->avg_beam_curr
    );
    
    return;
}

sub set_params {
    my $self   = shift;
    my %params = @_;
    
    $self->set_name($params{name}) if defined $params{name};
    
    # Exit if compulsory parameters have not been passed.
    foreach ('rf_power_source', 'peak_beam_nrg', 'peak_beam_curr') {
        unless (defined $params{$_}) {
            say "The [$_] key was not provided; terminating.";
            exit;
        }
    }
    
    # "Peak" quantities
    $self->set_peak_beam_nrg($params{peak_beam_nrg});   # eV
    $self->set_peak_beam_curr($params{peak_beam_curr}); # A
    $self->set_peak_beam_power();                       # W
    
    # "Average" quantities
    $self->rf_power_source->_set_kly_params(
        "\L$params{rf_power_source}" # The klystron name must be all-lowercase
                                     # letters for hash access.
    );
    $self->set_avg_beam_curr();
    $self->set_avg_beam_power();
    
    return;
}

sub update_params {
    my $self   = shift;
    my %params = @_;
    
    if (%params) {
        foreach my $k (keys %params) {
            my $_param_setter = 'set_'.$k;
            $self->$_param_setter($params{$k});
        }
    }
    
    $self->set_peak_beam_power();
    $self->set_avg_beam_curr();
    $self->set_avg_beam_power();
    
    return;
}

__PACKAGE__->meta->make_immutable;
1;


package Linac::rfPowerSource;

use Moose;
use namespace::autoclean;

#
# To add a new klystron, do the following:
# (1) Create an attribute like 'tetd_xband_e37113' and its builder.
# (2) Update %klystrons_list of the _set_kly_params subroutine.
#

# Klystron parameters to be set via the _set_kly_params subroutine
has 'name' => (
    is      => 'rw',
    isa     => 'Str',
    lazy    => 1,
    default => 'Klystron',
);

has $_ => (
    is  => 'rw',
    isa => 'Num',
) for qw(
    oper_freq
    rf_pulse_width
    rf_pulse_per_sec
    duty_cycle
);

# Thales L-band klystron "TV2022B"
has 'thales_lband_tv2022b' => (
    is       => 'ro',
    isa      => 'HashRef[Num|Str]',
    lazy     => 1,
    builder  => '_build_thales_lband_tv2022b',
    init_arg => undef,
);

sub _build_thales_lband_tv2022b {
    return {
        name             => 'Thales L-band TV2022B',
        oper_freq        => 1.3e+09, # sec^-1 (Hz)
        rf_pulse_width   => 4e-06,   # sec
        rf_pulse_per_sec => 100,     # sec^-1
    };
};

# TETD S-band klystron "E37307"
has 'tetd_sband_e37307' => (
    is       => 'ro',
    isa      => 'HashRef[Num|Str]',
    lazy     => 1,
    builder  => '_build_tetd_sband_e37307',
    init_arg => undef,
);

sub _build_tetd_sband_e37307 {
    return {
        name             => 'TETD S-band E37307',
        oper_freq        => 2.856e+09, # sec^-1 (Hz)
        rf_pulse_width   => 18e-06,    # sec
        rf_pulse_per_sec => 667,       # sec^-1
    };
};

# TETD X-band klystron "E37113"
has 'tetd_xband_e37113' => (
    is       => 'ro',
    isa      => 'HashRef[Num|Str]',
    lazy     => 1,
    builder  => '_build_tetd_xband_e37113',
    init_arg => undef,
);

sub _build_tetd_xband_e37113 {
    return {
        name             => 'TETD X-band E37113',
        oper_freq        => 11.9942e+09, # sec^-1 (Hz)
        rf_pulse_width   => 5e-06,       # sec
        rf_pulse_per_sec => 400,         # sec^-1
    };
};

sub _set_kly_params  {
    my $self     = shift;
    my $klystron = shift; # Must always be lowercased for hash access.
    
    my %klystrons_list = ( # Used in place of symbolic references.
        thales_lband_tv2022b => $self->thales_lband_tv2022b,
        tetd_sband_e37307    => $self->tetd_sband_e37307,
        tetd_xband_e37113    => $self->tetd_xband_e37113,
    );
    
    # Exit if a wrong klystron has been input.
    # (i.e. If the klystron had not been registered to %klystrons_list.)
    my $is_registered = grep $klystron eq $_, keys %klystrons_list;
    if (not $is_registered) {
        say "[$klystron]: Nonregistered klystron. Terminating.";
        say "Choose one of these:";
        say for keys %klystrons_list;
        exit;
    }
    
    $self->$_($klystrons_list{$klystron}{$_}) for qw(
        name
        oper_freq
        rf_pulse_width
        rf_pulse_per_sec
    );
    $self->duty_cycle($self->rf_pulse_width * $self->rf_pulse_per_sec);
    
    return;
}

__PACKAGE__->meta->make_immutable;
1;