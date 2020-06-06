#!/usr/bin/env perl
use strict;
use warnings;
use autodie;
use utf8;
use Carp           qw(croak);
use Cwd            qw(getcwd);
use Data::Dump     qw(dump);
use feature        qw(say state);
use File::Basename qw(basename);
use File::Copy     qw(copy);
use List::Util     qw(first min);
use POSIX          qw(ceil);
use constant PI    => 4 * atan2(1, 1);
use constant ARRAY => ref [];
use constant HASH  => ref {};

BEGIN { unshift @INC, "./lib"; }  # @INC's become dotless since v5.26000

use My::Toolset qw(:coding :rm :mod :geom);
use My::Nuclear qw(:yield);
use My::Moose::Animate;  # Moose.pm <= vendor lib || cpanm
use My::Moose::ANSYS;
use My::Moose::Image;
use My::Moose::Linac;
use My::Moose::MonteCarloCell;
use My::Moose::Parser;
use My::Moose::PHITS;
use My::Moose::Phys;
use My::Moose::Tally;
use My::Moose::Yield;
my $animate = Animate->new();
my $mapdl             = ANSYS->new();
my $mapdl_of_macs     = ANSYS->new();  # Target-specific
my $mapdl_of_macs_all = ANSYS->new();  # For all targets
my $image = Image->new();
my $llinac = Linac->new();
my $slinac = Linac->new();
my $xlinac = Linac->new();  # PRAB (20) p. 104701
my $elinac_of_int;
my $bconv         = MonteCarloCell->new();
my $motar         = MonteCarloCell->new();
my $motar_rcc     = MonteCarloCell->new();
my $motar_trc     = MonteCarloCell->new();
my $flux_mnt_up   = MonteCarloCell->new();
my $flux_mnt_down = MonteCarloCell->new();
my $tar_wrap      = MonteCarloCell->new();
my $motar_ent     = MonteCarloCell->new();  # Ultrathin, nonmat layer
my $motar_ent_to;
my $mc_space      = MonteCarloCell->new();  # MC calculation boundary
my $void          = MonteCarloCell->new();
my $parser = Parser->new();
my $phits = PHITS->new();
my $angel = PHITS->new();
my $phys = Phys->new();
my $t_track       = Tally->new();
my $t_cross       = Tally->new();
my $t_cross_dump  = Tally->new();
my $t_heat        = Tally->new();
my $t_heat_mapdl  = Tally->new();
my $t_gshow       = Tally->new();
my $t_3dshow      = Tally->new();
my $t_tot_fluence = Tally->new();
my $t_subtotal    = Tally->new();
my $t_total       = Tally->new();
my $t_shared      = Tally->new();
my $yield                    = Yield->new();
my $yield_mo99               = Yield->new();
my $yield_mo99_for_sp_src    = Yield->new();
my $pwm_mo99_for_sp_src      = Yield->new();
my $yield_au196              = Yield->new();
my $yield_au196_1            = Yield->new();
my $yield_au196_1_for_sp_src = Yield->new();
my $pwm_au196_1_for_sp_src   = Yield->new();
my $yield_au196_2            = Yield->new();
my $yield_au196_2_for_sp_src = Yield->new();
my $pwm_au196_2_for_sp_src   = Yield->new();


our $VERSION = '1.04';
our $LAST    = '2020-05-12';
our $FIRST   = '2018-04-23';


sub parse_argv {
    # """@ARGV parser"""
    my (
        $argv_aref,
        $cmd_opts_href,
        $run_opts_href,
    ) = @_;
    my %cmd_opts = %$cmd_opts_href;  # For regexes

    # Parser: Overwrite default run options if requested by the user.
    my $field_sep = ',';
    foreach (@$argv_aref) {
        # User input
        if (/[.]phi$/i) {
            croak "\n[$_] NOT found; terminating.\n" if not -e;
            $run_opts_href->{inp} = $_;
        }

        # Dump mode and its source particle
        if (/$cmd_opts{dump_src}/) {
            s/$cmd_opts{dump_src}//i;
            # Run only if a particle string has also been given.
            if ($_) {
                $t_cross_dump->set_particles_of_int(
                    /phot/i ? 'photon'  :
                    /neut/i ? 'neutron' :
                              'electron'  # Default
                );
                $phits->source->set_mode('dump');
            }
        }

        # Program run with default (predefined) parameters
        if (/$cmd_opts{default}/) {
            $run_opts_href->{is_default} = 1;
        }

        # Report path
        if (/$cmd_opts{rpt_subdir}/) {
            s/$cmd_opts{rpt_subdir}//i;
            $run_opts_href->{rpt_path} = getcwd().'/'.$_;
        }

        # Report formats
        if (/$cmd_opts{rpt_fmts}/) {
            s/$cmd_opts{rpt_fmts}//;
            if (/\ball\b/i) {
                @{$run_opts_href->{rpt_fmts}} = qw(dat tex csv xlsx json yaml);
            }
            else {
                @{$run_opts_href->{rpt_fmts}} = split /$field_sep/;
            }
        }

        # Report flag
        if (/$cmd_opts{rpt_flag}/) {
            s/$cmd_opts{rpt_flag}//;
            $run_opts_href->{rpt_flag} = $_ if $_;
        }

        # The shell won't be paused at the end of the program.
        if (/$cmd_opts{nopause}/) {
            $run_opts_href->{is_nopause} = 1;
        }
    }

    return;
}


sub init {
    # """Initialize object attributes."""

    #
    # ANSYS MAPDL
    #
    $mapdl->set_exe('mapdl.exe');
    $mapdl->Cmt->set_symb('!');
    $mapdl->Cmt->set_borders(
        leading_symb => $mapdl->Cmt->symb,
        border_symbs => ['#', '=', '-']
    );
    $mapdl->Data->set_eof('/eof');  # An MAPDL command
    $mapdl->set_params(
        # key-val pair for MAPDL
        job_name => ['job_name', 'phitar'                        ],
        tab_ext  => ['tab_ext', $mapdl->FileIO->fname_exts->{tab}],
        eps_ext  => ['eps_ext', $mapdl->FileIO->fname_exts->{eps}],
        # Target-dependent parameters are defined
        # in the inner_iterator() subroutine.
    );

    #
    # phitar input file parser
    #
    $parser->Data->set_delims(
        obj_attr => qr/[.]/,
        key_val  => '=',
        list_val => ',',
        dict_val => ':',  # Like the Python's dictionary key-val delim
    );

    #
    # PHITS
    #
    $phits->set_exe('phits.bat');
    $phits->Cmt->set_symb(
        # Although multiple comment characters ($, #, %, !)
        # can be used for PHITS input files,
        # the dollar sign is preferable, as can be used
        # in the cell and surface sections. (Others cannot.)
        '$'
    );
    $phits->Cmt->set_borders_len(
        # Designed to be independent from Cmt->set_borders,
        # so that comment borders with different lengths
        # can be generated.
        70
    );
    $phits->Cmt->set_borders(
        # Uses the default value of Cmt->borders_len (which is 70)
        # or the one overridden by Cmt->set_borders_len.
        leading_symb => $phits->Cmt->symb,
        border_symbs => ['+', '*', '=', '-']
    );
    $phits->Cmt->set_abbrs(
        # Key-val pairs predefined in the Moose class:
        # energy-eng, radius-rad, height-hgt, and bottom-bot
        phits   => ['phits'      => 'phi' ],
        angel   => ['angel'      => 'ang' ],
        varying => ['varying'    => 'v'   ],
        fixed   => ['fixed'      => 'f'   ],
        bot_rad => ['bot_radius' => 'brad'],
        top_rad => ['top_radius' => 'trad'],
    );
    $phits->Cmt->set_full_names(  # To be used in ANGEL
        xfwhm   => '$x$-FWHM',
        yfwhm   => '$y$-FWHM',
        zfwhm   => '$z$-FWHM',
        xyfwhms => '$xy$-FWHM',
    );
    $phits->Data->set_eof($phits->Cmt->symb.'eof');
    # If you want lengthier words to appear in the filenames,
    # change the last index from [1] to [0].
    $phits->FileIO->set_varying_str($phits->Cmt->abbrs->{varying}[1]);
    $phits->FileIO->set_fixed_str($phits->Cmt->abbrs->{fixed}[1]);

    # PHITS source
    # >> Energy distribution
    $phits->source->set_gaussian_nrg(
        type => {
            key  => 'e-type',
            val  => 2,
            cmt  => $phits->Cmt->symb.' Gaussian energy distribution',
            abbr => 'gaussian_nrg',
        },
        eg0 => {
            key         => 'eg0',
            flag        => 'eg0',
            val_fixed   => 35,
            vals_of_int => [30, 35, 40],
            cmt         => $phits->Cmt->symb.' Center energy',
        },
        fwhm => {
            key => 'eg1',
            val => 1,
            cmt => $phits->Cmt->symb.' FWHM',
        },
        lt_from_eg0 => 3,
        cutoff_min => {  # Used for [source]
            key => 'eg2',
            val => 35 - 3,  # Calculated in populate_gaussian_nrg_cutoffs()
            cmt => $phits->Cmt->symb.' Cutoff energy, min',
        },
        rt_from_eg0 => 3,
        cutoff_max => {  # Used for [source] and "tally emax"
            key => 'eg3',
            val => 35 + 3,  # Calculated in populate_gaussian_nrg_cutoffs()
            cmt => $phits->Cmt->symb.' Cutoff energy, max',
        },
    );
    $phits->source->set_free_form_nrg(
        type => {
            key  => 'e-type',
            val  => 22,
            cmt  => $phits->Cmt->symb.' Free-form energy distribution',
            abbr => 'free_form_nrg',
        },
        ne => {  # Used for [source]
            key => 'ne',
            val => 0,  # Calculated in populate_free_form_nrg_dist()
            cmt => $phits->Cmt->symb.' Number of energy bins',
        },
        file => '',
        cutoff_min => {  # Used as a comment
            val => 0,  # Calculated in populate_free_form_nrg_dist()
            cmt => $phits->Cmt->symb.' e-lower of first energy bin',
        },
        # cutoff_max: For key-accessing purposes,
        # the same key as the gaussian_nrg was given.
        cutoff_max => {  # Used for "tally emax"
            val => 0,  # Calculated in populate_free_form_nrg_dist()
            cmt => $phits->Cmt->symb.' e-upper of last energy bin',
        },
    );
    # <<
    # >> Spatial distribution
    $phits->source->set_gaussian_xy(
        type => {
            key  => 's-type',
            val  => 13,
            cmt  => $phits->Cmt->symb.' Gaussian distribution on xy plane',
            abbr => 'gaussian_xy',
        },
        proj => {
            key => 'proj',
            val => 'electron',
            cmt => $phits->Cmt->symb.' Projectile',
        },
        # Spatial distribution parameters in cm
        # > Must be within the MC space macrobody
        x_center => {
            key => 'x0',
            val => 0.0,
            cmt => $phits->Cmt->symb.' x-center of Gaussian',
        },
        y_center => {
            key => 'y0',
            val => 0.0,
            cmt => $phits->Cmt->symb.' y-center of Gaussian',
        },
        xy_fwhms => {
            key         => 'r1',
            flag        => 'xyfwhms',
            val_fixed   => 0.3,
            vals_of_int => [map $_ /= 10, 1..5],
            cmt         => $phits->Cmt->symb.' x-FWHM and y-FWHM of Gaussian',
        },
        z_beg => {
            key => 'z0',
            val => -5.0,
            cmt => $phits->Cmt->symb.' z-beginning coordinate',
        },
        z_end => {
            key => 'z1',
            val => -5.0,
            cmt => $phits->Cmt->symb.' z-ending coordinate',
        },
        t_cross_intact => {
            z_beg => -5.0 + 1,  # Based on {z_beg}{val}
            z_end => -5.0 + 1 + 1e-7,
        },
        dir => {
            key => 'dir',
            val => 1.0,
            cmt => $phits->Cmt->symb.' z-axis angle in arccosine',
        },
    );
    $phits->source->set_gaussian_xyz(
        type => {
            key  => 's-type',
            val  => 3,
            cmt  => $phits->Cmt->symb.' Gaussian distribution in xyz dirs',
            abbr => 'gaussian_xyz',
        },
        proj => {
            key => 'proj',
            val => 'electron',
            cmt => $phits->Cmt->symb.' Projectile',
        },
        xyz_sep => '_',
        x_center => {
            key => 'x0',
            val => 0.0,
            cmt => $phits->Cmt->symb.' x-center of Gaussian',
        },
        x_fwhm => {
            key         => 'x1',
            flag        => 'xfwhm',
            val_fixed   => 0.3,
            vals_of_int => [map $_ /= 10, 1..5],
            cmt         => $phits->Cmt->symb.' x-FWHM of Gaussian',
        },
        y_center => {
            key => 'y0',
            val => 0.0,
            cmt => $phits->Cmt->symb.' y-center of Gaussian',
        },
        y_fwhm => {
            key         => 'y1',
            flag        => 'yfwhm',
            val_fixed   => 0.3,
            vals_of_int => [map $_ /= 10, 1..5],
            cmt         => $phits->Cmt->symb.' y-FWHM of Gaussian',
        },
        z_center => {
            key => 'z0',
            val => -5.0,
            cmt => $phits->Cmt->symb.' z-center of Gaussian',
        },
        z_fwhm => {
            key         => 'z1',
            flag        => 'zfwhm',
            val_fixed   => 0.0,
            vals_of_int => [0.0],
            cmt         => $phits->Cmt->symb.' z-FWHM of Gaussian',
        },
        t_cross_intact => {
            z_beg => -5.0 + 1,  # Based on {z_center}{val}
            z_end => -5.0 + 1 + 1e-7,
        },
        dir => {
            key => 'dir',
            val => 1.0,
            cmt => $phits->Cmt->symb.' z-axis angle in arccosine',
        },
    );
    $phits->source->set_cylindrical(
        type => {
            key  => 's-type',
            val  => 1,
            cmt  => $phits->Cmt->symb.' Cylindrical',
            abbr => 'cylind',
        },
        proj => {
            key => 'proj',
            val => 'electron',
            cmt => $phits->Cmt->symb.' Projectile',
        },
        x_center => {
            key => 'x0',
            val => 0.0,
            cmt => $phits->Cmt->symb.' x-center coordinate',
        },
        y_center => {
            key => 'y0',
            val => 0.0,
            cmt => $phits->Cmt->symb.' y-center coordinate',
        },
        rad => {
            key         => 'r0',
            flag        => 'rad',
            val_fixed   => 0.3,
            vals_of_int => [map $_ /= 10, 1..5],
            cmt         => $phits->Cmt->symb.' Radius',
        },
        z_beg => {
            key => 'z0',
            val => -5.0,
            cmt => $phits->Cmt->symb.' z-beginning coordinate',
        },
        z_end => {
            key => 'z1',
            val => -5.0,
            cmt => $phits->Cmt->symb.' z-ending coordinate',
        },
        t_cross_intact => {
            z_beg => -5.0 + 1,  # Based on {z_beg}{val}
            z_end => -5.0 + 1 + 1e-7,
        },
        dir => {
            key => 'dir',
            val => 1.0,
            cmt => $phits->Cmt->symb.' z-axis angle in arccosine',
        },
    );
    # <<
    # >> Dump source
    # Effective only when the dump mode is turned on via cmd-line opt.
    $phits->source->set_dump(
        type => {
            key  => 's-type',
            val  => 17,
            cmt  => $phits->Cmt->symb.' Dump source',
            abbr => 'dump',
        },
        # Dump filename
        file => {
            key => 'file',
            val => '',  # To be defined
        },
    );
    # <<
    # PHITS cell materials
    # > To make new materials available, do:
    #   (1) Check if the new material is already registered in
    #       %_cell_mats_list below. If not, add a key-val pair
    #       by referring to the other existing pairs.
    #   (2) Associate the new material to the set_cell_mats_list() method.
    my %_cell_mats_list = (
        # None (no cell at all)
        none => {
            mat_id        => 777,
            mat_comp      => undef,
            mat_lab_name  => undef,
            mat_lab_size  => undef,
            mat_lab_color => undef,
            mass_dens     => undef,
            melt_pt       => undef,
            boil_pt       => undef,
            thermal_cond  => undef,
        },

        # Vacuum
        vac => {
            mat_id        => 0,  # Predefined ID for the "inner void"
            mat_comp      => undef,
            #---[mat name color] for T-Gshow and T-3Dshow tallies---#
            mat_lab_name  => 'Vacuum',
            mat_lab_size  => 1,
            mat_lab_color => '{1.000 0.100 1.000}',  # HSB color for light red
            #-------------------------------------------------------#
            mass_dens     => undef,
            melt_pt       => undef,
            boil_pt       => undef,
            thermal_cond  => undef,
        },

        # Gas
        air => {  # Dry air
            mat_id        => 1,
            mat_comp      => ' N 0.78 O 0.21 Ar 0.01',  # Ignore CO2 etc.
            mat_lab_name  => 'Air',
            mat_lab_size  => 1,
            mat_lab_color => '{0.250 0.100 1.000}',  # HSB color for light blue
            mass_dens     => 1.225e-3,  # g cm^-3
            melt_pt       => undef,
            boil_pt       => 78.8,
            thermal_cond  => 0.024,
        },
        h2 => {
            mat_id        => 10,
            mat_comp      => ' H 2',
            mat_lab_name  => 'H_\{2\}',
            mat_lab_size  => 1,
            mat_lab_color => '{1.000 0.100 1.000}',
            mass_dens     => 0.08988e-3,
            melt_pt       => 13.99,   # K
            boil_pt       => 20.271,  # K
            thermal_cond  => 0.1805,  # W m^-1 K^-1; used for MAPDL
        },
        he => {
            mat_id        => 20,
            mat_comp      => 'He 1',
            mat_lab_name  => 'He',
            mat_lab_size  => 1,
            mat_lab_color => '{1.000 0.200 1.000}',
            mass_dens     => 0.1786e-3,
            melt_pt       => 0.95,
            boil_pt       => 4.222,
            thermal_cond  => 0.1513,
        },

        # Liquid
        water => {
            mat_id        => 100,
            mat_comp      => ' H 2 O 1',
            mat_lab_name  => 'Water',
            mat_lab_size  => 1,
            mat_lab_color => '{0.250 0.300 1.000}',
            mass_dens     => 1.000,
            melt_pt       => 273.15,
            boil_pt       => 373.15,
            thermal_cond  => 0.0014,
        },

        #
        # Metals
        #
        # Material ID conventions for metals:
        # In the form of ZI, where Z stands for the atomic number and
        # I the ID of the chemical composition of the material.
        # e.g.
        # 420 for molybdenum metal
        # 421 for molybdenum(IV) oxide (MoO2; molybdenum dioxide)
        # 422 for molybdenum(VI) oxide (MoO3; molybdenum trioxide)
        #

        al => {
            mat_id        => 130,
            mat_comp      => 'Al 1',
            mat_lab_name  => 'Al_\{met\}',
            mat_lab_size  => 1,
            mat_lab_color => 'gray',
            mass_dens     => 2.7,
            melt_pt       => 933.47,
            boil_pt       => 2_743.15,
            thermal_cond  => 237,
        },

        mo => {
            mat_id        => 420,
            mat_comp      => 'Mo 1',
            mat_lab_name  => 'Mo_\{met\}',
            mat_lab_size  => 1,
            mat_lab_color => 'matblack',
            mass_dens     => 10.28,
            melt_pt       => 2_896.15,
            boil_pt       => 4_912.15,
            thermal_cond  => 138,
        },
        moo2 => {
            mat_id        => 421,
            mat_comp      => 'Mo 1 O 2',
            mat_lab_name  => 'MoO_\{2\}',
            mat_lab_size  => 1,
            mat_lab_color => 'darkred',
            mass_dens     => 6.47,
            melt_pt       => 1_373.15,
            boil_pt       => undef,
            thermal_cond  => undef,
        },
        moo3 => {
            mat_id        => 422,
            mat_comp      => 'Mo 1 O 3',
            mat_lab_name  => 'MoO_\{3\}',
            mat_lab_size  => 1,
            mat_lab_color => 'pastelblue',
            mass_dens     => 4.69,
            melt_pt       => 1_068.15,
            boil_pt       => 1_428.15,
            thermal_cond  => undef,
        },

        # Group 6 transition metals
        ta => {
            mat_id        => 730,
            mat_comp      => 'Ta 1',
            mat_lab_name  => 'Ta_\{met\}',
            mat_lab_size  => 1,
            mat_lab_color => 'darkgray',
            mass_dens     => 16.69,
            melt_pt       => 3_290.15,
            boil_pt       => 5_731.15,
            thermal_cond  => 57.5,
        },
        w => {
            mat_id        => 740,
            mat_comp      => ' W 1',
            mat_lab_name  => 'W_\{met\}',
            mat_lab_size  => 1,
            mat_lab_color => 'darkgray',
            mass_dens     => 19.25,
            melt_pt       => 3_695.15,
            boil_pt       => 6_203.15,
            thermal_cond  => 173,
        },
        ir => {
            mat_id        => 770,
            mat_comp      => 'Ir 1',
            mat_lab_name  => 'Ir_\{met\}',
            mat_lab_size  => 1,
            mat_lab_color => 'darkgray',
            mass_dens     => 22.56,
            melt_pt       => 2_719.15,
            boil_pt       => 4_403.15,
            thermal_cond  => 147,
        },
        pt => {
            mat_id        => 780,
            mat_comp      => 'Pt 1',
            mat_lab_name  => 'Pt_\{met\}',
            mat_lab_size  => 1,
            mat_lab_color => 'darkgray',
            mass_dens     => 21.45,
            melt_pt       => 2_041.45,
            boil_pt       => 4_098.15,
            thermal_cond  => 71.6,
        },
        au => {
            mat_id        => 790,
            mat_comp      => 'Au 1',
            mat_lab_name  => 'Au_\{met\}',
            mat_lab_size  => 1,
            mat_lab_color => 'orangeyellow',
            mass_dens     => 19.3,
            melt_pt       => 1_337.33,
            boil_pt       => 3_243.15,
            thermal_cond  => 318,
        },

        # Group 6 post-transition metals
        pb => {
            mat_id        => 820,
            mat_comp      => 'Pb 1',
            mat_lab_name  => 'Pb_\{met\}',
            mat_lab_size  => 1,
            mat_lab_color => 'matblack',
            mass_dens     => 11.34,
            melt_pt       => 600.61,
            boil_pt       => 2_022.15,
            thermal_cond  => 35.3,
        },
    );

    # Examine if a duplicate 'mat_id' exists.
    my %_seen = ();  # Must be initialized to an empty hash
    foreach my $mat (keys %_cell_mats_list) {
        $_seen{$_cell_mats_list{$mat}{mat_id}}++;
        if (
            $_seen{$_cell_mats_list{$mat}{mat_id}}
            and $_seen{$_cell_mats_list{$mat}{mat_id}} >= 2
        ) {
            croak(
                "'mat_id' => $_cell_mats_list{$mat}{mat_id} duplicated!\n".
                "Look up '%_cell_mats_list' and fix it.\n"
            );
        }
    }

    $bconv->set_cell_mats_list(
        # Group 6 transition metals
        ta => $_cell_mats_list{ta},
        w  => $_cell_mats_list{w},
        ir => $_cell_mats_list{ir},
        pt => $_cell_mats_list{pt},
        au => $_cell_mats_list{au},
        # Below can be used for integrated target systems, where
        # Mo is used as both a converter and as a Mo target.
        none => $_cell_mats_list{none},
        vac  => $_cell_mats_list{vac},
        air  => $_cell_mats_list{air},
    );

    $motar->set_cell_mats_list(
        mo   => $_cell_mats_list{mo},
        moo2 => $_cell_mats_list{moo2},
        moo3 => $_cell_mats_list{moo3},
        # Below are used for quantifying converter-escaping electrons.
        vac => $_cell_mats_list{vac},
        air => $_cell_mats_list{air},
        # Below is used for examining the photon stopping powers of materials.
        pb => $_cell_mats_list{pb},
    );

    $flux_mnt_up->set_cell_mats_list(
        au  => $_cell_mats_list{au},
        vac => $_cell_mats_list{vac},
        air => $_cell_mats_list{air},
    );

    $flux_mnt_down->set_cell_mats_list(
        au  => $_cell_mats_list{au},
        vac => $_cell_mats_list{vac},
        air => $_cell_mats_list{air},
    );

    $tar_wrap->set_cell_mats_list(
        al  => $_cell_mats_list{al},
        vac => $_cell_mats_list{vac},
        air => $_cell_mats_list{air},
    );

    $mc_space->set_cell_mats_list(
        vac   => $_cell_mats_list{vac},
        # Coolants
        air   => $_cell_mats_list{air},
        h2    => $_cell_mats_list{h2},
        he    => $_cell_mats_list{he},
        water => $_cell_mats_list{water},
    );

    $motar_ent->set_cell_mats_list(  # Nonmaterial space for dump file gen
        %{$mc_space->cell_mats_list}
    );

    # Set constraint user-input arguments.
    $phits->set_constraint_args(
        # Iteration geometries
        v_geom => [
            'height', 'hgt',
            'radius', 'rad',
            'bot_radius', 'bot_rad', 'brad',
            'top_radius', 'top_rad', 'trad',
            'gap',  # Converter-to-target distance
        ],
        # MC cell materials
        bconv_cell_mat         => [keys %{$bconv->cell_mats_list}        ],
        motar_cell_mat         => [keys %{$motar->cell_mats_list}        ],
        flux_mnt_up_cell_mat   => [keys %{$flux_mnt_up->cell_mats_list}  ],
        flux_mnt_down_cell_mat => [keys %{$flux_mnt_down->cell_mats_list}],
        tar_wrap_cell_mat      => [keys %{$tar_wrap->cell_mats_list}     ],
        motar_ent_cell_mat     => [keys %{$motar_ent->cell_mats_list}    ],
        mc_space_cell_mat      => [keys %{$mc_space->cell_mats_list}     ],
        # Tally particles
        tally_particles => [
            'electron',
            'photon',
            'neutron',
        ],
    );

    # PHITS tallies
    $t_track->set_flag('track');
    $t_cross->set_flag('cross');
    $t_cross_dump->set_flag('cross');
    $t_heat->set_flag('heat');
    $t_heat_mapdl->set_flag('heat');
    $t_gshow->set_flag('gshow');
    $t_3dshow->set_flag('3dshow');
    $t_tot_fluence->set_flag('fluence');
    $t_subtotal->set_flag('subtotal');
    $t_total->set_flag('total');
    $t_shared->set_flag('total');

    #
    # ANGEL
    #
    $angel->set_exe('angel.bat');
    $angel->Cmt->set_symb($phits->Cmt->symb);
    $angel->Cmt->set_borders(
        leading_symb => $angel->Cmt->symb,
        border_symbs => ['=', '-']
    );

    #
    # Linac
    #
    # List of available klystrons (As of 2018-07-31)
    # > thales_lband_tv2022b
    # > tetd_sband_e37307
    # > tetd_xband_e37113
    #
    $llinac->set_params(
        name            => 'L-band electron linac',
        # The following keys must be provided.
        rf_power_source => 'thales_lband_tv2022b',  # See the list above.
        peak_beam_nrg   => 30e+06,   # In eV; updated in inner_iterator.
                                     # Caution: This energy is used only for
                                     # calculating the beam powers,
                                     # but not used as the eg0 value of PHITS.
                                     # The eg0 value is designated by the user.
        peak_beam_curr  => 500e-03,  # In A.
                                     # This value, in contrast, is used as
                                     # multiplication factors for tallies.
    );
    $slinac->set_params(
        name            => 'S-band electron linac',
        rf_power_source => 'tetd_sband_e37307',
        peak_beam_nrg   => 35e+06,
        peak_beam_curr  => 340e-03,
    );
    $xlinac->set_params(
        name            => 'X-band electron linac:'.
                           ' Phys. Rev. Accel. Beams (20) p. 104701',
        rf_power_source => 'tetd_xband_e37113',
        peak_beam_nrg   => 35e+06,
        peak_beam_curr  => 130e-03,
    );

    #
    # Animating programs
    #
    $animate->set_exes(
        imagemagick => 'magick.exe',  # Legacy: 'convert.exe'
        ffmpeg      => 'ffmpeg.exe',
    );

    return;
}


sub particle_dependent_settings {
    # """Update attributes overridden in parse_argv()."""

    # Used for "toggling" ipnint, negs, and nucdata, but not for actual tallies
    $t_shared->set_particles_of_int(
        @{$t_track->particles_of_int},
        @{$t_cross->particles_of_int},
        @{$t_cross_dump->particles_of_int},
    );

    #
    # Part of 6. PHITS parameters section
    # -> Overridden in the parse_argv() subroutine
    #    if the values have been given by a user input.
    #
    $phits->set_params(
        ipnint  => {
            key => 'ipnint',
            val => (
                $t_shared->is_phot_of_int and
                $t_shared->is_neut_of_int
            ) ? 1 : 0,
            cmt => $phits->Cmt->symb.
                   ' [0] Off [1] Photonuclear reactions considered',
        },
        negs    => {
            key => 'negs',
            val => (
                $t_shared->is_elec_of_int or
                $t_shared->is_phot_of_int
            ) ? 1 : 0,
            cmt => $phits->Cmt->symb.
                   ' [0] Off '.
                   '[1] emin(12,13)=0.1,emin(14)=1e-3,dmax(12-14)=1e3',
        },
        nucdata => {
            key => 'nucdata',
            val => $t_shared->is_neut_of_int ? 1 : 0,
            cmt => $phits->Cmt->symb.
                   ' [0] Off [1] emin(2)=1e-10,dmax(2)=20 for neut calc',
        },
    );

    return;
}


sub default_run_settings {
    # """Default run settings: Almost all of the attributes defined in here
    # can be modified in parse_argv() via the user input file."""

    #
    # TOC: In the order of independence (i.e. the latter depends on the former)
    # 1. Controls         <= Independent
    # 2. PHITS cells      <= Independent
    # 3. PHITS source     <= Independent
    # 4. Linac            <= Independent
    # 5. PHITS tallies    <= Depends on 4. Linac
    # 6. PHITS parameters <= Depends on 5. Tally
    #

    #
    # Units
    # Dimensions: cm
    # Energy:     MeV
    #

    #
    # 1. Controls
    #
    $phits->Ctrls->set_switch('on');
    $phits->Ctrls->set_openmp(0);
    $mapdl->Ctrls->set_switch('off');
    $mapdl_of_macs->Ctrls->set_switch('off');
    $mapdl_of_macs_all->Ctrls->set_switch('off');
    $t_shared->Ctrls->set_shortname('on');
    $t_track->Ctrls->set_switch('on');
    $t_track->Ctrls->set_err_switch('off');
    $t_cross->Ctrls->set_switch('on');
    $t_heat->Ctrls->set_switch('off');
    $t_heat->Ctrls->set_err_switch('off');
    $t_gshow->Ctrls->set_switch('on');
    $t_3dshow->Ctrls->set_switch('on');
    $t_tot_fluence->Ctrls->set_switch('off');
    $angel->Ctrls->set_mute('on');
    $angel->Ctrls->set_switch('on');
    $angel->Ctrls->set_modify_switch('on');
    $angel->Ctrls->set_noframe_switch('on');
    $angel->Ctrls->set_nomessage_switch('on');
    $angel->Ctrls->set_nolegend_switch('off');
    $angel->Cmt->set_annot_type('geom');
    $angel->set_orientation('land');
    $angel->set_dim_unit('mm');
    $angel->set_cmin_track(1e-3);
    $angel->set_cmax_track(1e+0);
    $angel->set_cmin_heat(1e-1);
    $angel->set_cmax_heat(1e+2);
    $image->Ctrls->set_mute('on');
    $image->Ctrls->set_pdf_switch('on');
    $image->Ctrls->set_svg_switch('off');
    $image->Ctrls->set_emf_switch('off');
    $image->Ctrls->set_wmf_switch('off');
    $image->Ctrls->set_raster_dpi(150);
    $image->Ctrls->set_png_switch('off');
    $image->Ctrls->set_png_trn_switch('off');
    $image->Ctrls->set_jpg_switch('off');
    $animate->Ctrls->set_mute('off');
    $animate->Ctrls->set_raster_format('png');
    $animate->Ctrls->set_duration(5);
    $animate->Ctrls->set_gif_switch('off');
    $animate->Ctrls->set_mp4_switch('off');
    $animate->Ctrls->set_mp4_crf(18);  # 0 lossless, 51 worst. Choose 15--25.
    $animate->Ctrls->set_avi_switch('off');
    $animate->Ctrls->set_avi_kbps(1000);  # Max 1e3 at 4-kbps bitrate tolerance
    $yield->set_avg_beam_curr(15);  # uA
    $yield->set_end_of_irr(5/60);  # h
    $yield->set_unit('kBq');
    $yield_mo99->Ctrls->set_switch('on');
    $yield_mo99->Ctrls->set_pwm_switch('off');
    $yield_mo99->set_react_nucl_enri_lev(0.09744);  # Amount fraction
    $yield_mo99->set_num_of_nrg_bins(1_000);  # Energy bins of tally and xs
    $yield_mo99->FileIO->set_micro_xs_dir('./xs/endf');
    $yield_mo99->FileIO->set_micro_xs_dat('tendl2015_mo100_gn_mf3_t4.dat');
    $yield_mo99->set_micro_xs_interp_algo('csplines');
    $yield_au196->Ctrls->set_switch('off');
    $yield_au196->Ctrls->set_pwm_switch('off');
    $yield_au196->set_react_nucl_enri_lev(1.0000);
    $yield_au196->set_num_of_nrg_bins(1_000);
    $yield_au196->FileIO->set_micro_xs_dir('./xs/endf');
    $yield_au196->FileIO->set_micro_xs_dat('tendl2015_au197_gn_mf3_t4.dat');
    $yield_au196->set_micro_xs_interp_algo('csplines');

    #
    # 2. PHITS cells
    #

    # Bremsstrahlung converter
    # 'ta', 'w', 'ir', 'pt', 'au', 'vac', 'air', 'mo', 'pb'
    $bconv->set_cell_mat('w');
    # Ratio of converter density to theoretical density
    $bconv->set_dens_ratio(1.0000);  # [0,1]
    $bconv->set_iter_geoms(  # Geometric params for the inner iteration
        'height',
#        'radius',
#        'gap',
    );
    $bconv->set_height_fixed(0.20);  # z-vector
    $bconv->set_heights_of_int([map $_ /= 100, @{[20, 25, 30]}]);
    $bconv->set_radius_fixed(1.25);
    $bconv->set_radii_of_int([map $_ /= 100, @{[100, 125, 150]}]);
    $bconv->set_gap_fixed(1.30);
    $bconv->set_gaps_of_int([map $_ /= 100, @{[80, 105, 130]}]);

    # Molybdenum target
    # 'mo', 'moo2', 'moo3', 'vac', 'air', 'pb'
    $motar->set_cell_mat('mo');
    $motar->set_dens_ratio(1.0000);
    # Molybdenum target, RCC
    $motar_rcc->set_iter_geoms(
#        'height',
#        'radius',
    );
    $motar_rcc->set_height_fixed(0.50);
    $motar_rcc->set_heights_of_int([map $_ /= 100, @{[50, 75, 100]}]);
    $motar_rcc->set_radius_fixed(0.50);
    $motar_rcc->set_radii_of_int([map $_ /= 100, @{[50, 75, 100]}]);
    # Molybdenum target, TRC
    $motar_trc->set_iter_geoms(
#        'height',
#        'bot_radius',
#        'top_radius',
    );
    $motar_trc->set_height_fixed(0.50);
    $motar_trc->set_heights_of_int([map $_ /= 100, @{[50, 75, 100]}]);
    $motar_trc->set_bot_radius_fixed(0.10);
    $motar_trc->set_bot_radii_of_int([map $_ /= 100, @{[10, 25, 40]}]);
    $motar_trc->set_top_radius_fixed(0.60);
    $motar_trc->set_top_radii_of_int([map $_ /= 100, @{[50, 60, 70]}]);

    # Flux monitor, upstream
    $flux_mnt_up->set_cell_mat('au');        # 'au', 'vac', 'air'
    $flux_mnt_up->set_dens_ratio(1.0000);    # [0,1]
    $flux_mnt_up->set_height_fixed(0.0000);  # 0:none
    $flux_mnt_up->set_radius_fixed(0.5000);

    # Flux monitor, downstream
    $flux_mnt_down->set_cell_mat('au');
    $flux_mnt_down->set_dens_ratio(1.0000);
    $flux_mnt_down->set_height_fixed(0.0000);
    $flux_mnt_down->set_radius_fixed(0.5000);

    # Target wrap
    $tar_wrap->set_cell_mat('al');           # 'al', 'vac', 'air'
    $tar_wrap->set_dens_ratio(1.0000);       # [0,1]
    $tar_wrap->set_thickness_fixed(0.0012);  # 12 um

    # MC space
    $mc_space->set_cell_mat('air');     # 'vac', 'air', 'h2', 'he', 'water'
    $mc_space->set_dens_ratio(1.0000);  # [0,1]

    # Molybdenum target entrance; must be the same as $mc_space->cell_mat
    $motar_ent->set_cell_mat($mc_space->cell_mat);
    $motar_ent->set_dens_ratio($mc_space->dens_ratio);
    $motar_ent->set_height_fixed(1e-7);  # 1 nm

    #
    # 3. PHITS source
    #
    $phits->source->set_nrg_dist_of_int(  # Choose only one.
        $phits->source->gaussian_nrg
#        $phits->source->free_form_nrg
    );
    $phits->source->set_spat_dist_of_int(  # Choose only one.
        $phits->source->gaussian_xy
#        $phits->source->gaussian_xyz
#        $phits->source->cylindrical
    );
    $phits->source->set_iter_param(  # Choose only one.
        'eg0'       # gaussian_nrg
#        'xy_fwhms'  # gaussian_xy
#        'x_fwhm'    # gaussian_xyz
#        'y_fwhm'    # gaussian_xyz
#        'z_fwhm'    # gaussian_xyz
#        'rad'       # cylindrical
    );
    # Parameters corresponding to the default values chosen above
    $phits->source->set_eg0_val_fixed(35);
    $phits->source->set_eg0_vals_of_int([30, 35, 40]);
    $phits->source->set_xy_fwhms_val_fixed(0.45);
    $phits->source->set_xy_fwhms_vals_of_int([map $_ /= 100, @{[30, 45, 60]}]);

    #
    # 4. Linac
    #
    $elinac_of_int = $xlinac;

    #
    # 5. PHITS tallies
    #

    # Particle track tally
    $t_track->set_particles_of_int(
        'electron',
#        'positron',
        'photon',
        'neutron',
#        'proton',
    );
    $t_track->set_mesh_types(
        # A mesh is defined by
        # [1] The number of elements, and meshing points
        # [2] The number of elements, and the min and max meshing
        #     ranges. The elements are separated equally.
        # [3] The number of elements, and the min and max meshing
        #     ranges. The elements are separated logarithmically.
        # [4] The width, min and max coordinates of an element.
        #     The number of elements is automatically calculated.
        # [5] The width in logarithm, and min and max coordinates
        #     of an element.
        #     The number of elements is automatically calculated.
        x => 2,
        y => 2,
        z => 2,
        r => 2,
        e => 2,
    );
    $t_track->set_mesh_sizes(
        x => 200,
        y => 200,
        z => 200,
        e => 100,
    );
    $t_track->set_unit(
        # Dependent on tallies.
        # [1] cm^-2 source^-1
        #     A track length divided by the tallied volume.
        #     For mesh=xyz and mesh=r-z, volumes are
        #     automatically calculated.
        #     If mesh=reg is used, on the other hand, the volume
        #     must explicitly be provided via the volume command
        #     within the same tally section or via a separate
        #     volume section (phitar implements the latter method).
        # [2] cm^-2 MeV^-1 source^-1
        #     Obtained by dividing 'cm^-2 source^-1' by the energy mesh width.
        #     Can be used for "area under the curve":
        #     (cm^-2 MeV^-1 source^-1 == [2])*dE == (cm^-2 source^-1) == [1]
        #
        # When a tally file with the unit 'cm^-2 MeV^-1 source^-1' is passed to
        # calc_rn_yield(), that per-MeV unit is converted to 'cm^-2 source^-1'
        # by multiplying the energy mesh width ('edel' in the tally file).
        # That is, 'cm^-2 source^-1' is used for yield calculation after all.
        1
    );
    $t_track->set_factor(
        # Multiplication factor.
        # Only >1.0 appears in the input echo.
        val => 1.0,
        cmt => '',
    );
    $t_track->set_gshow(
        # 2D figure options
        # [0(d)] None of below
        # [1]    Cell boundary
        # [2]    Cell boundary + Material name
        # [3]    Cell boundary + Cell name
        # [4]    Cell boundary + Lattice name
        1
    );
    $t_track->set_cell_bnd(
        resol => 1.2,  # Cell boundary resolution factor. PHITS default: 1
        width => 1.0,  # Cell boundary width.             PHITS default: 0.5
    );
    $t_track->set_epsout(
        # eps file generation
        # [0(d)] Off
        # [1]    On
        # [2]    On with error bars when: [axis != xy, yz, xz, rz]
        0  # For phitar to modify ANGEL input files beforehand
    );
    $t_track->set_vtkout(
        # vtk file generation for ParaView
        # [0(d)] Off
        # [1]    On when: [mesh=xyz 'and' axis = xy, yz, or xz]
        0
    );

    # Surface-crossing tally
    $t_cross->set_particles_of_int(
        'electron',
#        'positron',
        'photon',
        'neutron',
#        'proton',
    );
    $t_cross->set_mesh_types(
        z => 2,
        r => 2,
        e => 2,
    );
    $t_cross->set_mesh_sizes(
        z => 1,  # Must be 1; $t_cross->mesh_sizes->{1} is used instead.
        r => 1,  # Must be 1; $t_cross->mesh_sizes->{1} is used instead.
        e => 100,
    );
    $t_cross->set_unit(
        # Dependent on tallies.
        # [1] cm^-2 source^-1
        # [2] cm^-2 MeV^-1 source^-1
        # Refer to the PHITS manual for other options.
        1
    );
    $t_cross->set_factor(
        val => 1.0,
        cmt => '',
    );
    $t_cross->set_output(
        # Dependent on tallies.
        # [current] Count the number of particles crossed the plane
        #           in question
        # [flux]    Count the number of particles crossed the plane
        #           in question and weight to [cos(theta)]^-1 where
        #           theta is the angle of the particle incident
        #           with respect to the normal vector of the plane.
        'flux'
    );
    $t_cross->set_epsout(0);

    # Surface-crossing tally: "dump source"
    $t_cross_dump->set_particles_of_int(
        # Choose only one at a time
        'electron'  # 'photon', 'neutron'
    );
    $t_cross_dump->set_mesh_types(
        # Key-val pairs
        e => 2,
    );
    $t_cross_dump->set_mesh_sizes(
        # Key-val pairs
        e => 500,
    );
    $t_cross_dump->set_unit(1);
    $t_cross_dump->set_output('flux');
    $t_cross_dump->set_epsout(0);

    # Heat tallies
    $t_heat->set_mesh_types(
        x => 2,
        y => 2,
        z => 2,
        r => 2,
    );
    $t_heat->set_mesh_sizes(
        x => 200,
        y => 200,
        z => 200,
        r => 100,
    );
    $t_heat->set_unit(
        # Dependent on tallies.
        # [0] Gy source^-1
        # [1] MeV cm^-3 source^-1
        # [2] MeV source^-1
        2
    );
    $t_heat->set_factor(
        val => (
            # MeV --> J
            #
            # 1 J == |-1 C| * 1 V == 6.242e+18  eV
            #                     == 6.242e+12 MeV
            #    1
            # == 1          J / 6.242e+12 MeV
            # == 1.602e-13  J / MeV
            # == (1e+06 * 1.602e-19) J / MeV
            (1e+06 * $phys->constants->{coulomb_per_elec})
        ),
        cmt => '  '.
               $phits->Cmt->symb.
               ' MeV --> J',
    );
    $t_heat->set_output(
        # Dependent on tallies.
        # Available options: heat, simple, and all
        'heat'
    );
    $t_heat->set_gshow(1);
    $t_heat->set_cell_bnd(
        resol => 1.2,
        width => 1.0,
    );
    $t_heat->set_epsout(0);
    $t_heat->set_vtkout(0);
    $t_heat->set_material('all');  # Overridden at inner_iterator()
    $t_heat->set_electron(
        # Energies transferred from electrons are calculated using:
        # [0(d)] Kerma factor of photons
        # [1]    Ionization loss of electrons
        1
    );

    # Heat tallies for MAPDL (an ANSYS module)
    $t_heat_mapdl->set_mesh_types(
        x => 2,
        y => 2,
        z => 2,
    );
    $t_heat_mapdl->set_mesh_sizes(
        # If set to be too large, PHITS stops running
        x => 100,
        y => 100,
        z => 20,
    );
    # Set the multiplication factor based on MeV cm^-3 source^-1
    $t_heat_mapdl->set_unit(1);
    $t_heat_mapdl->set_factor(
        # The product of 'unit=>1', (i), (ii), and (iii)
        # will be (only the units are shown for brevity):
        #
        # 'unit=>1' * (i):
        # (MeV cm^-3 source^-1)(J MeV^-1) == J cm^-3 source^-1
        #
        # (J cm^-3 source^-1) * (ii):
        # (J cm^-3 source^-1)(cm^3  m^-3) == (J m^-3 source^-1)
        #
        # (J m^-3 source^-1) * (iii):
        # (J m^-3 source^-1)(num_part s^-1) == J s^-1 m^-3
        #                                   == W m^-3
        val => (
            # (i) MeV --> J
            #
            # 1 J == |-1 C| * 1 V == 6.242e+18  eV
            #                     == 6.242e+12 MeV
            #    1
            # == 1          J / 6.242e+12 MeV
            # == 1.602e-13  J / MeV
            # == (1e+06 * 1.602e-19) J / MeV
            (1e+06 * $phys->constants->{coulomb_per_elec})

            # (ii) cm^-3 --> m^-3
            * 1e+06

            # (iii) Number of source particles per second
            * (
                $elinac_of_int->avg_beam_curr           # C s^-1
                / $phys->constants->{coulomb_per_elec}  # C source^-1
            )
        ),
        cmt => '  '.
               $phits->Cmt->symb.
               ' W m^-3: MeV --> J, cm^-3 --> m^-3, source^-1 --> s^-1',
    );
    $t_heat_mapdl->set_output('heat');
    $t_heat_mapdl->set_two_dim_type(
        # [3(d)] ANGEL 2D figure
        # [4   ] Columnar data for the ang_to_mapdl_tab routine of PHITS.pm
        4
    );
    $t_heat_mapdl->set_gshow(1);
    $t_heat_mapdl->set_epsout(0);
    $t_heat_mapdl->set_vtkout(0);
    $t_heat_mapdl->set_material('all');
    $t_heat_mapdl->set_electron(1);

    # Gshow tallies
    $t_gshow->set_mesh_types(
        x => 2,
        y => 2,
        z => 2,
    );
    $t_gshow->set_mesh_sizes(
        x => 200,
        y => 200,
        z => 200,
    );
    $t_gshow->set_output(
        # Drawing options
        # [1] Cell boundary
        # [2] Cell boundary + Material color
        # [3] Cell boundary + Material name
        # [4] Cell boundary + Material color + Material name
        # [5] Cell boundary + Cell name
        # [6] Cell boundary + Material color + Cell name
        # [7] Cell boundary + Lattice name
        # [8] Cell boundary + Material color + Lattice name
        2
    );
    $t_gshow->set_cell_bnd(
        resol => 1.2,  # Cell boundary resolution factor. PHITS default: 1
        width => 1.0,  # Cell boundary width.             PHITS default: 0.5
    );
    $t_gshow->set_epsout(1);
    $t_gshow->set_vtkout(0);

    # 3Dshow tallies
    $t_3dshow->set_output(
        # Drawing options
        # [0] Draft
        # [1] Cell boundary
        # [2] No cell boundary
        # [3] Cell boundary + Color
        3
    );
    $t_3dshow->set_material('all');          # Overridden at inner_iterator()
    $t_3dshow->set_material_cutaway('all');  # Overridden at inner_iterator()
    $t_3dshow->set_origin(  # The origin of the object to be rendered
        x  => 0,
        y  => 0,
        # z corresponds to a polar angle.
        z1 => 0.5,  # Left-to-right beam view
        z2 => 0.5,  # Right-to-left beam view
    );
    $t_3dshow->set_frame(  # Referred to as a window in the PHITS manual
        width          => 5,
        height         => 5,
        distance       => 5,
        # Increase the numbers of meshes to reduce image loss.
        wdt_num_meshes => 500,
        hgt_num_meshes => 500,
        angle          => 0,
    );
    $t_3dshow->set_eye(  # The point of the observer
        polar_angle1  => 70,
        polar_angle2  => -70,
        azimuth_angle => 0,
        distance      => $t_3dshow->frame->{distance} * 20,  # PHITS dflt: *10
    );
    $t_3dshow->set_light(  # The point from which light is shone
        polar_angle1  => $t_3dshow->eye->{polar_angle1},
        polar_angle2  => $t_3dshow->eye->{polar_angle2},
        azimuth_angle => $t_3dshow->eye->{azimuth_angle},
        distance      => $t_3dshow->eye->{distance},
        # Shadow level
        # [0(d)] No shadow
        # Recommended: 2
        shadow        => 2,
    );
    $t_3dshow->set_axis(
        # Upper direction on a 2D plane
        to_sky    => '-y',
        # [0]    No coordinate frame
        # [1(d)] Small coordinate frame at the bottom left
        # [2]    Large coordinate frame at the center
        crd_frame => 1,
    );
    $t_3dshow->set_cell_bnd(
        resol => 1.2,
        width => 1.0,
        # T-3Dshow line parameter
        # Effective only when output == 1 || 3.
        # [0(d)] Material boundary + Surface boundary
        # [1]    Material boundary + Surface boundary + Cell boundary
        line  => 0,
    );
    $t_3dshow->set_epsout(1);

    # Shared tally settings
    $t_shared->set_offsets(  # Figure range offsets
        x => 2,
        y => 2,
        z => 2,
    );

    #
    # 6. PHITS parameters
    #

    # Part of the PHITS parameters whose values are affected by
    # the particles of interest. Have been separated to allow
    # user-defined overriding. For details,
    # see the sections 5 and 6 of the parse_argv() subroutine.
    particle_dependent_settings();

    $phits->set_params(
        icntl   => {
            key => 'icntl',
            val => 0,
            cmt => $phits->Cmt->symb.
                   ' [0] MC run [7] Gshow [11] 3Dshow',
        },
        istdev  => {
            key => 'istdev',
            val => 0,
            cmt => $phits->Cmt->symb.
                   ' [0] Off [-1] Recalculate from the last batch',
        },
        maxcas  => {
            key => 'maxcas',
            val => 1000,
            cmt => $phits->Cmt->symb.
                   ' Number of histories per batch',
        },
        maxbch  => {
            key => 'maxbch',
            val => 10,
            cmt => $phits->Cmt->symb.
                   ' Number of batches',
        },
        # Calculation cutoff minimum energies; must be >=esmin.
        emin => {
            prot => {
                key => 'emin(1)',  # esmin: 1.0000000e-03
                cmt => $phits->Cmt->symb.
                       ' [D=1e+00   ] Cutoff: Proton',
            },
            neut => {
                key => 'emin(2)',
                cmt => $phits->Cmt->symb.
                       ' [D=1e+00   ] Cutoff: Neutron',
            },
            elec => {
                key => 'emin(12)',  # esmin: 5.4461935e-07
                cmt => $phits->Cmt->symb.
                       ' [D=1e+09   ] Cutoff: Electron',
            },
            posi => {
                key => 'emin(13)',  # esmin: 5.4461935e-07
                cmt => $phits->Cmt->symb.
                       ' [D=1e+09   ] Cutoff: Positron',
            },
            phot => {
                key => 'emin(14)',
                cmt => $phits->Cmt->symb.
                       ' [D=1e+09   ] Cutoff: Photon',
            },
        },
        # Nuclear data maximum energies; must be <=esmax.
        dmax => {
            prot => {
                key => 'dmax(1)',
                cmt => $phits->Cmt->symb.
                       ' [D=emin(1) ] Nucl data max: Proton',
            },
            neut => {
                key => 'dmax(2)',
                cmt => $phits->Cmt->symb.
                       ' [D=emin(2) ] Nucl data max: Neutron',
            },
            elec => {
                key => 'dmax(12)',
                cmt => $phits->Cmt->symb.
                       ' [D=emin(12)] Nucl data max: Electron',
            },
            posi => {
                key => 'dmax(13)',
                cmt => $phits->Cmt->symb.
                       ' [D=emin(13)] Nucl data max: Positron',
            },
            phot => {
                key => 'dmax(14)',
                cmt => $phits->Cmt->symb.
                       ' [D=emin(14)] Nucl data max: Photon',
            },
        },
        # Output options
        ipcut => {
            key => 'ipcut',
            val => 0,
            cmt => $phits->Cmt->symb.
                   ' [0] Off [1] Out [2] Out with time',
        },
        incut => {
            key => 'incut',
            val => 0,
            cmt => $phits->Cmt->symb.
                   ' [0] Off [1] Out [2] Out with time',
        },
        igcut => {
            key => 'igcut',
            val => 0,
            cmt => $phits->Cmt->symb.
                   ' [0] Off [1] Out '.
                   '[2] Out with time [3] Out gamma,elec,posi',
        },
        file => {
            phits_dname => {
                key => 'file(1)',
                val => 'c:/phits',
                cmt => $phits->Cmt->symb.
                       ' PHITS dir; sets file(7,20,21,24,25)',
                swc => 1
            },
            marspf_inp_fname => {
                key => 'file(4)',
                val => 'marspf.in',
                cmt => $phits->Cmt->symb.
                       ' Used for icntl=4.'
            },
            summary_out_fname => {
                key => 'file(6)',
                val => 'phits.out',
                cmt => $phits->Cmt->symb.
                       ' Simulation summary'
            },
            xs_dname => {
                key => 'file(7)',
                val => 'c:/phits/data/xsdir.jnd',
                cmt => $phits->Cmt->symb.
                       ' xs dir'
            },
            nucl_react_out_fname => {
                key => 'file(11)',
                val => 'nuclcal.out',
                cmt => $phits->Cmt->symb.
                       ' Nuclear reaction'
            },
            cut_neut_out_fname => {
                key => 'file(12)',
                val => 'fort.12',
                cmt => $phits->Cmt->symb.
                       ' Cut-offed neutrons'
            },
            cut_gamm_out_fname => {
                key => 'file(13)',
                val => 'fort.13',
                cmt => $phits->Cmt->symb.
                       ' Cut-offed gammas'
            },
            cut_prot_out_fname => {
                key => 'file(10)',
                val => 'fort.10',
                cmt => $phits->Cmt->symb.
                       ' Cut-offed protons'
            },
            dumpall_fname => {
                key => 'file(15)',
                val => 'dumpall.dat',
                cmt => $phits->Cmt->symb.
                       ' fname for dumpall=1'
            },
            ivoxel_fname => {
                key => 'file(18)',
                val => 'voxel.bin',
                cmt => $phits->Cmt->symb.
                       ' fname for ivoxel=1,2'
            },
            egs5_xs_dname => {
                key => 'file(20)',
                val => 'c:/phits/XS/egs/',
                cmt => $phits->Cmt->symb.
                       ' xs dir for negs=1'
            },
            dchain_xs_dname => {
                key => 'file(21)',
                val => 'c:/phits/dchain-sp/data/',
                cmt => $phits->Cmt->symb.
                       ' xs dir for DCHAIN-SP'
            },
            curr_bat_fname => {
                key => 'file(22)',
                val => 'batch.out',
                cmt => $phits->Cmt->symb.
                       ' Current batch'
            },
            # Standing for preprocessor for EGS,
            # PEGS generates material datasets for EGS5.
            pegs5_out_fname => {
                key => 'file(23)',
                val => 'pegs5',
                cmt => $phits->Cmt->symb.
                       ' PEGS5'
            },
            decdc_dname => {
                key => 'file(24)',
                val => 'c:/phits/data',
                cmt => $phits->Cmt->symb.
                       ' dir for DECDC data (RIsource.dat)'
            },
            track_xs_dname => {
                key => 'file(25)',
                val => 'c:/phits/XS/tra',
                cmt => $phits->Cmt->symb.
                       ' xs dir for track-structure analysis'
            },
        },
    );

    return;
}


sub parse_inp {
    # """Input file parser"""
    my $run_opts_href = shift;

    # Below is preferred to using symbolic references.
    my %_switch_holders = (
        # (key) Strings
        # (val) Moose objects
        phits             => $phits,
        mapdl             => $mapdl,
        mapdl_of_macs     => $mapdl_of_macs,
        mapdl_of_macs_all => $mapdl_of_macs_all,
        t_shared          => $t_shared,
        t_track           => $t_track,
        t_cross           => $t_cross,
        t_heat            => $t_heat,
        t_gshow           => $t_gshow,
        t_3dshow          => $t_3dshow,
        t_tot_fluence     => $t_tot_fluence,
        angel             => $angel,
        image             => $image,
        img               => $image,  # Alias of image
        animate           => $animate,
        yield             => $yield,
        yield_mo99        => $yield_mo99,
        yield_au196       => $yield_au196,
    );
    my %_mc_cells = (
        bconv         => $bconv,      # Defines bremss conv mat and geom
        motar         => $motar,      # Defines mo target mat
        motar_rcc     => $motar_rcc,  # Defines mo target geom
        motar_trc     => $motar_trc,  # Defines mo target geom
        mc_space      => $mc_space,   # MC calculation space
        # Auxiliary materials for experiments
        flux_mnt_up   => $flux_mnt_up,
        flux_mnt_down => $flux_mnt_down,
        tar_wrap      => $tar_wrap,
    );
    my $_mc_cell;
    my %_linacs = (
        lband  => $llinac,
        sband  => $slinac,
        xband  => $xlinac,
    );
    my %_tallies = (
        t_track      => $t_track,
        t_cross      => $t_cross,
        t_cross_dump => $t_cross_dump,
        t_heat       => $t_heat,
        t_heat_mapdl => $t_heat_mapdl,
        t_gshow      => $t_gshow,
        t_3dshow     => $t_3dshow,
        t_shared     => $t_shared,
    );

    # Key-val holders
    my ($key, $subkey, $val, @dict_val, $cmt);
    my $obj_attr_delim = $parser->Data->delims->{obj_attr};  # For regexes

    # Begin parsing the input file.
    open my $inp_fh, '<', $run_opts_href->{inp};
    foreach my $line (<$inp_fh>) {
        #
        # TOC ... the same as default_run_settings()
        # 1. Controls
        # 2. PHITS cells
        # 3. PHITS source
        # 4. Linac
        # 5. PHITS tallies
        # 6. PHITS parameters
        #

        # Initializations
        @{$parser->Data->list_val} = undef;

        chomp($line);
        $line =~ s/\s*#.*//;        # Remove a comment.
        next if $line =~ /^(#|$)/;  # Skip comment or blank lines.

        # Split the key and value.
        $key = (split $parser->Data->delims->{key_val}, $line)[0];
        $val = (split $parser->Data->delims->{key_val}, $line)[1];

        # Preprocess the lines.
        rm_space(\$key);
        rm_space(\$val)            if $val and not $val =~ /["']/;
        rm_space(\$val, 'surr')    if $val and $val =~ /["']/;
        rm_quotes(\$val)           if $val and $val =~ /["']/;
        solidus_as_division(\$val) if $val and $val =~ /
            \b [0-9.]+\s* \/ \s*[0-9.]+ \b
        /x;

        #+++++debugging+++++#
#        say "\$line: |$line|";
#        say "\$key: |$key|";
#        say "\$val: |$val|";
        #-------------------#

        #
        # 1. Controls
        #

        # Switches
        if ($key =~ /^\w+(?:$obj_attr_delim)(\w+$obj_attr_delim)*switch/i) {
            $key =~ s/\w+\K(?:$obj_attr_delim)switch//i;

            # Keys having subkeys (i.e. having more than one $obj_attr_delim)
            if ($key =~ /$obj_attr_delim/) {
                ($subkey = $key) =~ s/(\w+)$obj_attr_delim(\w+)/$2/;
                $key             =~ s/(\w+)$obj_attr_delim(\w+)/$1/;
                # $t_shared only
                if ($subkey =~ /short_?(name)?/i) {
                    $_switch_holders{$key}->Ctrls->set_shortname($val);
                }
                # $angel, $image, $animate
                if ($subkey =~ /mute/i) {
                    $_switch_holders{$key}->Ctrls->set_mute($val);
                }
                # $angel only
                if ($key =~ /angel/i) {
                    if ($subkey =~ /mod(ify)?\b/i) {
                        $angel->Ctrls->set_modify_switch($val);
                    }
                    if ($subkey =~ /nofr(?:ame)?\b/i) {
                        $angel->Ctrls->set_noframe_switch($val);
                    }
                    if ($subkey =~ /no(?:message|ms(?:g)?)\b/i) {
                        $angel->Ctrls->set_nomessage_switch($val);
                    }
                    if ($subkey =~ /no(?:legend|lg)\b/i) {
                        $angel->Ctrls->set_nolegend_switch($val);
                    }
                }
                # $image only
                if ($key =~ /image|img/i) {
                    if ($subkey =~ /pdf/i) {
                        $image->Ctrls->set_pdf_switch($val);
                    }
                    if ($subkey =~ /svg/i) {
                        $image->Ctrls->set_svg_switch($val);
                    }
                    if ($subkey =~ /emf/i) {
                        $image->Ctrls->set_emf_switch($val);
                    }
                    if ($subkey =~ /wmf/i) {
                        $image->Ctrls->set_wmf_switch($val);
                    }
                    if ($subkey =~ /png\b/i) {
                        $image->Ctrls->set_png_switch($val);
                    }
                    if ($subkey =~ /png_(trn|tomei)/i) {
                        $image->Ctrls->set_png_trn_switch($val);
                    }
                    if ($subkey =~ /jpe?g/i) {
                        $image->Ctrls->set_jpg_switch($val);
                    }
                }
                # $animate only
                if ($key =~ /animate/i) {
                    if ($subkey =~ /gif/i) {
                        $animate->Ctrls->set_gif_switch($val);
                    }
                    if ($subkey =~ /mp4/i) {
                        $animate->Ctrls->set_mp4_switch($val);
                    }
                    if ($subkey =~ /avi/i) {
                        $animate->Ctrls->set_avi_switch($val);
                    }
                }
            }
            # For those without subkeys
            else {
                $_switch_holders{$key}->Ctrls->set_switch($val);
            }
        }

        # PWM switch for the $yield_<..> objects
        if ($key =~ /^yield_.*(?:$obj_attr_delim)pwm_switch/i) {
            $key =~ s/\w+\K(?:$obj_attr_delim)pwm_switch//i;
            $_switch_holders{$key}->Ctrls->set_pwm_switch($val);
        }

        # Error switches for T-Track and T-Heat
        if ($key =~ /^t_.*(?:$obj_attr_delim)err_switch/i) {
            $key =~ s/\w+\K(?:$obj_attr_delim)err_switch//i;
            $_switch_holders{$key}->Ctrls->set_err_switch($val);
        }

        # Switch-like setter $phits
        if ($key =~ /^phits(?:$obj_attr_delim)o(?:pen)?mp/i) {
            $phits->Ctrls->set_openmp($val);
        }

        # Switch-like setter of $angel
        if ($key =~ /^angel(?:$obj_attr_delim)annot_type/i) {
            $angel->Cmt->set_annot_type($val);
        }
        if ($key =~ /^angel(?:$obj_attr_delim)orientation/i) {
            $angel->set_orientation($val);
        }
        if ($key =~ /^angel(?:$obj_attr_delim)dim_unit/i) {
            $angel->set_dim_unit($val);
        }
        if ($key =~ /^angel(?:$obj_attr_delim)cmin_track/i) {
            $angel->set_cmin_track($val);
        }
        if ($key =~ /^angel(?:$obj_attr_delim)cmax_track/i) {
            $angel->set_cmax_track($val);
        }
        if ($key =~ /^angel(?:$obj_attr_delim)cmin_heat/i) {
            $angel->set_cmin_heat($val);
        }
        if ($key =~ /^angel(?:$obj_attr_delim)cmax_heat/i) {
            $angel->set_cmax_heat($val);
        }

        # Switch-like setter of $image
        if ($key =~ /^(?:image|img)(?:$obj_attr_delim)raster_dpi/i) {
            $image->Ctrls->set_raster_dpi($val);
        }

        # Switch-like setters of $animate
        if ($key =~ /^animate(?:$obj_attr_delim)/i) {
            # Raster format to be animated
            if ($key =~ /raster/i) {
                $animate->Ctrls->set_raster_format($val)
            }
            # Animation duration in second
            if ($key =~ /duration/i) {
                $animate->Ctrls->set_duration($val);
            }
            # H.264 constant rate factor
            if ($key =~ /mp4(?:$obj_attr_delim)crf/i) {
                $animate->Ctrls->set_mp4_crf($val);
            }
            # MPEG-4 bitrate in kbit/s
            if ($key =~ /avi(?:$obj_attr_delim)kbps/i) {
                $animate->Ctrls->set_avi_kbps($val);
            }
        }

        # Yield attributes
        if ($key =~ /^yield[\w]*(?:$obj_attr_delim)/i) {

            #
            # Common
            #

            # Average beam current in microampere
            if ($key =~ /yield(?:$obj_attr_delim)avg_beam_curr/i) {
                $yield->set_avg_beam_curr($val);
            }
            # Irradiation time in hour
            if ($key =~ /yield(?:$obj_attr_delim)end_of_irr/i) {
                $yield->set_end_of_irr($val);
            }
            # Yield unit
            if ($key =~ /yield(?:$obj_attr_delim)unit/i) {
                $yield->set_unit($val);
            }

            #
            # Radionuclides
            #
            (my $rn = $key) =~ s/^yield[\w]*\K(?:$obj_attr_delim).*//i;

            # Reactant nuclide enrichment level
            if ($key =~ /(?:$obj_attr_delim)react_nucl_enri_lev/i) {
                $_switch_holders{$rn}->set_react_nucl_enri_lev($val);
            }
            # Number of energy bins used for MC and xs
            if ($key =~ /(?:$obj_attr_delim)num_of_nrg_bins/i) {
                $_switch_holders{$rn}->set_num_of_nrg_bins($val);
            }
            # Microscopic xs directory
            if ($key =~ /(?:$obj_attr_delim)micro_xs_dir/i) {
                $_switch_holders{$rn}->FileIO->set_micro_xs_dir($val);
            }
            # Microscopic xs data
            if ($key =~ /(?:$obj_attr_delim)micro_xs_dat/i) {
                $_switch_holders{$rn}->FileIO->set_micro_xs_dat($val);
            }
            # Microscopic xs data interpolation algorithm (gnuplot smooth opt)
            if ($key =~ /(?:$obj_attr_delim)micro_xs_interp_algo/i) {
                $_switch_holders{$rn}->set_micro_xs_interp_algo($val);
            }
        }

        #
        # 2. PHITS cells
        #
        if (first { $key =~ /$_$obj_attr_delim/i } keys %_mc_cells) {
            # e.g.
            # $key      => bconv.radius_fixed
            # $val      => 1
            # $_mc_cell => bconv
            $_mc_cell = (split $obj_attr_delim, $key)[0];

            # Cell materials
            # > Bremsstrahlung converter
            # > Molybdenum target
            # > Flux monitors
            # > Target wrap
            # > MC space
            if ($key =~ /mat(erial)?/i) {
                # Validate the material.
                my $_passed = first { /\b$val\b/i }
                    @{$phits->constraint_args->{$_mc_cell.'_cell_mat'}};
                unless ($_passed) {
                    croak(
                        "[$val] is not an allowed material for [$_mc_cell].\n".
                        "Input one of these: [".join(
                            ', ',
                            @{$phits->constraint_args->{$_mc_cell.'_cell_mat'}}
                        )."]\n"
                    );
                }
                # Assign the material.
                $_mc_cells{$_mc_cell}->set_cell_mat("\L$val");
            }

            # Ratio between material density and theoretical density
            # > Or, dens_{mat} / dens_{theo}
            # > Necessary for real targets used in experiments
            if ($key =~ /dens_ratio/i) {
                $_mc_cells{$_mc_cell}->set_dens_ratio($val);
            }

            # Geometric parameters for inner iteration
            if ($key =~ /iter(ation)?_geoms/i) {
                $_mc_cells{$_mc_cell}->set_iter_geoms(
                    $val ? (split $parser->Data->delims->{list_val}, $val) :
                        undef  # Empty arg: for skipping iteration
                );
            }

            # Fixed height
            if ($key =~ /height_fixed/i) {
                $_mc_cells{$_mc_cell}->set_height_fixed($val);
            }

            # Heights of interest
            if ($key =~ /heights_of_int/i) {
                @{$parser->Data->list_val} =
                    split $parser->Data->delims->{list_val}, $val;
                construct_range($parser->Data->list_val, \$line);
                $_mc_cells{$_mc_cell}->set_heights_of_int(
                    $parser->Data->list_val
                );
            }

            # Fixed radius
            if (
                $_mc_cell =~ /bconv|motar_rcc|flux_mnt_(?:up|down)/i
                and $key =~ /radius_fixed/i
            ) {
                $_mc_cells{$_mc_cell}->set_radius_fixed($val);
            }
            elsif ($_mc_cell =~ /motar_trc/i and $key =~ /bot_radius_fixed/i) {
                $_mc_cells{$_mc_cell}->set_bot_radius_fixed($val);
            }
            elsif ($_mc_cell =~ /motar_trc/i and $key =~ /top_radius_fixed/i) {
                $_mc_cells{$_mc_cell}->set_top_radius_fixed($val);
            }

            # Radii of interest
            if ($key =~ /radii_of_int/i) {
                @{$parser->Data->list_val} =
                    split $parser->Data->delims->{list_val}, $val;
                construct_range($parser->Data->list_val, \$line);
                if ($_mc_cell =~ /bconv|motar_rcc/i) {
                    $_mc_cells{$_mc_cell}->set_radii_of_int(
                        $parser->Data->list_val
                    );
                }
                elsif ($_mc_cell =~ /motar_trc/i and $key =~ /bot_/i) {
                    $_mc_cells{$_mc_cell}->set_bot_radii_of_int(
                        $parser->Data->list_val
                    );
                }
                elsif ($_mc_cell =~ /motar_trc/i and $key =~ /top_/i) {
                    $_mc_cells{$_mc_cell}->set_top_radii_of_int(
                        $parser->Data->list_val
                    );
                }
            }

            # Fixed gap
            if ($_mc_cell =~ /bconv/i and $key =~ /gap_fixed/i) {
                $_mc_cells{$_mc_cell}->set_gap_fixed($val);
            }

            # Gaps of interest
            if ($_mc_cell =~ /bconv/i and $key =~ /gaps_of_int/i) {
                @{$parser->Data->list_val} =
                    split $parser->Data->delims->{list_val}, $val;
                construct_range($parser->Data->list_val, \$line);
                $_mc_cells{$_mc_cell}->set_gaps_of_int(
                    $parser->Data->list_val
                );
            }

            # (target wrap) Fixed thickness
            if ($_mc_cell =~ /tar_wrap/i and $key =~ /thickness_fixed/i) {
                $_mc_cells{$_mc_cell}->set_thickness_fixed($val);
            }
        }

        #
        # 3. PHITS source
        #
        if ($key =~ /^source$obj_attr_delim/i) {
            $key =~ s/source$obj_attr_delim//i;

            # Energy distribution
            if ($key =~ /nrg_dist/i) {
                $phits->source->set_nrg_dist_of_int(
                    $val =~ /free(_form)?/i ?
                        $phits->source->free_form_nrg :
                        $phits->source->gaussian_nrg  # Default
                );
            }

            # Spatial distribution
            if ($key =~ /spat_dist/i) {
                $phits->source->set_spat_dist_of_int(
                    $val =~ /cylind/i       ? $phits->source->cylindrical :
                    $val =~ /gaussian_xyz/i ? $phits->source->gaussian_xyz :
                        $phits->source->gaussian_xy  # Default
                );
            }

            # Iteration parameter
            if ($key =~ /(iter|varying)_param/i) {
                # gaussian_xy
                if ($phits->source->spat_dist_of_int->{type}{val} == 13) {
                    $phits->source->set_iter_param(
                        $val =~ /eg0/i ? 'eg0' : 'xy_fwhms'
                    );
                }
                # gaussian_xyz
                if ($phits->source->spat_dist_of_int->{type}{val} == 3) {
                    $phits->source->set_iter_param(
                        $val =~ /eg0/i         ? 'eg0' :
                        $val =~ /z[\-_]?fwhm/i ? 'z_fwhm' :
                        $val =~ /y[\-_]?fwhm/i ? 'y_fwhm' :
                                                 'x_fwhm'
                    );
                }
                # cylindrical
                if ($phits->source->spat_dist_of_int->{type}{val} == 1) {
                    $phits->source->set_iter_param(
                        $val =~ /eg0/i ? 'eg0' : 'rad'
                    );
                }
            }

            # Energy distribution parameters
            # (i) gaussian_nrg
            if ($key =~ /gaussian_nrg/i) {
                ($subkey = $key) =~ s/(\w+)$obj_attr_delim(\w+)/$2/;
                $key             =~ s/(\w+)$obj_attr_delim(\w+)/$1/;
                if ($subkey =~ /\beg0\b/i) {
                    $phits->source->set_eg0_val_fixed($val);
                }
                if ($subkey =~ /eg0s_of_int/i) {
                    @{$parser->Data->list_val} =
                        split $parser->Data->delims->{list_val}, $val;
                    construct_range($parser->Data->list_val, \$line);
                    $phits->source->set_eg0_vals_of_int(
                        $parser->Data->list_val
                    );
                }
                if ($subkey =~ /fwhm/i) {
                    $phits->source->gaussian_nrg->{fwhm}{val} = $val;
                }
                if ($subkey =~ /lt_from_eg0/i) {
                    $phits->source->gaussian_nrg->{lt_from_eg0} = $val;
                }
                if ($subkey =~ /rt_from_eg0/i) {
                    $phits->source->gaussian_nrg->{rt_from_eg0} = $val;
                }
            }
            # (ii) free_form_nrg
            if ($key =~ /free_form_nrg/i) {
                ($subkey = $key) =~ s/(\w+)$obj_attr_delim(\w+)/$2/;
                $key             =~ s/(\w+)$obj_attr_delim(\w+)/$1/;
                if ($subkey =~ /file/i) {
                    $phits->source->free_form_nrg->{file} = $val;
                }
            }

            # Spatial distribution parameters
            # gaussian_xy: xy_fwhms only
            if ($key =~ /xy_fwhm_fixed/i) {
                $phits->source->set_xy_fwhms_val_fixed($val);
            }
            if ($key =~ /xy_fwhms_of_int/i) {
                @{$parser->Data->list_val} =
                    split $parser->Data->delims->{list_val}, $val;
                construct_range($parser->Data->list_val, \$line);
                $phits->source->set_xy_fwhms_vals_of_int(
                    $parser->Data->list_val
                );
            }

            # gaussian_xyz: x_fwhm, y_fwhm, and z_fwhm
            # x_fwhm
            if ($key =~ /x_fwhm_fixed/i) {
                $phits->source->set_x_fwhm_val_fixed($val);
            }
            if ($key =~ /x_fwhms_of_int/i) {
                @{$parser->Data->list_val} =
                    split $parser->Data->delims->{list_val}, $val;
                construct_range($parser->Data->list_val, \$line);
                $phits->source->set_x_fwhm_vals_of_int(
                    $parser->Data->list_val
                );
            }
            # y_fwhm
            if ($key =~ /\by_fwhm_fixed/i) {  # \b to skip 'xy_fwhm_fixed'
                $phits->source->set_y_fwhm_val_fixed($val);
            }
            if ($key =~ /\by_fwhms_of_int/i) {
                @{$parser->Data->list_val} =
                    split $parser->Data->delims->{list_val}, $val;
                construct_range($parser->Data->list_val, \$line);
                $phits->source->set_y_fwhm_vals_of_int(
                    $parser->Data->list_val
                );
            }
            # z_fwhm
            if ($key =~ /z_fwhm_fixed/i) {
                $phits->source->set_z_fwhm_val_fixed($val);
            }
            if ($key =~ /z_fwhms_of_int/i) {
                @{$parser->Data->list_val} =
                    split $parser->Data->delims->{list_val}, $val;
                construct_range($parser->Data->list_val, \$line);
                $phits->source->set_z_fwhm_vals_of_int(
                    $parser->Data->list_val
                );
            }

            # cylindrical: radius only
            if ($key =~ /rad_fixed/i) {
                $phits->source->set_rad_val_fixed($val);
            }
            if ($key =~ /radii_of_int/i) {
                @{$parser->Data->list_val} =
                    split $parser->Data->delims->{list_val}, $val;
                construct_range($parser->Data->list_val, \$line);
                $phits->source->set_rad_vals_of_int(
                    $parser->Data->list_val
                );
            }
        }

        #
        # 4. Linac
        #
        if ($key =~ /^linac$obj_attr_delim/i) {
            $key =~ s/linac$obj_attr_delim//i;

            if ($key =~ /$obj_attr_delim/) {  # for xband and sband
                ($subkey = $key) =~ s/(\w+)$obj_attr_delim(\w+)/$2/;
                $key             =~ s/(\w+)$obj_attr_delim(\w+)/$1/;
                if ($subkey =~ /rf_power_source/i) {
                    $_linacs{$key}->rf_power_source->_set_kly_params(
                        "\L$val"  # The klystron name must be all-lowercase
                                  # letters for hash access.
                    );
                }
                else {
                    my $_subkey_setter = 'set_'.$subkey;
                    $_linacs{$key}->$_subkey_setter($val);
                }
            }

            if ($key =~ /of_int/i) {
                $elinac_of_int = $_linacs{$val};

                # Create a key-val pair for the tally
                # factor setter in 5. PHITS tallies.
                #
                # This is because, even if 'of_int' is defined at the
                # declaration of %_tallies like
                # of_int => $elinac_of_int,
                # the address of this $elinac_of_int
                # differs from that of a newly set $elinac_of_int above,
                # which will be used later for setting tally factors.
                $_linacs{of_int} = $elinac_of_int;
            }
        }

        #
        # 5. PHITS tallies
        #
        if (first { $key =~ /$_$obj_attr_delim/i } keys %_tallies) {
            # Particles of interest
            if ($key =~ /particles_of_int/i) {
                $key =~ s/$obj_attr_delim(?:particles_of_int)//i;
                # String validation
                my @_vals = split $parser->Data->delims->{list_val}, $val
                    if $val;
                my $_passed;
                foreach my $_val (@_vals) {
                    last unless $val;
                    $_passed = first { /\b$_val\b/i }
                        @{$phits->constraint_args->{tally_particles}};
                    unless ($_passed) {
                        croak(
                            "[$_val] is not allowed for particles_of_int.\n".
                            "Input one of these: [".join(
                                ', ',
                                @{$phits->constraint_args->{tally_particles}}
                            )."]\n"
                        );
                    }
                }
                # Assign the particles of interest.
                $_tallies{$key}->set_particles_of_int(
                    $val ? (split $parser->Data->delims->{list_val}, $val) :
                           # {proj}{val}: electron
                           $phits->source->spat_dist_of_int->{proj}{val}
                );
                # Run the particle_dependent_settings() subroutine,
                # which contains "some" parameters of the section 6.
                # These "some" parameters have values dependent on
                # the particles of interest, examples including:
                # ipnint, negs, and nucdata.
                # They have been separated into
                # the particle_dependent_settings() subroutine
                # so that they can be overridden in the section 6
                # when a user input specifies the values.
                #--------------------------------------------------------------
                # Caution (as a log of debugging on 2018-08-15):
                #--------------------------------------------------------------
                # > The $t_shared->set_particles_of_int method in
                #   the particle_dependent_settings() subroutine
                #   works in a cumulative manner.
                # > For example, when t_track.particles_of_int
                #   is recognized by this parser, the statements
                #   of this conditional is executed,
                #   and so is the particle_dependent_settings() subroutine.
                # > The subroutine contains the setter method
                #   $t_shared->set_particles_of_int, which "partially"
                #   updates the particles of $t_shared using the particles
                #   of interest of the tallies at the time of its execution.
                # > Next, if t_track_spectra.particles_of_int
                #   is recognized by this parser, the statements
                #   of this conditional are again executed,
                #   and $t_shared->set_particles_of_int will again
                #   update its particles of interest, now with
                #   larger pieces of information:
                #   the particles of interest of $t_track_spectra
                #   in addition to the previously obtained
                #   particles of interest of $t_track.
                # > Accordingly, the particle_dependent_settings() subroutine
                #   must be inside this conditional to correctly update all
                #   the particles of interest of the tallies.
                particle_dependent_settings();
            }

            # Mesh sizes
            if ($key =~ /mesh_sizes/i) {
                $key =~ s/$obj_attr_delim(?:mesh_sizes)//i;
                foreach (split $parser->Data->delims->{list_val}, $val) {
                    push @dict_val, split $parser->Data->delims->{dict_val};
                }
                $_tallies{$key}->set_mesh_sizes(@dict_val) if @dict_val;
            }

            # Cell boundary resolution and width
            if ($key =~ /bnd_resol/i) {
                $key =~ s/$obj_attr_delim(?:bnd_resol)//i;
                $_tallies{$key}->cell_bnd->{resol} = $val;
            }
            if ($key =~ /bnd_width/i) {
                $key =~ s/$obj_attr_delim(?:bnd_width)//i;
                $_tallies{$key}->cell_bnd->{width} = $val;
            }

            # Units
            if ($key =~ /unit/i) {
                $key =~ s/$obj_attr_delim(?:unit)//i;
                $_tallies{$key}->set_unit($val);
            }

            # Factors
            if ($key =~ /factor/i) {
                next if not $val;

                $key =~ s/$obj_attr_delim(?:factor)//i;
                # (i) Based on a linac average current
                if ($val =~ /linac/i) {
                    $val =~ s/(?:linac)$obj_attr_delim//i;
                    $cmt = ($_linacs{$val}->avg_beam_curr * 1e+06).' uA';

                    $_tallies{$key}->set_factor(
                        val => (
                            $_linacs{$val}->avg_beam_curr           # C s^-1
                            / $phys->constants->{coulomb_per_elec}  # C src^-1
                        ),
                        cmt => '  '.$phits->Cmt->symb.' '.$cmt
                    );
                }

                # (ii) Based on a number
                else {
                    # If a comment has also been given:
                    if ($val =~ $parser->Data->delims->{dict_val}) {
                        # Split the value and the comment.
                        ($val, $cmt) =
                            split $parser->Data->delims->{dict_val}, $val;

                        # Assign the tally factor.
                        $_tallies{$key}->set_factor(
                            val => eval $val,
                            cmt => '  '.$phits->Cmt->symb.' '.$cmt
                        );
                    }

                    # If a comment has not been given:
                    else { $_tallies{$key}->set_factor(val => eval $val); }
                }
            }

            # Offsets: As of 2018-07-31, t_shared only.
            if ($key =~ /t_shared$obj_attr_delim(?:offsets)/i) {
                $key =~ s/$obj_attr_delim(?:offsets)//i;

                foreach (split $parser->Data->delims->{list_val}, $val) {
                    push @dict_val, split $parser->Data->delims->{dict_val};
                }

                $_tallies{$key}->set_offsets(
                    $val ? @dict_val : (  # Default values
                        x => 2,
                        y => 2,
                        z => 2
                    )
                );
            }
        }

        #
        # 6. PHITS parameters
        #    Parameters depending on the particles of interest
        #    are set following the tallies section.
        #    For details, see the section 5 above.
        #
        if ($key =~ /^params$obj_attr_delim/i) {
            $key =~ s/params$obj_attr_delim//i;

            # For emin and dmax
            if ($key =~ /$obj_attr_delim/) {
                ($subkey = $key) =~ s/(\w+)$obj_attr_delim(\w+)/$2/;
                $key             =~ s/(\w+)$obj_attr_delim(\w+)/$1/;
                $phits->params->{$key}{$subkey}{val} = $val;
            }
            # For others
            else {
                $phits->params->{$key}{val} = $val;
            }
        }
    }
    close $inp_fh;

    #
    # Update the linac attributes that may have been modified by this parser.
    #
    $elinac_of_int->update_params();

    return;
}


sub populate_gaussian_nrg_cutoffs {
    # """Populate the attributes of Gaussian energy cutoff values."""
    my $source_eg0 = $phits->source->gaussian_nrg->{eg0}{val_fixed};
    $source_eg0 = shift if @_;  # For varying center energies

    # Convert the user-given relative values to absolute eg2 and eg3 values.
    # > lt_from_eg0 (relative to center) to cutoff_min (absolute)
    # > rt_from_eg0 (relative to center) cutoff_max (absolute)
    $phits->source->gaussian_nrg->{cutoff_min}{val} = (
        $source_eg0  # Gaussian center energy, variable of fixed
        - $phits->source->gaussian_nrg->{lt_from_eg0}  # Fixed
    );
    $phits->source->gaussian_nrg->{cutoff_max}{val} = (
        $source_eg0
        + $phits->source->gaussian_nrg->{rt_from_eg0}  # Fixed
    );

    return;
}


sub populate_free_form_nrg_dist {
    # """Populate the attribute of free-form energy distribution."""

    # Check if the file can be seen from the CWD.
    my $_err_msg = sprintf(
        "[Source energy distribution No. %d: %s]\n".
        "[%s] NOT found from the CWD; terminating.\n\n",
        $phits->source->free_form_nrg->{type}{val},
        $phits->source->free_form_nrg->{type}{abbr},
        $phits->source->free_form_nrg->{file},
    );
    croak $_err_msg if not -e $phits->source->free_form_nrg->{file};

    # Calculate the number of energy bins, feed indentation, and
    # store the data into the 'ne' hash ref.
    # > The number of energy bins is stored into free_form_nrg->{ne}{val}.
    # > The energy distribution data are appended to free_form_nrg->{ne}{cmt}.
    #   > This is to conform to the construction method of [source] section:
    #     in constructing the [source] section, parameters are first stored
    #     as groups of three elements (key, val, and cmt) into array refs,
    #     which are then unpacked all at once using the map function.
    #     For details, look up "Source section".
    #   > This initial value of free_form_nrg->{ne}{cmt} is:
    #     $phits->Cmt->symb.' Number of energy bins'
    #     The energy distribution data will appear on the next line onward.
    my $ebin_first = 0;
    my $ebin_last  = 0;
    my $ne         = 0;
    my $idt        = " " x 4;
    $phits->source->free_form_nrg->{ne}{cmt}.= "\n";
    open my $free_form_nrg_fh, '<', $phits->source->free_form_nrg->{file};
    foreach (<$free_form_nrg_fh>) {
        if (not /^$/) {
            $ebin_first = $_ if $ne == 0;
            $ebin_last  = $_;
            $ne++;
        }
        s/^\s+//;  # Remove, if any, leading spaces for consistent use of $idt.
        $_ = $idt.$_;
        $phits->source->free_form_nrg->{ne}{cmt} .= $_;
    }
    close $free_form_nrg_fh;
    chomp($phits->source->free_form_nrg->{ne}{cmt});  # Last newline chars
    $phits->source->free_form_nrg->{cutoff_min}{val} =
        (split(/\s+/, $ebin_first))[0];
    $phits->source->free_form_nrg->{cutoff_max}{val} =
        (split(/\s+/, $ebin_last))[1];
    $phits->source->free_form_nrg->{ne}{val} = $ne;

    return;
}


sub determ_tally_emin_emax {
    # """Determine the emin and emax of tallies."""

    #
    # Dependencies on $phits->source->nrg_dist_of_int->{cutoff_max}{val}
    # > $phits->source->set_nrg_dist_of_int() had been called beforehand
    #   in default_run_settings() and parse_inp() to choose between
    #   Gaussian and free-form energy distributions.
    # > According to which energy distribution is used,
    #   one of the following routines determines {cutoff_max}{val}:
    #   > populate_gaussian_nrg_cutoffs()
    #   > populate_free_form_nrg_dist()
    #
    my $src_emax = $phits->source->nrg_dist_of_int->{cutoff_max}{val};

    #
    # emin and emax for Mo-99 yields
    #

    # (1a) Pointwise emin for gnuplot smooth: Simply the first energy point
    my $_micro_xs_dat_mo99 = sprintf(
        "%s%s%s%s%s",
        $phits->cwd,
        $yield_mo99->FileIO->path_delim,
        $yield_mo99->FileIO->micro_xs_dir,
        $yield_mo99->FileIO->path_delim,
        $yield_mo99->FileIO->micro_xs_dat,
    );
    my $_pointwise_mo99_emin;
    open my $_micro_xs_dat_mo99_fh, '<', $_micro_xs_dat_mo99;
    foreach (<$_micro_xs_dat_mo99_fh>) {
        next if /^\s*#/;
        # Obtain the first energy point.
        if (/^\s*[0-9.]/) {
            chomp;
            ($_pointwise_mo99_emin = $_) =~ s/^\s*([0-9.]+)E.*/$1/i;
            last;
        }
    }
    close $_micro_xs_dat_mo99_fh;

    # (1b) Pointwise emax for gnuplot smooth
    my $_pointwise_mo99_emax = $src_emax;

    # (2) Interval emin and emax for PHITS tallies
    # > edel, which is the interval between e-lower and e-upper,
    #   is calculated here to calculate emin and emax,
    #   but is NOT used directly in PHITS tallies.
    # > Not passing edel to PHITS is to prevent PHITS from setting
    #   ne != $yield_mo99->num_of_nrg_bins, which can happen
    #   because of the handling of floating numbers.
    # > Instead, values of ne, emin, and emax (e-type = 2)
    #   are passed to PHITS, and then PHITS calculates edel.
    #   The resulting PHITS edel might be slightly different from
    #   the edel calculated here (up to around 1e-4 MeV),
    #   but because we pass 'ne' to PHITS, the same 'ne' between
    #   PHITS tallies and xs data is guaranteed, allowing
    #   pointwise multiplication.
    my $_e_start = $_pointwise_mo99_emin;
    my $_e_stop  = $src_emax;
    my $_interval_mo99_edel = (
        ($_e_stop - $_e_start)
        / ($yield_mo99->num_of_nrg_bins - 1)
    );
    my $_interval_mo99_emin = $_e_start - 0.5*$_interval_mo99_edel;
    my $_interval_mo99_emax = (
        $_interval_mo99_emin
        # Not ($yield_mo99->num_of_nrg_bins - 1) because
        # PHITS calculates energy ranges up to ne + 1, and
        # $yield_mo99->num_of_nrg_bins below is to be the ne + 1.
        + $yield_mo99->num_of_nrg_bins*$_interval_mo99_edel
    );

    #
    # emin and emax for Au-196 yields
    #

    # (1a) Pointwise emin for gnuplot smooth
    my $_micro_xs_dat_au196 = sprintf(
        "%s%s%s%s%s",
        $phits->cwd,
        $yield_au196->FileIO->path_delim,
        $yield_au196->FileIO->micro_xs_dir,
        $yield_au196->FileIO->path_delim,
        $yield_au196->FileIO->micro_xs_dat,
    );
    my $_pointwise_au196_emin;
    open my $_micro_xs_dat_au196_fh, '<', $_micro_xs_dat_au196;
    foreach (<$_micro_xs_dat_au196_fh>) {
        next if /^\s*#/;
        if (/^\s*[0-9.]/) {
            chomp;
            ($_pointwise_au196_emin = $_) =~ s/^\s*([0-9.]+)E.*/$1/i;
            last;
        }
    }
    close $_micro_xs_dat_au196_fh;

    # (1b) Pointwise emax for gnuplot smooth
    my $_pointwise_au196_emax = $src_emax;

    # (2) Interval emin and emax for PHITS tallies
    $_e_start = $_pointwise_au196_emin;
    $_e_stop  = $src_emax;
    my $_interval_au196_edel = (
        ($_e_stop - $_e_start)
        / ($yield_au196->num_of_nrg_bins - 1)
    );
    my $_interval_au196_emin = (2*$_e_start - $_interval_au196_edel) / 2;
    my $_interval_au196_emax = (
        $_interval_au196_emin
        + $yield_au196->num_of_nrg_bins*$_interval_au196_edel
    );

    #
    # Assign the determined emin and emax to T-Track and T-Cross tallies.
    #
    $t_track->set_mesh_ranges(
        emin => {
            lower_nrg_range => 0,  # For photoneutrons
            tot_nrg_range   => 0,  # For all particles
            eff_nrg_range_pointwise_mo99  => $_pointwise_mo99_emin,  # xs
            eff_nrg_range_pointwise_au196 => $_pointwise_au196_emin,
            eff_nrg_range_interval_mo99   => $_interval_mo99_emin,  # Fluence
            eff_nrg_range_interval_au196  => $_interval_au196_emin,
        },
        emin_cmt => {
            lower_nrg_range => '',
            tot_nrg_range   => '',
            eff_nrg_range_pointwise_mo99 => (
                '  '.$phits->Cmt->symb.
                ' Mo-100(g,n)Mo-99 threshold'
            ),
            eff_nrg_range_pointwise_au196 => (
                '  '.$phits->Cmt->symb.
                ' Au-197(g,n)Au-196 threshold'
            ),
            eff_nrg_range_interval_mo99 => (
                '  '.$phits->Cmt->symb.
                ' Mo-100(g,n)Mo-99 threshold - 0.5*edel'
            ),
            eff_nrg_range_interval_au196 => (
                '  '.$phits->Cmt->symb.
                ' Au-197(g,n)Au-196 threshold - 0.5*edel'
            ),
        },
        emax => {
            lower_nrg_range => ceil($src_emax / 8),
            tot_nrg_range   => $src_emax,
            eff_nrg_range_pointwise_mo99  => $_pointwise_mo99_emax,
            eff_nrg_range_pointwise_au196 => $_pointwise_au196_emax,
            eff_nrg_range_interval_mo99   => $_interval_mo99_emax,
            eff_nrg_range_interval_au196  => $_interval_au196_emax,
        },
        emax_cmt => {
            lower_nrg_range => (
                '  '.$phits->Cmt->symb.' ceil(emax of [source] / 8)'
            ),
            tot_nrg_range   => (
                '  '.$phits->Cmt->symb.' emax of [source]'
            ),
            eff_nrg_range_pointwise_mo99  => (
                '  '.$phits->Cmt->symb.' emax of [source]'
            ),
            eff_nrg_range_pointwise_au196 => (
                '  '.$phits->Cmt->symb.' emax of [source]'
            ),
            eff_nrg_range_interval_mo99 => (
                '  '.$phits->Cmt->symb.
                ' emin + ne*edel'
            ),
            eff_nrg_range_interval_au196 => (
                '  '.$phits->Cmt->symb.
                ' emin + ne*edel'
            ),
        },
        ymin => 1e-5,
        ymax => 1e-1,
    );

    $t_cross->set_mesh_ranges(
        emin => {
            lower_nrg_range => 0,
            tot_nrg_range   => 0,
            eff_nrg_range_pointwise_mo99 => $_pointwise_mo99_emin,
            eff_nrg_range_interval_mo99  => $_interval_mo99_emin,
        },
        emin_cmt => {
            lower_nrg_range => '',
            tot_nrg_range   => '',
            eff_nrg_range_pointwise_mo99 => (
                '  '.$phits->Cmt->symb.
                ' Mo-100(g,n)Mo-99 threshold'
            ),
            eff_nrg_range_interval_mo99  => (
                '  '.$phits->Cmt->symb.
                ' Mo-100(g,n)Mo-99 threshold - 0.5*edel'
            ),
        },
        emax => {
            lower_nrg_range => ceil($src_emax / 8),
            tot_nrg_range   => $src_emax,
            eff_nrg_range_pointwise_mo99 => $_pointwise_mo99_emax,
            eff_nrg_range_interval_mo99  => $_interval_mo99_emax,
        },
        emax_cmt => {
            lower_nrg_range => (
                '  '.$phits->Cmt->symb.' ceil(emax of [source] / 8)'
            ),
            tot_nrg_range   => (
                '  '.$phits->Cmt->symb.' emax of [source]'
            ),
            eff_nrg_range_pointwise_mo99 => (
                '  '.$phits->Cmt->symb.' emax of [source]'
            ),
            eff_nrg_range_interval_mo99 => (
                '  '.$phits->Cmt->symb.
                ' emin + ne*edel'
            ),
        },
        ymin => 1e-5,
        ymax => 1e-1,
    );

    $t_cross_dump->set_mesh_ranges(
        emin     => 0,  # Always 0 as it will be used as a particle source.
        emin_cmt => '',
        emax     => $src_emax,
        emax_cmt => '  '.$phits->Cmt->symb.' emax of [source]',
    );

    return;
}


sub populate_mc_cell_props {
    # """ Populate the attributes of MC cell properties."""

    #
    # List of Monte Carlo cells
    #
    # (1) Bremsstrahlung converter
    # (2) Molybdenum target
    # (3) Flux monitor
    # (4) Target wrap
    # (5) Molybdenum target entrance
    # (6) MC space: Inside
    # (7) MC space: Outside
    #

    #
    # (1) Bremsstrahlung converter
    #

    # Preprocessing
    $bconv->set_flag(
        $bconv->cell_mat.(
            $t_shared->Ctrls->shortname =~ /on/i ?
                '' : $phits->FileIO->fname_space
        ).'rcc'  # As of v1.01, only RCC is allowed.
    );

    # Setter
    $bconv->set_cell_props(
        cell_id => 10,
        #---Material-specific---#
        mat_id => $bconv->cell_mats_list->
            {$bconv->cell_mat}
            {mat_id},
        mat_comp => $bconv->cell_mats_list->
            {$bconv->cell_mat}
            {mat_comp},
        mat_lab_name => $bconv->cell_mats_list->
            {$bconv->cell_mat}
            {mat_lab_name},
        mat_lab_size => $bconv->cell_mats_list->
            {$bconv->cell_mat}
            {mat_lab_size},
        mat_lab_color => $bconv->cell_mats_list->
            {$bconv->cell_mat}
            {mat_lab_color},
        dens => (
            $bconv->dens_ratio  # dens_{mat} / dens_{theo}
            * (
                $bconv->cell_mats_list->{$bconv->cell_mat}{mass_dens} ?
                $bconv->cell_mats_list->{$bconv->cell_mat}{mass_dens} : 0
            )
        ),
        melt_pt => $bconv->cell_mats_list->
            {$bconv->cell_mat}
            {melt_pt},
        boil_pt => $bconv->cell_mats_list->
            {$bconv->cell_mat}
            {boil_pt},
        thermal_cond => $bconv->cell_mats_list->
            {$bconv->cell_mat}
            {thermal_cond},
        #-----------------------#
        macrobody_descr => 'Right circular cylinder',
        macrobody_str   => 'rcc',
        macrobody_id    => 100,
        cmt => $phits->Cmt->symb.' Bremsstrahlung converter',
    );

    #
    # (2) Molybdenum target
    #

    # Preprocessing
    my %_motar_common = (
        cell_id => 11,
        #---Material-specific---#
        mat_id => $motar->cell_mats_list->
            {$motar->cell_mat}
            {mat_id},
        mat_comp => $motar->cell_mats_list->
            {$motar->cell_mat}
            {mat_comp},
        mat_lab_name => $motar->cell_mats_list->
            {$motar->cell_mat}
            {mat_lab_name},
        mat_lab_size => $motar->cell_mats_list->
            {$motar->cell_mat}
            {mat_lab_size},
        mat_lab_color => $motar->cell_mats_list->
            {$motar->cell_mat}
            {mat_lab_color},
        dens => (
            $motar->dens_ratio
            * $motar->cell_mats_list->{$motar->cell_mat}{mass_dens}
        ),
        melt_pt => $motar->cell_mats_list->
            {$motar->cell_mat}
            {melt_pt},
        boil_pt => $motar->cell_mats_list->
            {$motar->cell_mat}
            {boil_pt},
        thermal_cond  => $motar->cell_mats_list->
            {$motar->cell_mat}
            {thermal_cond},
        #-----------------------#
        macrobody_descr => 'Right circular cylinder',
        macrobody_str   => 'rcc',
        macrobody_id    => 105,
        cmt => $phits->Cmt->symb.' Molybdenum target',
    );

    $motar->set_cell_props(%_motar_common);
    # Molybdenum target, RCC
    $motar_rcc->set_cell_props(%_motar_common);
    $motar_rcc->cell_props->{cmt} .= ' (RCC)';
    $motar_rcc->set_flag(
        $motar->cell_mat.(
            $t_shared->Ctrls->shortname =~ /on/i ?
                '' : $phits->FileIO->fname_space
        ).$motar_rcc->cell_props->{macrobody_str}  # e.g. moo3_rcc
    );
    # Molybdenum target, TRC
    $motar_trc->set_cell_props(%_motar_common);
    $motar_trc->cell_props->{macrobody_descr} = 'Conical frustum';
    $motar_trc->cell_props->{macrobody_str}   = 'trc';
    $motar_trc->cell_props->{macrobody_id}    = 106;
    $motar_trc->cell_props->{cmt}            .= ' (TRC)';
    $motar_trc->set_flag(
        $motar->cell_mat.(
            $t_shared->Ctrls->shortname =~ /on/i ?
                '' : $phits->FileIO->fname_space
        ).$motar_trc->cell_props->{macrobody_str}  # e.g. moo3_trc
    );

    #
    # (3) Flux monitors
    #

    # Flux monitor, upstream
    $flux_mnt_up->set_cell_props(
        cell_id => 20,
        #---Material-specific---#
        mat_id => $flux_mnt_up->cell_mats_list->
            {$flux_mnt_up->cell_mat}
            {mat_id},
        mat_comp => $flux_mnt_up->cell_mats_list->
            {$flux_mnt_up->cell_mat}
            {mat_comp},
        mat_lab_name => $flux_mnt_up->cell_mats_list->
            {$flux_mnt_up->cell_mat}
            {mat_lab_name},
        mat_lab_size => $flux_mnt_up->cell_mats_list->
            {$flux_mnt_up->cell_mat}
            {mat_lab_size},
        mat_lab_color => $flux_mnt_up->cell_mats_list->
            {$flux_mnt_up->cell_mat}
            {mat_lab_color},
        dens => (
            $flux_mnt_up->dens_ratio
            * $flux_mnt_up->cell_mats_list->{$flux_mnt_up->cell_mat}
                                            {mass_dens}
        ),
        melt_pt => $flux_mnt_up->cell_mats_list->
            {$flux_mnt_up->cell_mat}
            {melt_pt},
        boil_pt => $flux_mnt_up->cell_mats_list->
            {$flux_mnt_up->cell_mat}
            {boil_pt},
        thermal_cond  => $flux_mnt_up->cell_mats_list->
            {$flux_mnt_up->cell_mat}
            {thermal_cond},
        #-----------------------#
        macrobody_descr => 'Right circular cylinder',
        macrobody_str   => 'rcc',
        macrobody_id    => 120,
        cmt => $phits->Cmt->symb.' Flux monitor (upstream)',
    );
    $flux_mnt_up->set_flag(
        $flux_mnt_up->cell_mat.(
            $t_shared->Ctrls->shortname =~ /on/i ?
                '' : $phits->FileIO->fname_space
        ).'rcc'  # wrto Mo RCC
    );

    # Flux monitor, downstream
    $flux_mnt_down->set_cell_props(
        cell_id => 21,
        #---Material-specific---#
        # The +9 below is to prevent an error of the 'mat name color' section.
        # (e.g. 790 + 9 = 799 will be its material ID)
        # If the upstream and downstream flux monitors are given different
        # densities in the 'cell' section, they will be recognized as separate
        # materials even though the same material ID is used.
        # In this case, the downstream flux monitor will not be colored
        # and named properly owing to lack of its own material ID
        # in the 'mat name color' section.
        mat_id => (
            $flux_mnt_down->cell_mats_list->
                {$flux_mnt_down->cell_mat}
                {mat_id}
        ) + 9,
        mat_comp => $flux_mnt_down->cell_mats_list->
            {$flux_mnt_down->cell_mat}
            {mat_comp},
        mat_lab_name => $flux_mnt_down->cell_mats_list->
            {$flux_mnt_down->cell_mat}
            {mat_lab_name},
        mat_lab_size => $flux_mnt_down->cell_mats_list->
            {$flux_mnt_down->cell_mat}
            {mat_lab_size},
        mat_lab_color => $flux_mnt_down->cell_mats_list->
            {$flux_mnt_down->cell_mat}
            {mat_lab_color},
        dens => (
            $flux_mnt_down->dens_ratio
            * $flux_mnt_down->cell_mats_list->{$flux_mnt_down->cell_mat}
                                              {mass_dens}
        ),
        melt_pt => $flux_mnt_down->cell_mats_list->
            {$flux_mnt_down->cell_mat}
            {melt_pt},
        boil_pt => $flux_mnt_down->cell_mats_list->
            {$flux_mnt_down->cell_mat}
            {boil_pt},
        thermal_cond => $flux_mnt_down->cell_mats_list->
            {$flux_mnt_down->cell_mat}
            {thermal_cond},
        #-----------------------#
        macrobody_descr => 'Right circular cylinder',
        macrobody_str   => 'rcc',
        macrobody_id    => 121,
        cmt => $phits->Cmt->symb.' Flux monitor (downstream)',
    );
    $flux_mnt_down->set_flag(
        $flux_mnt_down->cell_mat.(
            $t_shared->Ctrls->shortname =~ /on/i ?
                '' : $phits->FileIO->fname_space
        ).'rcc'  # wrto Mo RCC
    );

    #
    # (4) Target wrap
    #
    $tar_wrap->set_flag(
        $tar_wrap->cell_mat.(
            $t_shared->Ctrls->shortname =~ /on/i ?
                '' : $phits->FileIO->fname_space
        ).'rcc'  # wrto Mo RCC
    );
    $tar_wrap->set_cell_props(
        cell_id => 30,
        #---Material-specific---#
        mat_id => $tar_wrap->cell_mats_list->
            {$tar_wrap->cell_mat}
            {mat_id},
        mat_comp => $tar_wrap->cell_mats_list->
            {$tar_wrap->cell_mat}
            {mat_comp},
        mat_lab_name => $tar_wrap->cell_mats_list->
            {$tar_wrap->cell_mat}
            {mat_lab_name},
        mat_lab_size => $tar_wrap->cell_mats_list->
            {$tar_wrap->cell_mat}
            {mat_lab_size},
        mat_lab_color => $tar_wrap->cell_mats_list->
            {$tar_wrap->cell_mat}
            {mat_lab_color},
        dens => (
            $tar_wrap->dens_ratio
            * $tar_wrap->cell_mats_list->{$tar_wrap->cell_mat}{mass_dens}
        ),
        melt_pt => $tar_wrap->cell_mats_list->
            {$tar_wrap->cell_mat}
            {melt_pt},
        boil_pt => $tar_wrap->cell_mats_list->
            {$tar_wrap->cell_mat}
            {boil_pt},
        thermal_cond => $tar_wrap->cell_mats_list->
            {$tar_wrap->cell_mat}
            {thermal_cond},
        #-----------------------#
        macrobody_descr => 'Right circular cylinder',
        macrobody_str   => 'rcc',
        macrobody_id    => 130,
        cmt => $phits->Cmt->symb.' Target wrap',
    );

    # (5) Molybdenum target entrance
    # Override the material using the material of MC space.
    $motar_ent->set_cell_mat($mc_space->cell_mat);
    $motar_ent->set_flag('motar_ent');
    $motar_ent->set_cell_props(
        cell_id => 40,
        #---Material-specific---#
        mat_id => $motar_ent->cell_mats_list->
            {$motar_ent->cell_mat}
            {mat_id},
        mat_comp => $motar_ent->cell_mats_list->
            {$motar_ent->cell_mat}
            {mat_comp},
        mat_lab_name => $motar_ent->cell_mats_list->
            {$motar_ent->cell_mat}
            {mat_lab_name},
        mat_lab_size => $motar_ent->cell_mats_list->
            {$motar_ent->cell_mat}
            {mat_lab_size},
        mat_lab_color => $motar_ent->cell_mats_list->
            {$motar_ent->cell_mat}
            {mat_lab_color},
        dens => $motar_ent->cell_mats_list->{$motar_ent->cell_mat}{mass_dens} ?
            (
                $motar_ent->cell_mats_list->{$motar_ent->cell_mat}{mass_dens}
                * $motar_ent->dens_ratio
            ) : $motar_ent->cell_mats_list->{$motar_ent->cell_mat}{mass_dens},
        #-----------------------#
        macrobody_descr => 'Right circular cylinder',
        macrobody_str   => 'rcc',
        macrobody_id    => 140,
        cmt => $phits->Cmt->symb.' Molybdenum target entrance',
    );

    #
    # (6) MC space: Inside
    #
    $mc_space->set_flag('mc_space');
    $mc_space->set_cell_props(
        cell_id => 98,
        #---Material-specific---#
        mat_id => $mc_space->cell_mats_list->
            {$mc_space->cell_mat}
            {mat_id},
        mat_comp => $mc_space->cell_mats_list->
            {$mc_space->cell_mat}
            {mat_comp},
        mat_lab_name => $mc_space->cell_mats_list->
            {$mc_space->cell_mat}
            {mat_lab_name},
        mat_lab_size => $mc_space->cell_mats_list->
            {$mc_space->cell_mat}
            {mat_lab_size},
        mat_lab_color => $mc_space->cell_mats_list->
            {$mc_space->cell_mat}
            {mat_lab_color},
        dens => $mc_space->cell_mats_list->{$mc_space->cell_mat}{mass_dens} ?
            (
                $mc_space->cell_mats_list->{$mc_space->cell_mat}{mass_dens}
                * $mc_space->dens_ratio
            ) : $mc_space->cell_mats_list->{$mc_space->cell_mat}{mass_dens},
        #-----------------------#
        macrobody_descr => 'Sphere at the origin',
        macrobody_str   => 'so',
        macrobody_id    => 999,
        cmt => $phits->Cmt->symb.' MC calculation space',
    );
    $mc_space->set_radius_fixed(50);

    #
    # (7) MC space: Outside
    #
    $void->set_flag('void');
    $void->set_cell_props(
        cell_id => 99,
        mat_id  => -1,  # Predefined ID for the "outer void"
        # No composition for void
        # No [mat name color] for void
        # No density for void
        # No macrobody for void
    );

    # Examine if a duplicate 'cell_id' and/or a 'macrobody_id' exists.
    my %_seen = ();
    foreach my $mc_cell (
        $bconv,
        $motar,
        $flux_mnt_up,
        $flux_mnt_down,
        $tar_wrap,
        $motar_ent,
        $mc_space,
        $void,
    ) {
        $_seen{$mc_cell->cell_props->{cell_id}}++;
        if (
            $_seen{$mc_cell->cell_props->{cell_id}}
            and $_seen{$mc_cell->cell_props->{cell_id}} >= 2
        ) {
            croak(
                "'cell_id' => ".$mc_cell->cell_props->{cell_id}.
                " duplicated!\n".
                "Look up 'sub populate_mc_cell_props' and fix it.\n"
            );
        }

        if ($mc_cell->cell_props->{macrobody_id}) {
            $_seen{$mc_cell->cell_props->{macrobody_id}}++;
            if (
                $_seen{$mc_cell->cell_props->{macrobody_id}}
                and $_seen{$mc_cell->cell_props->{macrobody_id}} >= 2
            ) {
                croak(
                    "'macrobody_id' => ".$mc_cell->cell_props->{macrobody_id}.
                    " duplicated!\n".
                    "Look up 'sub populate_mc_cell_props' and fix it.\n"
                );
            }
        }
    }

    return;
}


sub show_tar_geoms {
    # """Show target geometries."""
    my $opt = shift if $_[0];
    my @target_geoms;

    #
    # Unit: cm
    #

    # Bremsstrahlung converter
    push @target_geoms,
        sprintf("\$bconv->$_ is [%s]", $bconv->$_) for qw (
            height_fixed
            radius_fixed
            gap_fixed
        );

    map {
        push @target_geoms, "\$bconv->$_ is [";
        $target_geoms[-1] .= $_ for join(', ', @{$bconv->$_});
        $target_geoms[-1] .= "]";
    } qw (
        heights_of_int
        radii_of_int
        gaps_of_int
    );

    # Molybdenum target, "R"CC
    push @target_geoms,
        sprintf("\$motar_rcc->$_ is [%s]", $motar_rcc->$_) for qw (
            height_fixed
            radius_fixed
        );

    map {
        push @target_geoms, "\$motar_rcc->$_ is [";
        $target_geoms[-1] .= $_ for join(', ', @{$motar_rcc->$_});
        $target_geoms[-1] .= "]";
    } qw (
        heights_of_int
        radii_of_int
    );

    # Molybdenum target, "T"RC
    push @target_geoms, sprintf("\$motar_trc->$_ is [%s]", $motar_trc->$_)
        for qw (
            height_fixed
            bot_radius_fixed
            top_radius_fixed
        );

    map {
        push @target_geoms, "\$motar_trc->$_ is [";
        $target_geoms[-1] .= $_ for join(', ', @{$motar_trc->$_});
        $target_geoms[-1] .= "]";
    } qw (
        heights_of_int
        bot_radii_of_int
        top_radii_of_int
    );

    # Flux monitor, upstream
    push @target_geoms,
        sprintf("\$flux_mnt_up->$_ is [%s]", $flux_mnt_up->$_)
        for qw (
            height_fixed
            radius_fixed
        );

    # Flux monitor, downstream
    push @target_geoms,
        sprintf("\$flux_mnt_down->$_ is [%s]", $flux_mnt_down->$_)
        for qw (
            height_fixed
            radius_fixed
        );

    # Print or return the target geometries.
    if (not $opt) {
        say for @target_geoms;
    }
    elsif ($opt and $opt =~ /copy/i) {
        return @target_geoms;
    }

    return;
}


sub show_linac_params {
    # """Show linac parameters."""
    my $opt = shift if $_[0];
    my @linac_settings;

    #
    # Unit: s, eV, A, W
    #

    # Klystron info
    push @linac_settings, sprintf(
        "\$elinac_of_int->rf_power_source->$_ is [%s]",
        $elinac_of_int->rf_power_source->$_
    ) for qw(
        name
        oper_freq
        rf_pulse_width
        rf_pulse_per_sec
        duty_cycle
    );

    # Beam parameters
    push @linac_settings, sprintf(
        "\$elinac_of_int->$_ is [%s]",
        $elinac_of_int->$_
    ) for qw(
        name
        peak_beam_nrg
        peak_beam_curr
        peak_beam_power
        avg_beam_curr
        avg_beam_power
    );

    # Print or return the linac settings.
    if (not $opt) {
        say for @linac_settings;
    }
    elsif ($opt and $opt =~ /copy/i) {
        return @linac_settings;
    }

    return;
}


sub run_and_rpt_calc_rn_yield {
    # """Run Nuclear::calc_rn_yield() and generate report files."""
    my (                      # e.g.
        $mc_cell_of_int,      # $flux_mnt_up
        $react_nucl,          # 'au197'
        $prod_nucl,           # 'au196'
        $prod_nucl_flag,      # '_1'
        $yld_deleg,           # == $yield (delegate of all)
        $yld_pn_deleg,        # $yield_au196 (product nuclide delegate)
        $yld_pn_each,         # $yield_au196_1 (each product nuclide)
        $yld_pn_each_sp_src,  # $yield_au196_1_for_sp_src
        $pwm_pn_each_sp_src,  # $pwm_au196_1_for_sp_src
        $mc_flue_dat,         # $t_track->nrg_flux_mnt_up->fname
        # >> Dependent on inner_iterator()
        $tar_of_int,
        $_varying_str,
        $run_opts_href,
        $prog_info_href,
        $source_eg0,
        # <<
    ) = @_;
    my $_conv_cmt1 = '%-24s';
    my $_conv_cmt2 = '%-30s';
    my $_conv_val1 = '%.6f';
    my $_conv_val2 = '%.6e';

    #
    # (1/2) Running Part
    # > Calculate the yield and specific yield of $prod_nucl and
    #   fill in the data reduction array reference.
    #
    my $the_tar_mat = sprintf(
        # calc_rn_yield() requirement:
        # > 'mo' -> 'momet'
        # > 'au' -> 'aumet'
        "%s%s",
        $mc_cell_of_int->cell_mat,
        $mc_cell_of_int->cell_mat =~ /(mo|au)\b/i ? 'met' : '',
    );
    my $yld_pn_each_href = calc_rn_yield(
        {
            # Reactant nuclide number density calculation
            tar_mat                 => $the_tar_mat,
            tar_dens_ratio          => $mc_cell_of_int->dens_ratio,
            tar_vol                 => $mc_cell_of_int->vol,
            react_nucl              => $react_nucl,
            react_nucl_enri_lev     => $yld_pn_deleg->react_nucl_enri_lev,
            enri_lev_type           => 'amt_frac',
            prod_nucl               => $prod_nucl,
            min_depl_lev_global     => 0.0000,
            min_depl_lev_local_href => {},
            depl_order              => 'ascend',
            is_verbose              => 0,

            # Irradiation conditions
            avg_beam_curr => $yld_deleg->avg_beam_curr,  # uA
            end_of_irr    => $yld_deleg->end_of_irr,     # h

            # Particle fluence data
            mc_flue_dir => (
                $phits->FileIO->subdir.
                $phits->FileIO->path_delim.
                $phits->FileIO->subsubdir
            ),
            # Column number for the reaction projectile
            mc_flue_dat          => $mc_flue_dat,
            mc_flue_dat_proj_col => $t_track->is_elec_of_int ? 4 : 2,

            # Microscopic xs data
            micro_xs_dir => (
                $phits->cwd.
                $phits->FileIO->path_delim.
                $yld_pn_deleg->FileIO->micro_xs_dir
            ),
            micro_xs_dat         => $yld_pn_deleg->FileIO->micro_xs_dat,
            micro_xs_interp_algo => $yld_pn_deleg->micro_xs_interp_algo,
            # Note on eff_nrg_range_pointwise_<<$prod_nucl>>
            # > xs data, as will be interpolated by gnuplot smooth
            #   in calc_rn_yield(), are pointwise data; namely,
            #   one cross section corresponds to one energy "point".
            #   e.g. Energy: 8.46938e+06 eV, cross section: 0.0035858 b
            # > On the other hand, a PHITS particle fluence is bounded by
            #   e-lower and e-upper in a tally.
            #   e.g. e-lower: 8.2820E+00 MeV, e-upper: 8.3017E+00 MeV
            #        electron fluence: 1.6865E-04 cm^-2 source^-1
            # > To make the indices of xs and fluence data correspond to
            #   effectively the same energy points,
            #   "eff_nrg_range_pointwise_<<$prod_nucl>>" is used for xs data,
            #   and "eff_nrg_range_interval_<<$prod_nucl>>" for PHITS data.
            # > Both the pointwise and interval parameters are calculated
            #   at determ_tally_emin_emax().
            micro_xs_emin => sprintf(
                "%s"."e6",  # eV
                $t_track->mesh_ranges
                    ->{emin}{"eff_nrg_range_pointwise_$prod_nucl"}
            ),
            micro_xs_emax => sprintf(
                "%s"."e6",  # eV
                $t_track->mesh_ranges
                    ->{emax}{"eff_nrg_range_pointwise_$prod_nucl"}
            ),
            micro_xs_ne => $yld_pn_deleg->num_of_nrg_bins,

            # precision_href: Overwrite the local %fmt_specifiers.
            precision_href => {
                molar_mass         => $_conv_val1,
                wgt_molar_mass     => $_conv_val1,
                wgt_avg_molar_mass => $_conv_val1,
                amt_frac           => $_conv_val1,
                mass_frac          => $_conv_val1,
                dens_ratio         => $_conv_val1,
                mass_dens          => $_conv_val1,
                num_dens           => $_conv_val2,
                vol                => $_conv_val1,
                mass               => $_conv_val1,
                dcc                => $_conv_val1,
                avg_beam_curr => $_conv_val1,
                end_of_irr    => $_conv_val1,
                nrg_ev        => $_conv_val2,
                nrg_mega_ev   => $_conv_val1,
                ev            => $_conv_val2,
                mega_ev       => $_conv_val1,
                proj          => $_conv_val2,
                barn          => $_conv_val1,
                'cm^2'        => $_conv_val2,
                'cm^-1'       => $_conv_val2,
                de            => $_conv_val1,
                xs_micro      => $_conv_val2,
                xs_macro      => $_conv_val2,
                mc_flue       => $_conv_val2,
                pwm_micro     => $_conv_val2,
                pwm_micro_tot => $_conv_val2,
                pwm_macro     => $_conv_val2,
                pwm_macro_tot => $_conv_val2,
                source_rate   => $_conv_val2,
                reaction_rate => $_conv_val2,
                react_rate_per_vol     => $_conv_val2,
                react_rate_per_vol_tot => $_conv_val2,
                react_rate             => $_conv_val2,
                react_rate_tot         => $_conv_val2,
                yield                 => $_conv_val1,
                yield_per_microamp    => $_conv_val1,
                sp_yield              => $_conv_val1,
                sp_yield_per_microamp => $_conv_val1,
            },

            # Yield and specific yield units
            yield_unit => $yld_deleg->unit,  # If omitted, 'Bq' is used.
        },
    );
    $yld_pn_each->set_calc_rn_yield(%$yld_pn_each_href);

    # Fill in the array refs with calculation results.
    $_->add_columnar_arr(
        $phits->v_src_param->{curr},        # Curr var src param
        $phits->v_geom_param->{curr} * 10,  # Curr var geom param; cm --> mm
        $yld_pn_each->calc_rn_yield->{prod_nucl_yield},
        $yld_pn_each->calc_rn_yield->{prod_nucl_yield_per_microamp},
        $yld_pn_each->calc_rn_yield->{prod_nucl_sp_yield},
        $yld_pn_each->calc_rn_yield->{prod_nucl_sp_yield_per_microamp},
    ) for ($yld_pn_each, $yld_pn_each_sp_src);

    # PWM
    if ($yld_pn_deleg->Ctrls->pwm_switch =~ /on/i) {
        # Write data over the photon energy range.
        for (
            my $i=0;
            $i<=$#{$yld_pn_each->calc_rn_yield->{mc_flue_nrg_mega_ev}};
            $i++
        ) {
            $pwm_pn_each_sp_src->add_columnar_arr(
                $phits->v_src_param->{curr},
                $phits->v_geom_param->{curr} * 10,
                $yld_pn_each->calc_rn_yield->{mc_flue_nrg_mega_ev}[$i],
                $yld_pn_each->calc_rn_yield->{mc_flue_proj}[$i],
                $yld_pn_each->calc_rn_yield->{xs_nrg_mega_ev}[$i],
                $yld_pn_each->calc_rn_yield->{micro_xs_barn}[$i],
                $yld_pn_each->calc_rn_yield->{'micro_xs_cm^2'}[$i],
                $yld_pn_each->calc_rn_yield->{react_nucl_num_dens},
                $yld_pn_each->calc_rn_yield->{'macro_xs_cm^-1'}[$i],
                $yld_pn_each->calc_rn_yield->{pwm_micro}[$i],
                $yld_pn_each->calc_rn_yield->{pwm_macro}[$i],
                $yld_pn_each->calc_rn_yield->{avg_beam_curr},
                $yld_pn_each->calc_rn_yield->{source_rate},
                $yld_pn_each->calc_rn_yield->{react_rate_per_vol}[$i],
                $yld_pn_each->calc_rn_yield->{tar_vol},
                $yld_pn_each->calc_rn_yield->{react_rate}[$i],
            );
        }
    }

    #
    # (2/2) Postprocessing Part
    #
    if (@{$yld_pn_each->columnar_arr}) {
        # Heads and subheads 1
        # > $yld_pn_each and $yld_pn_each_sp_src
        my $_heads1 = [
            sprintf(
                "%s",  # e.g. eg0
                $phits->v_src_param->{name},
            ),
            sprintf(
                "%s %s",  # e.g. wrcc vhgt
                $tar_of_int->flag,
                $phits->FileIO->varying_flag,
            ),
            sprintf(
                "%s yield",
                $yld_pn_each->calc_rn_yield->{prod_nucl_symb},
            ),
            sprintf(
                "%s yield per uA",
                $yld_pn_each->calc_rn_yield->{prod_nucl_symb},
            ),
            sprintf(
                "%s sp_yield",
                $yld_pn_each->calc_rn_yield->{prod_nucl_symb},
            ),
            sprintf(
                "%s sp_yield per uA",
                $yld_pn_each->calc_rn_yield->{prod_nucl_symb},
            ),
        ];
        my $_subheads1 = [
            sprintf(
                "(%s)",
                $phits->v_src_param->{unit},
            ),
            "(mm)",
            sprintf(
                "(%s)",
                $yld_pn_each->calc_rn_yield->{yield_unit},
            ),
            sprintf(
                "(%s uA^{-1})",
                $yld_pn_each->calc_rn_yield->{yield_unit},
            ),
            sprintf(
                "(%s g^{-1})",
                $yld_pn_each->calc_rn_yield->{yield_unit},
            ),
            sprintf(
                "(%s g^{-1} uA^{-1})",
                $yld_pn_each->calc_rn_yield->{yield_unit},
            ),
        ];
        # Heads and subheads 2
        # > $pwm_pn_each_sp_src
        my $_heads2 = [
            sprintf(
                "%s",
                $phits->v_src_param->{name},
            ),
            sprintf(
                "%s %s",
                $tar_of_int->flag,
                $phits->FileIO->varying_flag,
            ),
            "MC fluence energy [(e-lower + e-upper) / 2]",
            "MC fluence",
            "xs energy",
            "Microscopic xs",
            "Microscopic xs",
            (
                $yld_pn_each->calc_rn_yield->{react_nucl_symb}.
                ' number density'
            ),
            "Macroscopic xs",
            "PWM for microscopic xs",
            "PWM for macroscopic xs",
            "Average beam current",
            "Source rate",
            sprintf(
                "Reaction rate per %s volume",
                $yld_pn_each->calc_rn_yield->{tar_mat_symb},
            ),
            sprintf(
                "%s volume",
                $yld_pn_each->calc_rn_yield->{tar_mat_symb},
            ),
            "Reaction rate",
        ];
        my $_subheads2 = [
            sprintf(
                "(%s)",
                $phits->v_src_param->{unit},
            ),
            "(mm)",
            "(MeV)",
            sprintf(
                "(cm^{-2} %s^{-1})",
                $phits->source->spat_dist_of_int->{proj}{val},
            ),
            "(MeV)",
            "(b)",
            "(cm^{2})",
            "(cm^{-3})",
            "(cm^{-1})",
            sprintf(
                "(%s^{-1})",
                $phits->source->spat_dist_of_int->{proj}{val},
            ),
            sprintf(
                "(cm^{-3} %s^{-1})",
                $phits->source->spat_dist_of_int->{proj}{val},
            ),
            "(uA)",
            sprintf(
                "(%s s^{-1})",
                $phits->source->spat_dist_of_int->{proj}{val},
            ),
            "(cm^{-3} s^{-1})",
            "(cm^{3})",
            "(s^{-1} or Bq)",
        ];

        my $_v_src_param_start  = $phits->v_src_param->{start};
        my $_v_src_param_stop   = $phits->v_src_param->{stop};
        my $_v_src_param_curr   = $phits->v_src_param->{curr};
        my $_v_geom_param_start = $phits->v_geom_param->{start};
        my $_v_geom_param_stop  = $phits->v_geom_param->{stop};
        s/[.]/p/ for (
            $_v_src_param_start,
            $_v_src_param_stop,
            $_v_src_param_curr,
            $_v_geom_param_start,
            $_v_geom_param_stop,
        );
        my %yield_objs = (
            yld_pn_each => {
                obj_for_cmt => $yld_pn_each,
                rpt_bname   => (                   # Filename w/o its ext
                    "yields_$prod_nucl$prod_nucl_flag".
                    $phits->FileIO->fname_sep.     # -
                    $_varying_str.                 # v
                    $phits->v_src_param->{name}.   # eg0
                    (
                        $phits->v_src_param->{name} =~ /[0-9]$/i ?
                            $phits->FileIO->fname_space : ''
                    ).
                    $_v_src_param_start.           # 30
                    'to'.                          # to
                    $_v_src_param_stop.            # 40
                    $phits->FileIO->fname_sep.     # -
                    $tar_of_int->flag.             # wrcc || w_rcc
                    $phits->FileIO->fname_sep.     # -
                    $phits->FileIO->varying_flag.  # vhgt || v_hgt
                    $_v_geom_param_start.          # 0p10
                    'to'.                          # to
                    $_v_geom_param_stop            # 0p70
                ),
                size         => 6,
                heads        => $_heads1,
                subheads     => $_subheads1,
                columnar_arr => $yld_pn_each->columnar_arr,
                ragged_left  => [2..5],
            },
            yld_pn_each_sp_src => {
                obj_for_cmt => $yld_pn_each,
                rpt_bname   => (                  # Filename w/o its ext
                    "yields_$prod_nucl$prod_nucl_flag".
                    $phits->FileIO->fname_sep.    # -
                    $_varying_str.                # v
                    $phits->v_src_param->{name}.  # eg0
                    (
                        $phits->v_src_param->{name} =~ /[0-9]$/i ?
                            $phits->FileIO->fname_space : ''
                    ).
                    $_v_src_param_curr.           # 35
                    $phits->FileIO->fname_sep.
                    $tar_of_int->flag.
                    $phits->FileIO->fname_sep.
                    $phits->FileIO->varying_flag.
                    $_v_geom_param_start.
                    'to'.
                    $_v_geom_param_stop
                ),
                size         => 6,
                heads        => $_heads1,
                subheads     => $_subheads1,
                columnar_arr => $yld_pn_each_sp_src->columnar_arr,
                ragged_left  => [2..5],
            },
            pwm_pn_each_sp_src => {
                obj_for_cmt => $yld_pn_each,
                rpt_bname   => (
                    "yields_$prod_nucl$prod_nucl_flag".
                    $phits->FileIO->fname_sep.
                    $_varying_str.
                    $phits->v_src_param->{name}.
                    (
                        $phits->v_src_param->{name} =~ /[0-9]$/i ?
                            $phits->FileIO->fname_space : ''
                    ).
                    $_v_src_param_curr.
                    $phits->FileIO->fname_sep.
                    $tar_of_int->flag.
                    $phits->FileIO->fname_sep.
                    $phits->FileIO->varying_flag.
                    $_v_geom_param_start.
                    'to'.
                    $_v_geom_param_stop.
                    $phits->FileIO->fname_sep.
                    'pwm'
                ),
                size         => 16,
                heads        => $_heads2,
                subheads     => $_subheads2,
                columnar_arr => $pwm_pn_each_sp_src->columnar_arr,
                switch       => $yld_pn_deleg->Ctrls->pwm_switch,
            },
        );

        foreach my $k (sort keys %yield_objs) {
            next if (
                exists $yield_objs{$k}{switch}
                and $yield_objs{$k}{switch} =~ /off/i
            );

            my $obj_for_cmt = $yield_objs{$k}{obj_for_cmt};
            reduce_data(
                {  # Settings
                    rpt_formats => $run_opts_href->{rpt_fmts},
                    rpt_path    => $run_opts_href->{rpt_path},
                    rpt_bname   => $yield_objs{$k}{rpt_bname},
                    begin_msg   => "collecting yields and specific yields...",
                    prog_info   => $prog_info_href,
                    cmt_arr => [
                        #
                        # Shared comment 1: Yield calculation conditions
                        #
                        "-" x 69,
                        " Yield calculation conditions (last evaluated)",
                        "-" x 69,
                        # (1) Source particle
                        sprintf(
                            " %s %s",
                            'Source particle:',  # Projectile: electron
                            $phits->source->spat_dist_of_int->{proj}{val},
                        ),
                        sprintf(
                            " $_conv_cmt1 %s",
                            'Source energy distribution:',
                            $phits->curr_src_nrg_dist->{name},
                        ),
                        sprintf(
                            " %s",
                            $phits->curr_src_nrg_dist->{param1},
                        ),
                        sprintf(
                            " %s",
                            $phits->curr_src_nrg_dist->{param2},
                        ),
                        sprintf(
                            " %s %s uA",
                            'Source average current:',
                            $obj_for_cmt->calc_rn_yield->{avg_beam_curr},
                        ),
                        sprintf(
                            " $_conv_cmt1 %s",
                            'Source spatial distribution:',
                            $phits->curr_src_spat_dist->{name},
                        ),
                        sprintf(
                            " %s",
                            $phits->curr_src_spat_dist->{param1},
                        ),
                        sprintf(
                            " %s",
                            $phits->curr_src_spat_dist->{param2},
                        ),
                        # (2) Converter
                        '',
                        sprintf(
                            " $_conv_cmt1 %s",
                            'Converter material:',
                            $bconv->cell_mat,
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1",
                            'Converter density ratio:',
                            $bconv->dens_ratio,
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1 g cm^{-3}",
                            'Converter mass density:',
                            $bconv->cell_props->{dens},
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1 mm",
                            'Converter diameter:',
                            2 * $bconv->radius * 10,
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1 mm",
                            'Converter thickness:',
                            $bconv->height * 10,
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1 cm^{3}",
                            'Converter volume:',
                            $bconv->vol,
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1 g",
                            'Converter mass:',
                            $bconv->mass,
                        ),
                        # Intertarget distance
                        '',
                        sprintf(
                            " $_conv_cmt1 $_conv_val1 mm",
                            'Converter-Mo target distance:',
                            $bconv->gap * 10,
                        ),
                        # (3) Mo target
                        '',
                        sprintf(
                            " $_conv_cmt1 %s",
                            'Mo target:',
                            $motar->cell_mat,
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1",
                            'Mo target density ratio:',
                            $motar->dens_ratio,
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1 g cm^{-3}",
                            'Mo target mass density:',
                            $motar->cell_props->{dens},
                        ),
                        (
                            $tar_of_int->flag eq $motar_trc->flag ?
                            (
                                sprintf(
                                    " $_conv_cmt1 $_conv_val1 mm",
                                    'Mo target bottom radius:',
                                    $motar_trc->bot_radius * 10,
                                ),
                                sprintf(
                                    " $_conv_cmt1 $_conv_val1 mm",
                                    'Mo target top radius:',
                                    $motar_trc->top_radius * 10,
                                ),
                                sprintf(
                                    " $_conv_cmt1 $_conv_val1 mm",
                                    'Mo target thickness:',
                                    $motar_trc->height * 10,
                                ),
                                sprintf(
                                    " $_conv_cmt1 $_conv_val1 cm^{3}",
                                    'Mo target volume:',
                                    $motar_trc->vol,
                                ),
                                sprintf(
                                    " $_conv_cmt1 $_conv_val1 g",
                                    'Mo target mass:',
                                    $motar_trc->mass,
                                ),
                            ) : (
                                sprintf(
                                    " $_conv_cmt1 $_conv_val1 mm",
                                    'Mo target diameter:',
                                    2 * $motar_rcc->radius * 10,
                                ),
                                sprintf(
                                    " $_conv_cmt1 $_conv_val1 mm",
                                    'Mo target thickness:',
                                    $motar_rcc->height * 10,
                                ),
                                sprintf(
                                    " $_conv_cmt1 $_conv_val1 cm^{3}",
                                    'Mo target volume:',
                                    $motar_rcc->vol,
                                ),
                                sprintf(
                                    " $_conv_cmt1 $_conv_val1 g",
                                    'Mo target mass:',
                                    $motar_rcc->mass,
                                ),
                            ),
                        ),
                        # (4) Flux monitor, upstream (conditional)
                        '',
                        $flux_mnt_up->height > 0 ? (
                            sprintf(
                                " $_conv_cmt1 %s",
                                'Upstream flux monitor material:',
                                $flux_mnt_up->cell_mat,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1",
                                'Upstream flux monitor density ratio:',
                                $flux_mnt_up->dens_ratio,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 g cm^{-3}",
                                'Upstream flux monitor mass density:',
                                $flux_mnt_up->cell_props->{dens},
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 mm",
                                'Upstream flux monitor diameter:',
                                2 * $flux_mnt_up->radius * 10,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 um",
                                'Upstream flux monitor thickness:',
                                $flux_mnt_up->height * 1e4,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 cm^{3}",
                                'Upstream flux monitor volume:',
                                $flux_mnt_up->vol,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 g",
                                'Upstream flux monitor mass:',
                                $flux_mnt_up->mass,
                            ),
                        ) : " No upstream fluence",
                        # (5) Flux monitor, downstream (conditional)
                        $flux_mnt_down->height > 0 ? (
                            '',
                            sprintf(
                                " $_conv_cmt1 %s",
                                'Downstream flux monitor material:',
                                $flux_mnt_down->cell_mat,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1",
                                'Downstream flux monitor density ratio:',
                                $flux_mnt_down->dens_ratio,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 g cm^{-3}",
                                'Downstream flux monitor mass density:',
                                $flux_mnt_down->cell_props->{dens},
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 mm",
                                'Downstream flux monitor diameter:',
                                2 * $flux_mnt_down->radius * 10,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 um",
                                'Downstream flux monitor thickness:',
                                $flux_mnt_down->height * 1e4,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 cm^{3}",
                                'Downstream flux monitor volume:',
                                $flux_mnt_down->vol,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 g",
                                'Downstream flux monitor mass:',
                                $flux_mnt_down->mass,
                            ),
                        ) : " No downstream fluence",
                        # (6) Target wrap (conditional)
                        $tar_wrap->thickness > 0 ? (
                            '',
                            sprintf(
                                " $_conv_cmt1 %s",
                                'Target wrap flux monitor material:',
                                $tar_wrap->cell_mat,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1",
                                'Target wrap flux monitor density ratio:',
                                $tar_wrap->dens_ratio,
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 g cm^{-3}",
                                'Target wrap flux monitor mass density:',
                                $tar_wrap->cell_props->{dens},
                            ),
                            sprintf(
                                " $_conv_cmt1 $_conv_val1 um",
                                'Target wrap flux monitor thickness:',
                                $tar_wrap->thickness * 1e4,
                            ),
                        ) : " No target wrap",
                        # Main calculation conditions
                        '',
                        sprintf(
                            " $_conv_cmt1 $_conv_val1",
                            (
                                $obj_for_cmt->calc_rn_yield->{react_nucl_symb}.
                                ' enrichment level:'
                            ),
                            $obj_for_cmt->calc_rn_yield->{react_nucl_enri_lev},
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1 uA (%s)",
                            'Average beam current:',
                            $obj_for_cmt->calc_rn_yield->{avg_beam_curr},
                            sprintf(
                                "$_conv_val2 %ss s^{-1}",
                                $obj_for_cmt->calc_rn_yield->{source_rate},
                                $phits->source->spat_dist_of_int->{proj}{val},
                            ),
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1 h",
                            'Irradiation time:',
                            $obj_for_cmt->calc_rn_yield->{end_of_irr},
                        ),
                        # PHITS summary
                        '',
                        sprintf(
                            " $_conv_cmt1 %s",
                            'Summary file:',
                            $phits->params->{file}{summary_out_fname}{val},
                        ),
                        sprintf(
                            " $_conv_cmt1 %s",
                            'maxcas:',
                            $phits->retrieved->{maxcas},
                        ),
                        sprintf(
                            " $_conv_cmt1 %s",
                            'maxbch:',
                            $phits->retrieved->{maxbch},
                        ),
                        # Particle fluence
                        '',
                        sprintf(
                            " $_conv_cmt1 %s",
                            'Fluence file:',
                            $mc_flue_dat,
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1--$_conv_val1 MeV",
                            'Fluence energy range:',
                            $t_track->mesh_ranges
                                ->{emin}{"eff_nrg_range_interval_$prod_nucl"},
                            $t_track->mesh_ranges
                                ->{emax}{"eff_nrg_range_interval_$prod_nucl"},
                        ),
                        sprintf(
                            " $_conv_cmt1 %s",
                            'Fluence ne:',
                            $obj_for_cmt->calc_rn_yield->{mc_flue_nrg_ne},
                        ),
                        sprintf(
                            " $_conv_cmt1 %s MeV",
                            'Fluence de:',
                            $obj_for_cmt->calc_rn_yield->{mc_flue_nrg_de},
                        ),
                        sprintf(
                            " $_conv_cmt1 %s",
                            'Fluence unit:',
                            $obj_for_cmt->calc_rn_yield->{mc_flue_unit},
                        ),
                        # Microscopic xs
                        '',
                        sprintf(
                            " $_conv_cmt1 %s",
                            'xs file:',
                            $yld_pn_deleg->FileIO->micro_xs_dat,
                        ),
                        sprintf(
                            " $_conv_cmt1 %s",
                            'xs interpolation algo:',
                            $yld_pn_deleg->micro_xs_interp_algo,
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1--$_conv_val1 MeV",
                            'xs energy range:',
                            $obj_for_cmt->calc_rn_yield->{xs_nrg_mega_ev}[0],
                            $obj_for_cmt->calc_rn_yield->{xs_nrg_mega_ev}[-1],
                        ),
                        sprintf(
                            " $_conv_cmt1 %s",
                            'xs ne:',
                            $obj_for_cmt->calc_rn_yield->{xs_nrg_ne},
                        ),
                        sprintf(
                            " $_conv_cmt1 $_conv_val1 MeV",
                            'xs de:',
                            $obj_for_cmt->calc_rn_yield->{xs_nrg_de},
                        ),
                        "-" x 69,
                        #
                        # Shared comment 2: Part of calculation results
                        #
                        "-" x 69,
                        " Part of calculation results (last evaluated)",
                        "-" x 69,
                        # Target material
                        sprintf(
                            " $_conv_cmt2 $_conv_val1 g cm^{-3}",
                            (
                                $obj_for_cmt->calc_rn_yield->{tar_mat_symb}.
                                ' mass density:'
                            ),
                            $obj_for_cmt->calc_rn_yield->{tar_mass_dens},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val2 cm^{-3}",
                            (
                                $obj_for_cmt->calc_rn_yield->{tar_mat_symb}.
                                ' number density:'
                            ),
                            $obj_for_cmt->calc_rn_yield->{tar_num_dens},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val1 g",
                            (
                                $obj_for_cmt->calc_rn_yield->{tar_mat_symb}.
                                ' mass:'
                            ),
                            $obj_for_cmt->calc_rn_yield->{tar_mass},
                        ),
                        # Reactant nuclide element
                        '',
                        sprintf(
                            " $_conv_cmt2 $_conv_val1",
                            (
                                $obj_for_cmt->calc_rn_yield
                                    ->{react_nucl_elem_symb}.
                                ' mass fraction in '.
                                $obj_for_cmt->calc_rn_yield
                                    ->{tar_mat_symb}.':'
                            ),
                            $obj_for_cmt->calc_rn_yield
                                ->{react_nucl_elem_mass_frac},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val1 g cm^{-3}",
                            (
                                $obj_for_cmt->calc_rn_yield
                                    ->{react_nucl_elem_symb}.' mass density:'
                            ),
                            $obj_for_cmt->calc_rn_yield
                                ->{react_nucl_elem_mass_dens},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val2 cm^{-3}",
                            (
                                $obj_for_cmt->calc_rn_yield
                                    ->{react_nucl_elem_symb}.' number density:'
                            ),
                            $obj_for_cmt->calc_rn_yield
                                ->{react_nucl_elem_num_dens},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val1 g",
                            (
                                $obj_for_cmt->calc_rn_yield
                                    ->{react_nucl_elem_symb}.' mass:'
                            ),
                            $obj_for_cmt->calc_rn_yield
                                ->{react_nucl_elem_mass},
                        ),
                        # Reactant nuclide
                        '',
                        sprintf(
                            " $_conv_cmt2 $_conv_val1",
                            (
                                $obj_for_cmt->calc_rn_yield
                                    ->{react_nucl_symb}.' amount fraction in '.
                                $obj_for_cmt->calc_rn_yield
                                    ->{react_nucl_elem_symb}.':'
                            ),
                            $obj_for_cmt->calc_rn_yield->{react_nucl_amt_frac},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val1",
                            (
                                $obj_for_cmt->calc_rn_yield
                                    ->{react_nucl_symb}.' mass fraction in '.
                                $obj_for_cmt->calc_rn_yield
                                    ->{react_nucl_elem_symb}.':'
                            ),
                            $obj_for_cmt->calc_rn_yield
                                ->{react_nucl_mass_frac},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val1 g cm^{-3}",
                            (
                                $obj_for_cmt->calc_rn_yield
                                    ->{react_nucl_symb}.' mass density:'
                            ),
                            $obj_for_cmt->calc_rn_yield
                                ->{react_nucl_mass_dens},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val2 cm^{-3}",
                            (
                                $obj_for_cmt->calc_rn_yield
                                    ->{react_nucl_symb}.' number density:'
                            ),
                            $obj_for_cmt->calc_rn_yield->{react_nucl_num_dens},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val1 g",
                            (
                                $obj_for_cmt->calc_rn_yield
                                    ->{react_nucl_symb}.' mass:'
                            ),
                            $obj_for_cmt->calc_rn_yield->{react_nucl_mass},
                        ),
                        # PWMs
                        '',
                        sprintf(
                            " $_conv_cmt2 $_conv_val2 %s^{-1}",
                            'Sum of microscopic PWMs:',
                            $obj_for_cmt->calc_rn_yield->{pwm_micro_tot},
                            $phits->source->spat_dist_of_int->{proj}{val},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val2 cm^{-3} %s^{-1}",
                            'Sum of macroscopic PWMs:',
                            $obj_for_cmt->calc_rn_yield->{pwm_macro_tot},
                            $phits->source->spat_dist_of_int->{proj}{val},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val2 cm^{-3} s^{-1}",
                            'Sum of per-vol reaction rates:',
                            $obj_for_cmt->calc_rn_yield
                                ->{react_rate_per_vol_tot},
                        ),
                        sprintf(
                            " $_conv_cmt2 $_conv_val2 s^{-1} or Bq",
                            'Sum of reaction rates:',
                            $obj_for_cmt->calc_rn_yield->{react_rate_tot},
                        ),
                        ' (= saturation yield)',
                        "-" x 69,
                    ],
                },
                {  # Columnar
                    size     => $yield_objs{$k}{size},  # Col size validation
                    heads    => $yield_objs{$k}{heads},
                    subheads => $yield_objs{$k}{subheads},
                    data_arr_ref => $yield_objs{$k}{columnar_arr},
                    sum_idx_multiples =>
                        $yield_objs{$k}{sum} // [],
                    ragged_left_idx_multiples =>
                        $yield_objs{$k}{ragged_left} // [],
                    freeze_panes => 'D4',  # Alt: {row => 3, col => 3}
                    space_bef    => {dat => " ", tex => " "},
                    heads_sep    => {dat => "|", csv => ","},
                    space_aft    => {dat => " ", tex => " "},
                    data_sep     => {dat => " ", csv => ","},
                }
            );
        }
    }

    return;
}


sub outer_iterator {
    # """Iterate over target materials with varying source parameters."""
    my (
        $prog_info_href,
        $run_opts_href,
    ) = @_;

    # Array ref of varying source parameters
    my $v_src_params_href;
    if ($phits->source->iter_param =~ /eg0/i) {
        $v_src_params_href =
            $phits->source->gaussian_nrg->{$phits->source->iter_param}
                                          {vals_of_int};
        $phits->set_v_src_param(
            name => 'eg0',
            unit => 'MeV',
        );
    }
    else {  # Source spatial distribution parameters; e.g. x_fwhm, xy_fwhms
        $v_src_params_href =
            $phits->source->spat_dist_of_int->{$phits->source->iter_param}
                                              {vals_of_int};
        $phits->set_v_src_param(
            name => $phits->source->spat_dist_of_int->
                        {$phits->source->iter_param}
                        {flag},
            unit => 'cm',
        );
    }
    $phits->set_v_src_param(
        start => $v_src_params_href->[0],
        stop  => $v_src_params_href->[-1],
        # 'curr' will be given a value in the loop of @v_src_params.
    );
    my @v_src_params = @$v_src_params_href;

    # Iterate over the varying source parameters.
    my ($src_eg0, $src_size, $src_size_str);

    # Conversion for annotations
    my %_geom_val_conv;
    $_geom_val_conv{dec_places_len} = 0;
    my @_v_src_params = @v_src_params;
    foreach (@_v_src_params) {
        $_ *= 1e1 if (
            not $phits->source->iter_param =~ /eg0/i
            and $angel->dim_unit =~ /mm/i
        );
        $_ *= 1e4 if (
            not $phits->source->iter_param =~ /eg0/i
            and $angel->dim_unit =~ /um/i
        );
        $_geom_val_conv{dec} = index((reverse $_), '.');
        $_geom_val_conv{dec} = 0 if $_geom_val_conv{dec} == -1;
        $_geom_val_conv{dec_places_len} = $_geom_val_conv{dec} if (
            $_geom_val_conv{dec} > $_geom_val_conv{dec_places_len}
        );
    }
    $_geom_val_conv{the_conv} = '%.'.$_geom_val_conv{dec_places_len}.'f';

    #**************************************************************************
    # Real outer iteration
    #**************************************************************************
    foreach my $v_src_param (@v_src_params) {
        #
        # Initializations: Must be performed
        #

        # Varying/fixed source parameters (1/2): Source energy
        if ($phits->source->iter_param =~ /eg0/i) {
            # Source energy: Varying
            if ($phits->source->nrg_dist_of_int->{type}{val} == 2) {
                $src_eg0 = $v_src_param;
                # Populate the Gaussian energy cutoffs and
                # determine the emin and emax of tallies.
                # > Although the two routines below had already been called
                #   in phitar(), they must be called repeatedly for
                #   every varying Gaussian center energy.
                # > This is because the Gaussian energy cutoffs are determined
                #   by the Gaussian center energy, and the effective tally emax
                #   is determined by the upper Gaussian energy cutoff.
                populate_gaussian_nrg_cutoffs($src_eg0);
                determ_tally_emin_emax($src_eg0);
            }
            elsif ($phits->source->nrg_dist_of_int->{type}{val} == 22) {
                my $_err_msg = sprintf(
                    "[Source energy distribution No. %d: %s]".
                    " is incompatible with [eg0] iteration.\n".
                    "Instead, use of one these: [%s]\n\n",
                    $phits->source->nrg_dist_of_int->{type}{val},
                    $phits->source->nrg_dist_of_int->{type}{abbr},
                    join(
                        ', ',
                        qw(
                            rad
                            x_fwhm
                            y_fwhm
                            z_fwhm
                            xy_fwhms
                        ),
                    ),
                );
                croak $_err_msg;
            }

            # Source size: Fixed
            if ($phits->source->spat_dist_of_int->{type}{val} == 1) {
                $src_size = $phits->source->spat_dist_of_int->{rad}{val_fixed};
            }
            elsif ($phits->source->spat_dist_of_int->{type}{val} == 3) {
                $src_size = sprintf(
                    # $src_size is passed to inner_iterator() but
                    # the values of {val_fixed} will be separately used
                    # around the [source] section; namely, $src_size here
                    # are only for displaying purposes.
                    "%s%s%s%s%s",
                    $phits->source->spat_dist_of_int->{x_fwhm}{val_fixed},
                    $phits->source->spat_dist_of_int->{xyz_sep},
                    $phits->source->spat_dist_of_int->{y_fwhm}{val_fixed},
                    $phits->source->spat_dist_of_int->{xyz_sep},
                    $phits->source->spat_dist_of_int->{z_fwhm}{val_fixed},
                );
            }
            else {  # $phits->source->spat_dist_of_int->{type}{val} == 13
                $src_size = $phits->source->spat_dist_of_int
                    ->{xy_fwhms}{val_fixed};
            }
        }

        # Varying/fixed source parameters (2/3): Source size
        else {
            # Source energy: Fixed
            $src_eg0 = $phits->source->gaussian_nrg->{eg0}{val_fixed};

            # Source size: Varying
            $src_size = $v_src_param;
        }

        # Varying/fixed source parameters (3/3): Display the source parameters.
        print "^" x 70, "\n\n";
        printf(
            "%sSource spatial distribution: [%s]\n",
            ' ' x 15,
            $phits->source->spat_dist_of_int->{type}{abbr},
        );
        printf("%sSource size: [", ' ' x 15);
        print $phits->v_src_param->{name}." "
            if $phits->v_src_param->{name} !~ /eg0/i;
        print $src_size;
        print "]<--Unit: cm\n";
        print "\n", "^" x 70, "\n";

        # . --> p in source size strings
        ($src_size_str = $src_size) =~ s/[.]/p/;

        # Initialize animation raster subdir names used in the previous run
        $animate->clear_examined_dirs();

        # Memorize the current value of the varying source parameter.
        $phits->set_v_src_param(curr => $v_src_param);

        # (conditional) Populate the annot attribute - outer (beam).
        # > Look up "Populate the annot attribute - inner (geom)".
        if ($angel->Cmt->annot_type =~ /beam/i) {
            if (not $phits->source->iter_param =~ /eg0/i) {
                my $_beam_size_val = $phits->v_src_param->{curr};
                $_beam_size_val *= 1e1 if $angel->dim_unit =~ /mm/i;
                $_beam_size_val *= 1e4 if $angel->dim_unit =~ /um/i;
                $angel->Cmt->set_annot(
                    sprintf(
                        "Incident e^\{\$-\$\} beam size:".
                        " $_geom_val_conv{the_conv} %s in %s",
                        $_beam_size_val,
                        (
                            $angel->dim_unit =~ /um/i ?
                                '{\mu}m' : $angel->dim_unit
                        ),
                        $phits->Cmt->full_names->{$phits->v_src_param->{name}},
                    )
                );
            }
            else {
                $angel->Cmt->set_annot(
                    sprintf(
                        "Incident e^\{\$-\$\} beam %s:".
                        " $_geom_val_conv{the_conv} %s",
                        $phits->Cmt->full_names->{$phits->v_src_param->{name}},
                        $phits->v_src_param->{curr},
                        $phits->v_src_param->{unit},
                    )
                );
            }
        }

        # Notify the beginning of the iteration.
        say "";
        say $phits->Cmt->borders->{'*'};
        printf(
            "%s [%s] running at [%s: %s / %s--%s %s]...\n",
            $phits->Cmt->symb,
            (caller(0))[3],
            $phits->v_src_param->{name},
            $v_src_param,
            $v_src_params[0],
            $v_src_params[-1],
            $phits->v_src_param->{unit},
        );
        say $phits->Cmt->borders->{'*'};

        # Make a subdirectory wrto the varying source parameter
        # and move to that subdirectory to work on.
        chdir $phits->cwd;  # Start from the parent dir.
        $phits->FileIO->set_subdir(
            $phits->cwd.
            $phits->FileIO->path_delim.(
                $phits->source->iter_param =~ /eg0/i ?
                    'eg0_'.$src_eg0 :
                    $phits->source->spat_dist_of_int
                        ->{$phits->source->iter_param}{flag}.$src_size_str
            )
        );
        if (not -e $phits->FileIO->subdir) {
            mkdir $phits->FileIO->subdir;

            say "";
            say "[".$phits->FileIO->subdir."] mkdir-ed.";
            say " ".('^' x length($phits->FileIO->subdir));
        }
        chdir $phits->FileIO->subdir;
        printf("CWD: [%s]\n", getcwd());

        # Invoke inner_iterator() for each target material.
        # > The iterator is invoked for each of the designated
        #   varying geometric parameters (e.g. height, radius, ...)
        #   of the target material in question (e.g. w_rcc, mo_rcc, ...).
        # > Remember that we are now within the outer iterator;
        #   the series of inner_iterator() invocation below will continue
        #   with the next, if any, outer iteration source parameter
        #   (e.g. eg = 31, 32, ...).
        inner_iterator(
            $prog_info_href,
            $run_opts_href,
            $src_eg0,
            $src_size,
            $bconv,
            $_,
        ) for @{$bconv->iter_geoms};
        inner_iterator(
            $prog_info_href,
            $run_opts_href,
            $src_eg0,
            $src_size,
            $motar_rcc,
            $_,
        ) for @{$motar_rcc->iter_geoms};
        inner_iterator(
            $prog_info_href,
            $run_opts_href,
            $src_eg0,
            $src_size,
            $motar_trc,
            $_,
        ) for @{$motar_trc->iter_geoms};
    }

    return;
}


sub inner_iterator {
    # """Inner: Iterate over geometric parameters."""
    my (
        $prog_info_href,
        $run_opts_href,
        $source_eg0,
        $source_size,
        $tar_of_int,
        $v_geom,
    ) = @_;

    state $tot_flues_hash_ref = {};
    my %tot_flues = %$tot_flues_hash_ref;


    #
    # Validate the 4th subroutine argument.
    #
    return if not $v_geom;
    my $passed = first { /\b$v_geom\b/i }
        @{$phits->constraint_args->{v_geom}};
    unless ($passed) {
        croak(
            "[$v_geom] is a wrong iteration geometry".
            " to the [inner_iterator] subroutine.\n".
            "Input one of these: [".join(
                ', ', @{$phits->constraint_args->{v_geom}}
            )."]\n"
        );
    }


    #
    # Initializations
    #
    # (1) Update the attributes dependent on the varying geometric parameters.
    # (2) Initializations
    #

    # Electron linac parameters
    $elinac_of_int->update_params(peak_beam_nrg => $source_eg0 * 1e+06);

    #+++++debugging+++++#
#    show_tar_geoms();
#    show_linac_params();
    #+++++++++++++++++++#

    # MC calculation space
    if ($mc_space->cell_mat !~ /vac/i) {
        #
        # Materials
        # i.   Bremsstrahlung converter
        # ii.  Molybdenum target
        # iii. Flux monitor, upstream
        # iv.  Flux monitor, downstream
        # v.   Target wrap
        my $_num_mats_to_score = 0;
        $_num_mats_to_score++ if $bconv->flag !~ /none/i;
        $_num_mats_to_score++;  # <--Mo tgt, which is always turned on
        $_num_mats_to_score++ if $flux_mnt_up->height_fixed   > 0;
        $_num_mats_to_score++ if $flux_mnt_down->height_fixed > 0;
        $_num_mats_to_score++ if $tar_wrap->thickness_fixed   > 0;
        my $_num_mats_to_score_cutaway = 0;
        $_num_mats_to_score_cutaway++ if $bconv->flag !~ /none/i;
        $_num_mats_to_score_cutaway++;  # <--Mo tgt, which is always turned on
        $_num_mats_to_score_cutaway++ if $flux_mnt_up->height_fixed   > 0;
        $_num_mats_to_score_cutaway++ if $flux_mnt_down->height_fixed > 0;
        # <---No tar wrapper--->
        my $_mats_of_int = sprintf(
            "   %s\n".
            "%s".
            "%s".      # Optional: Converter
            "%s".      # Required: Mo target
            "%s%s%s",  # Optional: Flux monitors and a target wrapper
            $_num_mats_to_score,
            (' ' x 12),
            (
                $bconv->flag !~ /none/i ?
                    $bconv->cell_props->{mat_id}.' ' : ''
            ),
            $motar->cell_props->{mat_id},
            (
                $flux_mnt_up->height_fixed > 0 ?
                    ' '.$flux_mnt_up->cell_props->{mat_id} : ''
            ),
            (
                $flux_mnt_down->height_fixed > 0 ?
                    ' '.$flux_mnt_down->cell_props->{mat_id} : ''
            ),
            (
                $tar_wrap->thickness_fixed > 0 ?
                    ' '.$tar_wrap->cell_props->{mat_id} : ''
            ),
        );
        # A target wrapper, even if exists, is not shown in the cutaway view.
        my $_mats_of_int_cutaway = sprintf(
            "   %s\n".
            "%s".
            "%s".
            "%s".
            "%s%s",
            $_num_mats_to_score_cutaway,
            (' ' x 12),
            (
                $bconv->flag !~ /none/i ?
                    $bconv->cell_props->{mat_id}.' ' : ''
            ),
            $motar->cell_props->{mat_id},
            (
                $flux_mnt_up->height_fixed > 0 ?
                    ' '.$flux_mnt_up->cell_props->{mat_id} : ''
            ),
            (
                $flux_mnt_down->height_fixed > 0 ?
                    ' '.$flux_mnt_down->cell_props->{mat_id} : ''
            ),
        );

        $t_heat->set_material($_mats_of_int);
        $t_heat_mapdl->set_material($_mats_of_int);
        $t_3dshow->set_material($_mats_of_int);
        $t_3dshow->set_material_cutaway($_mats_of_int_cutaway);
    }

    #
    # Turn off neutron data options for Ir and Pt converters.
    # > Otherwise, the following fatal errors occur:
    #   (i) ir
    #   Error: There is no cross-section table(s) in xsdir.
    #     77191.  c
    #     77193.  c
    #   Please check [material] section,
    #   or set nucdata=0 to disable nuclear data
    #   (ii) Pt
    #   Error: There is no cross-section table(s) in xsdir.
    #     78190.  c
    #     78192.  c
    #     78194.  c
    #     78195.  c
    #     78196.  c
    #     78198.  c
    #   Please check [material] section,
    #   or set nucdata=0 to disable nuclear data
    # > dmax(2) is the culprit. Therefore:
    #   > Set nucdata=0 (which, if turned on, sets dmax(2)=20)
    #   > Do not define dmax(2).
    #
    if ($bconv->cell_mat =~ /ir|pt/i) {
        $phits->params->{nucdata}{val}    = 0;
        # dmax(2) is not written on the PHITS input file
        # if $phits->params->{dmax}{neut}{val} is undefined.
        $phits->params->{dmax}{neut}{val} = undef;
    }

    # Initializations
    $yield_mo99_for_sp_src->clear_columnar_arr();
    $pwm_mo99_for_sp_src->clear_columnar_arr();
    $yield_au196_1_for_sp_src->clear_columnar_arr();
    $pwm_au196_1_for_sp_src->clear_columnar_arr();
    $yield_au196_2_for_sp_src->clear_columnar_arr();
    $pwm_au196_2_for_sp_src->clear_columnar_arr();
    # Empty the filenames of MAPDL macros contained in a target-specific
    # macro-of-macros for the next target.
    $mapdl_of_macs->FileIO->clear_macs();
    # Used for notification
    $t_tot_fluence->Ctrls->init_is_first_run();

    #
    # Construct flag strings that will be used for naming files and subsubdirs.
    #
    # (1) Shorten, if long, the names of geometric parameters.
    # (2) Define the values of the varying geometry and
    #     the flags and values of the fixed geometries
    #     as functions of the shortened varying geometry.
    # (3) Copy-paste the value of {v_geom_vals} defined in (2)
    #     to @v_geom_vals.
    # (4) Copy-paste the value of {fixed_flags_and_vals} defined in (2)
    #     to $fixed_flags_and_vals.
    #     > Values of the fixed geometries included
    #     > $fixed_flags_and_vals will then be used for
    #       naming tally files (look up my $backbone.)
    # (5) Copy-paste the value of {fixed_flags_and_vals} defined in (2)
    #     to $fixed_flags.
    #     > Values of the fixed geometries  EXCLUDED
    #     > $fixed_flags will then be used for set_fixed_flag(); see (6) below.
    # (6) Call the set_varying_flag() set_fixed_flag() setter methods.
    #     The varying_flag and fixed_flag attributes will then be used for
    #     > Subdir names for Ghostscript-rasterized files
    #     > Macro filenames
    #     > Gross fluence retrieval
    #

    # (1)
    my @abbr_hgt = (
        $phits->Cmt->abbrs->{height}[0],
        $phits->Cmt->abbrs->{height}[1]
    );
    my @abbr_rad = (
        $phits->Cmt->abbrs->{radius}[0],
        $phits->Cmt->abbrs->{radius}[1]
    );
    my @abbr_bot_rad = (
        $phits->Cmt->abbrs->{bot_rad}[0],
        $phits->Cmt->abbrs->{bot_rad}[1]
    );
    my @abbr_top_rad = (
        $phits->Cmt->abbrs->{top_rad}[0],
        $phits->Cmt->abbrs->{top_rad}[1]
    );
    my @abbr_gap = (
        $phits->Cmt->abbrs->{gap}[0],
        $phits->Cmt->abbrs->{gap}[1]
    );
    my $v_geom_intact = $v_geom;
    $v_geom_intact =~ s/height/thickness/;  # For titles of ANGEL PS files
    $v_geom =~ s/\b$abbr_hgt[0]/$abbr_hgt[1]/gi;
    $v_geom =~ s/\b$abbr_rad[0]/$abbr_rad[1]/gi;
    $v_geom =~ s/\b$abbr_bot_rad[0]/$abbr_bot_rad[1]/gi;
    $v_geom =~ s/\b$abbr_top_rad[0]/$abbr_top_rad[1]/gi;
    $v_geom =~ s/\b$abbr_gap[0]/$abbr_gap[1]/gi;

    # (2)
    my $_varying_str = $phits->FileIO->varying_str.(
        $t_shared->Ctrls->shortname =~ /on/i ?
            '' : $phits->FileIO->fname_space
    );
    my $_fixed_str = $phits->FileIO->fixed_str.(
        $t_shared->Ctrls->shortname =~ /on/i ?
            '' : $phits->FileIO->fname_space
    );
    my $geom_val_sep = $t_shared->Ctrls->shortname =~ /on/i ?
        '' : $phits->FileIO->fname_space;
    my %functs_of_v_geom = (  # (key) Abbreviated geom, (val) hash ref
        # Varying height; applies to
        # > $bconv
        # > $motar_rcc
        # > $motar_trc
        $abbr_hgt[1] => {
            varying_vals         => $tar_of_int->heights_of_int,
            fixed_flags_and_vals => $tar_of_int->flag eq $motar_trc->flag ? (
                # Fixed bottom radius
                $_fixed_str.                    # f || f_
                $abbr_bot_rad[1].               # brad
                $geom_val_sep.                  # '' || _
                $tar_of_int->bot_radius_fixed.  # 0.15
                # Filename separator
                $phits->FileIO->fname_sep.      # -
                # Fixed top radius
                $_fixed_str.                    # f || f_
                $abbr_top_rad[1].               # trad
                $geom_val_sep.                  # '' || _
                $tar_of_int->top_radius_fixed.  # 0.60
                # Filename separator
                $phits->FileIO->fname_sep.      # -
                # Fixed gap
                $_fixed_str.                    # f || f_
                $abbr_gap[1].                   # gap
                $geom_val_sep.                  # '' || _
                $bconv->gap_fixed               # 0.15
            ) : (
                # Fixed radius
                $_fixed_str.                    # f || f_
                $abbr_rad[1].                   # rad
                $geom_val_sep.                  # '' || _
                $tar_of_int->radius_fixed.      # 1.00
                # Filename separator
                $phits->FileIO->fname_sep.      # -
                # Fixed gap
                $_fixed_str.                    # f || f_
                $abbr_gap[1].                   # gap
                $geom_val_sep.                  # '' || _
                $bconv->gap_fixed               # 0.15
            ),
        },
        # Varying radius; applies to
        # > $bconv
        # > $motar_rcc
        $abbr_rad[1] => {
            varying_vals         => $tar_of_int->radii_of_int,
            fixed_flags_and_vals => (
                # Fixed height
                $_fixed_str.                # f || f_
                $abbr_hgt[1].               # hgt
                $geom_val_sep.              # '' || _
                $tar_of_int->height_fixed.  # 0.33
                # Filename separator
                $phits->FileIO->fname_sep.  # -
                # Fixed gap
                $_fixed_str.                # f || f_
                $abbr_gap[1].               # gap
                $geom_val_sep.              # '' || _
                $bconv->gap_fixed           # 0.15
            ),
        },
        # Varying bottom radius; applies to
        # > $motar_trc
        $abbr_bot_rad[1] => {
            varying_vals         => $tar_of_int->bot_radii_of_int,
            fixed_flags_and_vals => (
                # Fixed height
                $_fixed_str.                    # f || f_
                $abbr_hgt[1].                   # hgt
                $geom_val_sep.                  # '' || _
                $tar_of_int->height_fixed.      # 0.50
                # Filename separator
                $phits->FileIO->fname_sep.      # -
                # Fixed top radius
                $_fixed_str.                    # f || f_
                $abbr_top_rad[1].               # trad
                $geom_val_sep.                  # '' || _
                $tar_of_int->top_radius_fixed.  # 0.60
                # Filename separator
                $phits->FileIO->fname_sep.      # -
                # Fixed gap
                $_fixed_str.                    # f || f_
                $abbr_gap[1].                   # gap
                $geom_val_sep.                  # '' || _
                $bconv->gap_fixed               # 0.15
            ),
        },
        # Varying top radius; applies to
        # > $motar_trc
        $abbr_top_rad[1] => {
            varying_vals         => $tar_of_int->top_radii_of_int,
            fixed_flags_and_vals => (
                # Fixed height
                $_fixed_str.                    # f || f_
                $abbr_hgt[1].                   # hgt
                $geom_val_sep.                  # '' || _
                $tar_of_int->height_fixed.      # 0.50
                # Filename separator
                $phits->FileIO->fname_sep.      # -
                # Fixed bot radius
                $_fixed_str.                    # f || f_
                $abbr_bot_rad[1].               # brad
                $geom_val_sep.                  # '' || _
                $tar_of_int->bot_radius_fixed.  # 0.15
                # Filename separator
                $phits->FileIO->fname_sep.      # -
                # Fixed gap
                $_fixed_str.                    # f || f_
                $abbr_gap[1].                   # gap
                $geom_val_sep.                  # '' || _
                $bconv->gap_fixed               # 0.15
            ),
        },
        # Varying gaps; applies to
        # > $bconv
        $abbr_gap[1] => {
            varying_vals         => $tar_of_int->gaps_of_int,
            fixed_flags_and_vals => (
                # Fixed height
                $_fixed_str.                # f || f_
                $abbr_hgt[1].               # hgt
                $geom_val_sep.              # '' || _
                $bconv->height_fixed.       # 0.33
                # Filename separator
                $phits->FileIO->fname_sep.  # -
                # Fixed radius
                $_fixed_str.                # f || f_
                $abbr_rad[1].               # rad
                $geom_val_sep.              # '' || _
                $tar_of_int->radius_fixed   # 1.00
            ),
        },
    );

    # (3)
    my @v_geom_vals = @{$functs_of_v_geom{$v_geom}{varying_vals}};

    # (4)
    (
        my $fixed_flags_and_vals =
            $functs_of_v_geom{$v_geom}{fixed_flags_and_vals}
    ) =~ s/[.]/p/g;

    # (5)
    (
        my $fixed_flags =
            $functs_of_v_geom{$v_geom}{fixed_flags_and_vals}
    ) =~ s/[0-9.]+//g;
    $fixed_flags =~ s/_-/-/g;  # For $t_shared->Ctrls->shortname =~ /off/i
    $fixed_flags =~ s/--/-/g;  # For $t_shared->Ctrls->shortname =~ /off/i
    $fixed_flags =~ s/[\-_]$//;

    # (6)
    $phits->FileIO->set_varying_flag($_varying_str.$v_geom);  # e.g. vhgt
    $phits->FileIO->set_fixed_flag($fixed_flags);             # e.g. frad-fgap

    #
    # Set the xyze mesh ranges.
    #
    # Condition 1: +-x and +-y are determined by the bremsstrahlung converter.
    # Condition 2: -z is determined by the entrance of the converter,
    #              +z by the exit of the molybdenum target.
    #
    $t_shared->set_mesh_ranges(
        xmin => -($bconv->radius_fixed + $t_shared->offsets->{x}),
        xmax =>  ($bconv->radius_fixed + $t_shared->offsets->{x}),
        ymin => -($bconv->radius_fixed + $t_shared->offsets->{y}),
        ymax =>  ($bconv->radius_fixed + $t_shared->offsets->{y}),
        zmin => $bconv->beam_ent - $t_shared->offsets->{z},
        zmax =>  # z-coordinate of the molybdenum target entrance
                (
                    $bconv->beam_ent
                    + $bconv->height_fixed
                    + $bconv->gap_fixed
                )
                # Increase the z-coordinate to the molybdenum target exit.
                + (
                    $tar_of_int->flag eq $motar_trc->flag ?
                        $motar_trc->height_fixed : $motar_rcc->height_fixed
                )
                # Add the z-offset.
                + $t_shared->offsets->{z},
    );

    # If a bremsstrahlung converter is the target of interest and
    # its radius is to be varied, overwrite the xy mesh ranges
    # using the "largest" radius of the converter.
    if (
        $tar_of_int->flag eq $bconv->flag
        and $v_geom =~ /\b($abbr_rad[0]|$abbr_rad[1])/i
    ) {
        $t_shared->set_mesh_ranges(
            xmin => -($bconv->radii_of_int->[-1] + $t_shared->offsets->{x}),
            xmax =>  ($bconv->radii_of_int->[-1] + $t_shared->offsets->{x}),
            ymin => -($bconv->radii_of_int->[-1] + $t_shared->offsets->{y}),
            ymax =>  ($bconv->radii_of_int->[-1] + $t_shared->offsets->{y}),
        );
    }

    # If a bremsstrahlung converter is the target of interest and
    # its distance to the molybdenum target (i.e. gap) is to be varied,
    # extend the z-max mesh using the "largest" gap.
    if (
        $tar_of_int->flag eq $bconv->flag
        and $v_geom =~ /\b($abbr_gap[0]|$abbr_gap[1])/i
    ) {
        $t_shared->set_mesh_ranges(
            zmax => $t_shared->mesh_ranges->{zmax}
                    # Replace $bconv->gap_fixed
                    # with    $bconv->gaps_of_int->[-1]
                    - $bconv->gap_fixed
                    + $bconv->gaps_of_int->[-1]
        );
    }

    # If a molybdenum target is the target of interest and
    # its height is to be varied, extend the z-max mesh
    # using the "largest" height of the molybdenum target.
    if (
        $tar_of_int->flag ne $bconv->flag
        and $v_geom =~ /\b($abbr_hgt[0]|$abbr_hgt[1])/i
    ) {
        $t_shared->set_mesh_ranges(
            zmax => $t_shared->mesh_ranges->{zmax}
                    # Replace $tar_of_int->height_fixed
                    # with    $tar_of_int->heights_of_int->[-1]
                    - (
                        $tar_of_int->flag eq $motar_trc->flag ?
                            $motar_trc->height_fixed : $motar_rcc->height_fixed
                    )
                    + $tar_of_int->heights_of_int->[-1]
        );
    }

    #
    # Create a sub-subdirectory with respect to
    # the varying geometric parameter, and
    # move to and work on that directory.
    #
    chdir $phits->FileIO->subdir;  # Start from the parent dir.
    $phits->FileIO->set_subsubdir(
        $tar_of_int->flag.
        $phits->FileIO->fname_sep.
        $phits->FileIO->varying_flag.
        $phits->FileIO->fname_sep.
        $phits->FileIO->fixed_flag.(
            $phits->source->mode =~ /du?mp/i ?
            (
                $phits->FileIO->fname_space.
                $t_cross_dump->particles_of_int->[0].
                $t_cross_dump->dump->{suffix}
            ) : ''
        )
    );
    if (not -e $phits->FileIO->subsubdir) {
        mkdir $phits->FileIO->subsubdir;

        say "";
        say "[".$phits->FileIO->subsubdir."] mkdir-ed.";
        say " ".('^' x length($phits->FileIO->subsubdir));
    }
    chdir $phits->FileIO->subsubdir;


    #
    # Inner iteration
    #
    # Step 1. Generate a PHITS input (.inp) and an MAPDL macro (.mac)
    #         with respect to the varying geometric parameter.
    # Step 2. Run phits.bat:            .inp --> .ang
    #         Modify and memorize .ang: .ang --> .ang
    #         Memorize nps from the summary output file (.out).
    # Step 3. Generate MAPDL tab files: .ang --> .tab
    # Step 4. Run angel.bat:            .ang --> .eps
    #         Modify .eps:              .eps --> .eps
    # Step 5. Run gs.exe (or Win ver):  .eps --> .pdf, .png, .jpg
    #         Run inkscape.exe:         .eps --> .svg, .emf, .wmf
    #         Memorize .png/.jpg dirs for the Step 7
    # Step 6. Calculate the yields and specific yields of
    #         Mo-99 and/or Au-196, and generate data files.
    #
    # Below: Outside the inner iteration
    # Step 7. Run magick.exe: .png/.jpg --> .gif
    #         Run ffmpeg.exe: .gif      --> .mp4/.avi
    # Step 8. Generate MAPDL macro-of-macro files (.mac).
    # Step 9. Retrieve max total fluences from the tally files (.ang).
    #

    # Conversion for annotations
    my %_geom_val_conv;
    $_geom_val_conv{dec_places_len} = 0;
    my @_v_geom_vals = @v_geom_vals;
    foreach (@_v_geom_vals) {
        $_ *= 1e1 if $angel->dim_unit =~ /mm/i;
        $_ *= 1e4 if $angel->dim_unit =~ /um/i;
        $_geom_val_conv{dec} = index((reverse $_), '.');
        $_geom_val_conv{dec} = 0 if $_geom_val_conv{dec} == -1;
        $_geom_val_conv{dec_places_len} = $_geom_val_conv{dec} if (
            $_geom_val_conv{dec}
            > $_geom_val_conv{dec_places_len}
        );
    }
    $_geom_val_conv{the_conv} = '%.'.$_geom_val_conv{dec_places_len}.'f';

    #**************************************************************************
    # Real inner iteration
    #**************************************************************************
    $phits->set_v_geom_param(
        start => $v_geom_vals[0],
        stop  => $v_geom_vals[-1],
        # 'curr' will be given a value in the loop of @v_geom_vals below.
    );
    foreach my $v_geom_val (@v_geom_vals) {
        # Initializations
        $phits->clear_sects();  # Prevents repeating input lines.
        $t_track->reset_t_counter();
        $t_cross->reset_t_counter();
        $t_cross_dump->reset_t_counter();
        $t_heat->reset_t_counter();
        $t_gshow->reset_t_counter();
        $t_3dshow->reset_t_counter();
        $t_subtotal->reset_t_counter();  # Number of tallies of an input file
        # Note: $t_total->t_counter, which represents the number of tallies
        #       of a run of phitar, is not reset.
        $angel->Ctrls->init_is_first_run();
        $angel->clear_ang_fnames();  # Prevents rerunning ANGEL on prev val.
        $image->Ctrls->init_is_first_run();
        $phits->set_v_geom_param(curr => $v_geom_val);

        # (conditional) Populate the annot attribute - inner (geom).
        # > Look up "Populate the annot attribute - outer (beam)".
        if ($angel->Cmt->annot_type =~ /geom/i) {
            my $_geom_val = $v_geom_val;
            $_geom_val *= 1e1 if $angel->dim_unit =~ /mm/i;
            $_geom_val *= 1e4 if $angel->dim_unit =~ /um/i;
            (my $_tar_of_int_cell_mat = $tar_of_int->cell_mat);
            $angel->Cmt->set_annot(
                sprintf(
                    "%s %s: $_geom_val_conv{the_conv} %s",
                    "\u$_tar_of_int_cell_mat",  # First letter uppercased
                    $v_geom_intact,
                    $_geom_val,
                    $angel->dim_unit,
                )
            );
        }

        # Notify the beginning of the iteration.
        say "";
        say $phits->Cmt->borders->{'*'};
        printf(
            "%s [%s] running at [%s: %s / %s--%s cm]...\n",
            $phits->Cmt->symb, (caller(0))[3],
            $phits->FileIO->varying_flag,
            $phits->v_geom_param->{curr},
            $phits->v_geom_param->{start},
            $phits->v_geom_param->{stop},
        );
        say $phits->Cmt->borders->{'*'};
        printf("CWD: [%s]\n", getcwd());

        #-----------------------------------------------------------
        # Step 1
        # Generate a PHITS input (.inp) and an MAPDL macro (.mac)
        # with respect to the varying geometric parameter.
        #-----------------------------------------------------------

        #
        # Assign varying or fixed values to the radii and heights
        # of the macrobodies "and" calculate their volumes.
        # The calculated volumes will be written to the volume section,
        # which is necessary for tallies having region-wise meshes.
        # (to be specific, it is necessary for volume-averaged fluence.)
        # The values of these dimensional parameters will also be used for
        # constructing the names of the PHITS input files.
        #

        # Bremsstrahlung converter
        $bconv->set_height(
            (
                $tar_of_int->flag eq $bconv->flag
                and $v_geom =~ /\b($abbr_hgt[0]|$abbr_hgt[1])/i
            ) ? $v_geom_val : $bconv->height_fixed
        );
        $bconv->set_radius(
            (
                $tar_of_int->flag eq $bconv->flag
                and $v_geom =~ /\b($abbr_rad[0]|$abbr_rad[1])/i
            ) ? $v_geom_val : $bconv->radius_fixed
        );
        $bconv->set_gap(
            (
                $tar_of_int->flag eq $bconv->flag
                and $v_geom =~ /\b($abbr_gap[0]|$abbr_gap[1])/i
            ) ? $v_geom_val : $bconv->gap_fixed
        );
        $bconv->set_vol(
            calc_vol(
                {
                    shape => 'rcc',
                    rcc => {
                        radius => $bconv->radius,
                        height => $bconv->height,
                    },
                }
            )
        );
        $bconv->set_mass($bconv->cell_props->{dens} * $bconv->vol);
        # Molybdenum target, RCC
        $motar_rcc->set_beam_ent(
            $bconv->beam_ent + $bconv->height + $bconv->gap
        );
        $motar_rcc->set_height(
            (
                $tar_of_int->flag eq $motar_rcc->flag
                and $v_geom =~ /\b($abbr_hgt[0]|$abbr_hgt[1])/i
            ) ? $v_geom_val : $motar_rcc->height_fixed
        );
        $motar_rcc->set_radius(
            (
                $tar_of_int->flag eq $motar_rcc->flag
                and $v_geom =~ /\b($abbr_rad[0]|$abbr_rad[1])/i
            ) ? $v_geom_val : $motar_rcc->radius_fixed
        );
        $motar_rcc->set_vol(
            calc_vol(
                {
                    shape => 'rcc',
                    rcc => {
                        radius => $motar_rcc->radius,
                        height => $motar_rcc->height,
                    },
                }
            )
        );
        $motar_rcc->set_mass($motar->cell_props->{dens} * $motar_rcc->vol);
        # Molybdenum target, TRC
        $motar_trc->set_beam_ent(
            $bconv->beam_ent + $bconv->height + $bconv->gap
        );
        $motar_trc->set_height(
            (
                $tar_of_int->flag eq $motar_trc->flag
                and $v_geom =~ /\b($abbr_hgt[0]|$abbr_hgt[1])/i
            ) ? $v_geom_val : $motar_trc->height_fixed
        );
        $motar_trc->set_bot_radius(
            (
                $tar_of_int->flag eq $motar_trc->flag
                and $v_geom =~ /\b($abbr_bot_rad[0]|$abbr_bot_rad[1])/i
            ) ? $v_geom_val : $motar_trc->bot_radius_fixed
        );
        $motar_trc->set_top_radius(
            (
                $tar_of_int->flag eq $motar_trc->flag
                and $v_geom =~ /\b($abbr_top_rad[0]|$abbr_top_rad[1])/i
            ) ? $v_geom_val : $motar_trc->top_radius_fixed
        );
        $motar_trc->set_vol(
            calc_vol(
                {
                    shape => 'trc',
                    trc => {
                        bot_radius => $motar_trc->bot_radius,
                        top_radius => $motar_trc->top_radius,
                        height     => $motar_trc->height,
                    },
                }
            )
        );
        $motar_trc->set_mass($motar->cell_props->{dens} * $motar_trc->vol);
        # Molybdenum target, delegate
        $motar->set_vol(
            $tar_of_int->flag eq $motar_trc->flag ?
                $motar_trc->vol : $motar_rcc->vol
        );
        # [Mat for expt] Flux monitor, upstream
        $flux_mnt_up->set_height(
            # 2019-04-17 updated:
            # No flux monitor for TRC-shaped Mo target
            $tar_of_int->flag eq $motar_trc->flag ?
                0 : $flux_mnt_up->height_fixed
        );
        $flux_mnt_up->set_beam_ent(
            $motar_rcc->beam_ent
            - $flux_mnt_up->height
        );
        $flux_mnt_up->set_radius($flux_mnt_up->radius_fixed);
        $flux_mnt_up->set_vol(
            calc_vol(
                {
                    shape => 'rcc',
                    rcc => {
                        radius => $flux_mnt_up->radius,
                        height => $flux_mnt_up->height,
                    },
                }
            )
        );
        $flux_mnt_up->set_mass(
            $flux_mnt_up->cell_props->{dens}
            * $flux_mnt_up->vol
        );
        # [Mat for expt] Flux monitor, downstream
        $flux_mnt_down->set_height(
            # 2019-04-17 updated:
            # No flux monitor for TRC-shaped Mo target
            $tar_of_int->flag eq $motar_trc->flag ?
                0 : $flux_mnt_down->height_fixed
        );
        $flux_mnt_down->set_beam_ent(
            $motar_rcc->beam_ent
            + $motar_rcc->height
        );
        $flux_mnt_down->set_radius($flux_mnt_down->radius_fixed);
        $flux_mnt_down->set_vol(
            calc_vol(
                {
                    shape => 'rcc',
                    rcc => {
                        radius => $flux_mnt_down->radius,
                        height => $flux_mnt_down->height,
                    },
                }
            )
        );
        $flux_mnt_down->set_mass(
            $flux_mnt_down->cell_props->{dens}
            * $flux_mnt_down->vol
        );
        # [Mat for expt] Aluminum foil wrapper
        $tar_wrap->set_thickness(
            # 2019-04-17 updated:
            # No aluminum foil wrapper for TRC-shaped Mo target
            $tar_of_int->flag eq $motar_trc->flag ?
                0 : $tar_wrap->thickness_fixed
        );
        $tar_wrap->set_beam_ent($flux_mnt_up->beam_ent - $tar_wrap->thickness);
        $tar_wrap->set_height(
            $tar_wrap->thickness + $flux_mnt_up->height  # Upstream
            + $motar_rcc->height
            + $flux_mnt_down->height + $tar_wrap->thickness  # Downstream
        );
        $tar_wrap->set_radius($motar_rcc->radius + $tar_wrap->thickness);
        $tar_wrap->set_vol(
            calc_vol(
                {
                    shape => 'rcc',
                    rcc => {
                        radius => $tar_wrap->radius,
                        height => $tar_wrap->height,
                    },
                }
            )
        );
        # Molybdenum target entrance for dump file generation
        $motar_ent_to = $tar_of_int->flag eq $motar_trc->flag ? $motar_trc :
                                                                $motar_rcc;
        foreach ($flux_mnt_up, $tar_wrap) {
            $motar_ent_to = $_ if ($_->beam_ent) < ($motar_ent_to->beam_ent);
        }
        $motar_ent->set_height($motar_ent->height_fixed);
        $motar_ent->set_beam_ent(
            $motar_ent_to->beam_ent
            - $motar_ent->height
        );
        $motar_ent->set_radius($motar_rcc->radius);
        $motar_ent->set_area(
            calc_area(
                {
                    shape => 'circ',
                    circ => {
                        radius => $motar_ent->radius,
                    },
                }
            )
        );
        $motar_ent->set_vol(
            $motar_ent->area * $motar_ent->height
        );
        $motar_ent->set_mass(
            $motar_ent->cell_props->{dens} ?
                $motar_ent->vol * $motar_ent->cell_props->{dens} : 0
        );

        #
        # angel: 'p:' parameters
        #

        # cmmm/cmum for axis=xyz
        my $_t_track_xyz_angel = $angel->orientation;
        $_t_track_xyz_angel .= " nofr"
            if $angel->Ctrls->noframe_switch =~ /on/i;
        $_t_track_xyz_angel .= " noms"
            if $angel->Ctrls->nomessage_switch =~ /on/i;
        $_t_track_xyz_angel .= sprintf(" cm%s", $angel->dim_unit)
            if $angel->dim_unit !~ /cm/i;
        my $_t_3dshow_polar_angel = $_t_track_xyz_angel;
        $_t_track_xyz_angel .= " nolg"
            if $angel->Ctrls->nolegend_switch =~ /on/i;
        $t_track->xz->set_angel($_t_track_xyz_angel);
        $t_track->yz->set_angel($_t_track_xyz_angel);
        $t_track->xy_bconv->set_angel($_t_track_xyz_angel);
        $t_track->xy_motar->set_angel_mo($_t_track_xyz_angel);
        $t_track->xz->set_angel($_t_track_xyz_angel);
        $t_heat->xz->set_angel($_t_track_xyz_angel);
        $t_heat->yz->set_angel($_t_track_xyz_angel);
        $t_heat->xy_bconv->set_angel($_t_track_xyz_angel);
        $t_heat->xy_motar->set_angel_mo($_t_track_xyz_angel);
        $t_heat->rz_bconv->set_angel($_t_track_xyz_angel);
        $t_heat->rz_motar->set_angel($_t_track_xyz_angel);
        $t_gshow->xz->set_angel($_t_track_xyz_angel);
        $t_gshow->yz->set_angel($_t_track_xyz_angel);
        $t_gshow->xy_bconv->set_angel($_t_track_xyz_angel);
        $t_gshow->xy_motar->set_angel_mo($_t_track_xyz_angel);
        $t_3dshow->polar1->set_angel($_t_3dshow_polar_angel);
        $t_3dshow->polar2->set_angel($_t_3dshow_polar_angel);

        # ymin, ymax for axis=eng, t_track
        my $_t_track_nrg_angel = sprintf(
            "%s ymin(%s) ymax(%s)",
            $angel->orientation,
            $t_track->mesh_ranges->{ymin},
            $t_track->mesh_ranges->{ymax},
        );
        $_t_track_nrg_angel .= " nofr"
            if $angel->Ctrls->noframe_switch =~ /on/i;
        $_t_track_nrg_angel .= " noms"
            if $angel->Ctrls->nomessage_switch =~ /on/i;
        $t_track->nrg_bconv->set_angel($_t_track_nrg_angel);
        $t_track->nrg_bconv_low_emax->set_angel($_t_track_nrg_angel);
        $t_track->nrg_motar->set_angel($_t_track_nrg_angel);
        $t_track->nrg_motar_low_emax->set_angel($_t_track_nrg_angel);
        $t_track->nrg_flux_mnt_up->set_angel($_t_track_nrg_angel);
        $t_track->nrg_flux_mnt_down->set_angel($_t_track_nrg_angel);

        # ymin, ymax for axis=eng, t_cross
        my $_t_cross_nrg_angel = sprintf(
            "%s ymin(%s) ymax(%s)",
            $angel->orientation,
            $t_cross->mesh_ranges->{ymin},
            $t_cross->mesh_ranges->{ymax},
        );
        $_t_cross_nrg_angel .= " nofr"
            if $angel->Ctrls->noframe_switch =~ /on/i;
        $_t_cross_nrg_angel .= " noms"
            if $angel->Ctrls->nomessage_switch =~ /on/i;
        $_t_cross_nrg_angel .= sprintf(" cm%s", $angel->dim_unit)
            if $angel->dim_unit !~ /cm/i;
        $t_cross->nrg_intact->set_angel($_t_cross_nrg_angel);
        $t_cross->nrg_intact_low_emax->set_angel($_t_cross_nrg_angel);
        $t_cross->nrg_bconv_ent->set_angel($_t_cross_nrg_angel);
        $t_cross->nrg_bconv_ent_low_emax->set_angel($_t_cross_nrg_angel);
        $t_cross->nrg_bconv_exit->set_angel($_t_cross_nrg_angel);
        $t_cross->nrg_bconv_exit_low_emax->set_angel($_t_cross_nrg_angel);
        $t_cross->nrg_motar_ent->set_angel($_t_cross_nrg_angel);
        $t_cross->nrg_motar_ent_low_emax->set_angel($_t_cross_nrg_angel);
        $t_cross->nrg_motar_exit->set_angel($_t_cross_nrg_angel);
        $t_cross->nrg_motar_exit_low_emax->set_angel($_t_cross_nrg_angel);

        #
        # sangel: Annotations for MC cell materials
        #
        my (
            %_bconv_aw,
            %_motar_aw,
            %_flux_mnt_up_aw,
            %_flux_mnt_down_aw,
            %_tar_wrap_aw,
            %_src_ab,
            %_src_w,
            %_unit_w,
        );

        # Bremsstrahlung converter
        $_bconv_aw{mat} = $bconv->cell_props->{mat_lab_name} ?
            $bconv->cell_props->{mat_lab_name} : '',
        $_bconv_aw{mat} =~ s/\\//g;  # Backslashes are not necessary for annots
        $_bconv_aw{ax} = $bconv->beam_ent + ($bconv->height / 2.0);
        $_bconv_aw{ay} = -$bconv->radius;
        $_bconv_aw{x}  = $_bconv_aw{ax} + 0.0;  # 0.0: same line as x
        $_bconv_aw{y}  = $_bconv_aw{ay} - 0.8;
        $_bconv_aw{0}  = 0;
        # Molybdenum target
        ($_motar_aw{mat} = $motar->cell_props->{mat_lab_name})
            =~ s/\\//g;
        $_motar_aw{ax} = $tar_of_int->flag eq $motar_trc->flag ?
            $motar_trc->beam_ent + ($motar_trc->height / 2.5) :
            $motar_rcc->beam_ent + ($motar_rcc->height / 2.5);
        $_motar_aw{ay} = -(
            $tar_of_int->flag eq $motar_trc->flag ?
                $motar_trc->top_radius / 2.0 :
                $motar_rcc->radius
        );
        $_motar_aw{x} = $_motar_aw{ax} + 0.5;
        $_motar_aw{y} = $_motar_aw{ay} - 1.0;
        $_motar_aw{0} = 0;
        # Flux monitor, upstream
        ($_flux_mnt_up_aw{mat} = $flux_mnt_up->cell_props->{mat_lab_name})
            =~ s/\\//g;
        $_flux_mnt_up_aw{ax} =
            $flux_mnt_up->beam_ent
            + ($flux_mnt_up->height / 2.0);
        $_flux_mnt_up_aw{ay} = $flux_mnt_up->radius;
        $_flux_mnt_up_aw{x}  = $_flux_mnt_up_aw{ax} + 0.5;
        $_flux_mnt_up_aw{y}  = $_flux_mnt_up_aw{ay} + 1.0;
        $_flux_mnt_up_aw{0}  = 0;
        # Flux monitor, downstream
        ($_flux_mnt_down_aw{mat} = $flux_mnt_down->cell_props->{mat_lab_name})
            =~ s/\\//g;
        $_flux_mnt_down_aw{ax} =
            $flux_mnt_down->beam_ent
            + ($flux_mnt_down->height / 2.0);
        $_flux_mnt_down_aw{ay} = $flux_mnt_down->radius;
        $_flux_mnt_down_aw{x}  = $_flux_mnt_down_aw{ax} + 0.5;
        $_flux_mnt_down_aw{y}  = $_flux_mnt_down_aw{ay} + 0.4;
        $_flux_mnt_down_aw{0}  = 0;
        # Target wrap
        ($_tar_wrap_aw{mat} = $tar_wrap->cell_props->{mat_lab_name})
            =~ s/\\//g;
        $_tar_wrap_aw{ax} =
            $tar_wrap->beam_ent + ($tar_wrap->height / 1.5);
        $_tar_wrap_aw{ay} = -$tar_wrap->radius;
        $_tar_wrap_aw{x}  = $_tar_wrap_aw{ax} + 0.8;
        $_tar_wrap_aw{y}  = $_tar_wrap_aw{ay} - 0.4;
        $_tar_wrap_aw{0}  = 0;
        # Source propagation direction
        $_src_ab{x}   = -1.5;
        $_src_ab{ax}  = $_src_ab{x} + 1.4;
        $_src_ab{y}   = 0;
        $_src_ab{ay}  = $_src_ab{y};
        $_src_ab{ang} = 1.2;
        $_src_ab{col} = 'red';  # wrto the coordinate frame color
        $_src_ab{tck} = 'tt';
        $_src_w{cmt}  = 'e^{$-$}';
        $_src_w{x}    = $_src_ab{x} + 0.4;
        $_src_w{y}    = $_src_ab{y} - 0.09;
        $_src_w{size} = 1.3;
        $_src_w{col}  = 'white';
        # Unit for T-3Dshow
        $_unit_w{cmt} = '(Unit: cm)';
        $_unit_w{x}   = 0.15;
        $_unit_w{y}   = 0.7;
        $_unit_w{s}   = 1.3;

        # sangel strings depending on the number of active MC cells
        my @_cells = (
            [
                ($bconv->flag !~ /none/i ? 1 : 0),
                \%_bconv_aw,
            ],
            [
                1,  # Always turned on
                \%_motar_aw,
            ],
            [
                ($flux_mnt_up->height > 0 ? 1 : 0),
                \%_flux_mnt_up_aw,
            ],
            [
                ($flux_mnt_down->height > 0 ? 1 : 0),
                \%_flux_mnt_down_aw,
            ],
            [
                ($tar_wrap->thickness > 0 ? 1 : 0),
                \%_tar_wrap_aw,
            ],
        );
        my $angel_cmt_annot = sprintf(
            "\n%9s".
            "'%8s'",  # ANGEL man p. 5
            ' ',
            $angel->Cmt->annot,
        );
        my $angel_cmt_annot_dummy = sprintf(
            "\n%9s''",
            ' ',
        );
        my $num_cells = 0;
        $num_cells += $_->[0] for @_cells;
        $num_cells++ if $angel->Cmt->annot;  # Increment num. lines of sangel.
        my $format_str = sprintf(
            "%4s%s",
            $num_cells,
            $angel->Cmt->annot ? $angel_cmt_annot : '',
        );
        my $format_str_title_only = sprintf(
            "%4s%s",
            1,
            $angel->Cmt->annot ? $angel_cmt_annot : $angel_cmt_annot_dummy,
        );
        foreach my $_ (@_cells) {
            next unless $_->[0];
            $format_str .= sprintf(
                "\n%9s".
                "aw: %s / x(%.4f) y(%.4f) ax(%.4f) ay(%.4f)",
                ' ',
                @{$_->[1]}{'mat', 'x', 'y', 'ax', 'ay'},
            );
        }

        # sangel setters
        $t_track->xz->set_sangel($format_str);
        $t_track->yz->set_sangel($t_track->xz->sangel);
        $t_track->xy->set_sangel(
            sprintf(
                "%4s%s".
                "\n%9s"."aw: %s / x(%s) y(%s) ax(%s) ay(%s)",
                $angel->Cmt->annot ? (2, $angel_cmt_annot) :
                                     (1, ''),
                ' ', @_bconv_aw{'mat', '0', 'y', '0', 'ay'},
            )
        );
        $t_track->xy_bconv->set_sangel($t_track->xy->sangel);
        $t_track->xy->set_sangel_mo(
            sprintf(
                "%4s%s".
                "\n%9s"."aw: %s / x(%s) y(%s) ax(%s) ay(%s)",
                $angel->Cmt->annot ? (2, $angel_cmt_annot) :
                                     (1, ''),
                ' ', @_motar_aw{'mat', '0', 'y', '0', 'ay'},
            )
        );
        $t_track->xy_motar->set_sangel_mo($t_track->xy->sangel_mo);
        $t_track->nrg_bconv->set_sangel($format_str_title_only);
        $t_track->nrg_bconv_low_emax->set_sangel($format_str_title_only);
        $t_track->nrg_motar->set_sangel($format_str_title_only);
        $t_track->nrg_motar_low_emax->set_sangel($format_str_title_only);
        $t_track->nrg_flux_mnt_up->set_sangel($format_str_title_only);
        $t_track->nrg_flux_mnt_down->set_sangel($format_str_title_only);

        $t_cross->nrg_intact->set_sangel($format_str_title_only);
        $t_cross->nrg_intact_low_emax->set_sangel($format_str_title_only);
        $t_cross->nrg_bconv_ent->set_sangel($format_str_title_only);
        $t_cross->nrg_bconv_ent_low_emax->set_sangel($format_str_title_only);
        $t_cross->nrg_bconv_exit->set_sangel($format_str_title_only);
        $t_cross->nrg_bconv_exit_low_emax->set_sangel($format_str_title_only);
        $t_cross->nrg_motar_ent->set_sangel($format_str_title_only);
        $t_cross->nrg_motar_ent_low_emax->set_sangel($format_str_title_only);
        $t_cross->nrg_motar_exit->set_sangel($format_str_title_only);
        $t_cross->nrg_motar_exit_low_emax->set_sangel($format_str_title_only);

        $t_heat->xz->set_sangel($t_track->xz->sangel);
        $t_heat->yz->set_sangel($t_track->yz->sangel);
        $t_heat->xy->set_sangel($t_track->xy->sangel);
        $t_heat->xy_bconv->set_sangel($t_heat->xy->sangel);
        $t_heat->xy->set_sangel_mo($t_track->xy->sangel_mo);
        $t_heat->xy_motar->set_sangel_mo($t_heat->xy->sangel_mo);
        $t_heat->rz_bconv->set_sangel($format_str_title_only);
        $t_heat->rz_motar->set_sangel($format_str_title_only);

        $num_cells += 2;
        $format_str =~ s/^\s*[0-9]/$num_cells/;
        $format_str .= sprintf(
            "\n%9s"."ab: x(%s) ax(%s) y(%s) ay(%s) a(%s) cb(%s) %s".
            "\n%9s"."w:  %s / x(%s) y(%s) s(%s) c(%s)",
            ' ', @_src_ab{'x', 'ax', 'y', 'ay', 'ang', 'col', 'tck'},
            ' ', @_src_w{'cmt', 'x', 'y', 'size', 'col'}
        );
        $t_gshow->xz->set_sangel($format_str);
        $t_gshow->yz->set_sangel($t_gshow->xz->sangel);
        $t_gshow->xy->set_sangel($t_track->xy->sangel);
        $t_gshow->xy_bconv->set_sangel($t_gshow->xy->sangel);
        $t_gshow->xy->set_sangel_mo($t_track->xy->sangel_mo);
        $t_gshow->xy_motar->set_sangel_mo($t_gshow->xy->sangel_mo);

        # Overriding
        $_src_ab{x}   = $t_3dshow->frame->{width} / 2 - (
            $bconv->radius > 1.80 ? 2.37 :
            $bconv->radius > 1.50 ? 2.25 :
                                    2.00
        );
        $_src_ab{ax}  = $_src_ab{x} + 1;
        $_src_ab{y}   = $t_3dshow->frame->{height} / 2;
        $_src_ab{ay}  = $_src_ab{y};
        $_src_w{x}    = $_src_ab{x} + 0.4;
        $_src_w{y}    = $_src_ab{y} - 0.09;
        $_src_w{size} = 1.5;
        $t_3dshow->polar1->set_sangel(
            sprintf(
                "%4s%s".
                "\n%12s"."w:  %s / x(%s) y(%s) s(%s)".
                "\n%12s"."ab: x(%s) ax(%s) y(%s) ay(%s) cb(%s) %s".
                "\n%12s"."w:  %s / x(%s) y(%s) s(%s) c(%s)",
                $angel->Cmt->annot ? (4, $angel_cmt_annot) :
                                     (3, ''),
                ' ', @_unit_w{'cmt', 'x', 'y', 's'},
                ' ', @_src_ab{'x', 'ax', 'y', 'ay', 'col', 'tck'},
                ' ', @_src_w{'cmt', 'x', 'y', 'size', 'col'},
            )
        );
        # Overriding
        $_src_ab{x}  = $t_3dshow->frame->{width} / 2 + (
            $bconv->radius > 1.80 ? 2.37 :
            $bconv->radius > 1.50 ? 2.25 :
                                    2.00
        );
        $_src_ab{ax} = $_src_ab{x} - 1;
        $_src_w{x}   = $_src_ab{x} - 0.95;
        $_src_w{y}   = $_src_ab{y} - 0.07;
        $t_3dshow->polar2->set_sangel(
            sprintf(
                "%4s%s".
                "\n%12s"."w:  %s / x(%s) y(%s) s(%s)".
                "\n%12s"."ab: x(%s) ax(%s) y(%s) ay(%s) cb(%s) %s".
                "\n%12s"."w:  %s / x(%s) y(%s) s(%s) c(%s)",
                $angel->Cmt->annot ? (4, $angel_cmt_annot) :
                                     (3, ''),
                ' ', @_unit_w{'cmt', 'x', 'y', 's'},
                ' ', @_src_ab{'x', 'ax', 'y', 'ay', 'col', 'tck'},
                ' ', @_src_w{'cmt', 'x', 'y', 'size', 'col'},
            )
        );

        #
        # Define a filename wrto the varying parameter.
        # (1) Construct a backbone.
        # (2) Define filenames based on the backbone.
        #

        # (1)
        (my $_v_geom_val = $v_geom_val) =~ s/[.]/p/;
        # Changed at each iteration are:
        # > $_v_geom_val
        # > $fixed_flags_and_vals
        my $backbone = (                   # e.g.
            $tar_of_int->flag.             # wrcc || w_rcc
            $phits->FileIO->fname_sep.     # -
            $phits->FileIO->varying_flag.  # vhgt || v_hgt
            $geom_val_sep.                 # '' || _
            $_v_geom_val.                  # 0p10
            $phits->FileIO->fname_sep.     # -
            $fixed_flags_and_vals          # frad1p00_fgap0p15
                                           # || f_rad_1p00_f_gap_0p15
        );

        # (2)
        # e.g.
        # wrcc-vhgt0p10-frad1p00-fgap0p15.inp <= Input file; for running PHITS
        # wrcc-vhgt0p10-frad1p00-fgap0p15.out <= file(6); for summary output
        # wrcc-vhgt0p10-frad1p00-fgap0p15.mac <= An MAPDL macro file.
        $phits->FileIO->set_inp(
            $backbone.
            $phits->FileIO->fname_ext_delim.
            $phits->FileIO->fname_exts->{inp}
        );

        $phits->FileIO->set_inp_dmp(  # Input file generating a dump file
            $backbone.
            $t_cross_dump->dump->{suffix}.
            $phits->FileIO->fname_ext_delim.
            $phits->FileIO->fname_exts->{inp}
        );

        $phits->params->{file}{summary_out_fname}{val} = sprintf(  # file(6)
            "%s%s%s",
            $backbone,
            $phits->FileIO->fname_ext_delim,
            $phits->FileIO->fname_exts->{out}
        );

        $phits->params->{file}{$_.'_out_fname'}{val} = sprintf(
            "%s%s%s%s%s",
            $backbone,
            $phits->FileIO->fname_sep,
            $_,
            $phits->FileIO->fname_ext_delim,
            $phits->FileIO->fname_exts->{out}
        ) for qw(
            nucl_react
            cut_neut
            cut_gamm
            cut_prot
            bat
            pegs5
        );  # file(x): 11, 12, 13, 10, 22, 23

        my @_args = (  # e.g. wrcc-vhgt0p10-frad1p00-fgap0p15
            $bconv->cell_mat,
            $motar->cell_mat,
            $flux_mnt_up->cell_mat,
            $flux_mnt_down->cell_mat,
            $t_cross_dump->particles_of_int->[0],
            $backbone
        );                                  # e.g.
        $t_track->set_fnames(@_args);       # -track-xz
        $t_cross->set_fnames(@_args);       # -cross-eng-w_exit
        $t_cross_dump->set_fnames(@_args);  # -cross-eng-moo3_ent_elec
        $t_heat->set_fnames(@_args);        # -heat-xz
        $t_heat_mapdl->set_fnames(@_args);  # -w
        $t_gshow->set_fnames(@_args);       # -gshow-xz
        $t_3dshow->set_fnames(@_args);      # -3dshow
                                            # .ang

        $mapdl->FileIO->set_inp(
            $backbone.
            $mapdl->FileIO->fname_ext_delim.
            $mapdl->FileIO->fname_exts->{mac}
        );
        # Target-specific: Initialized at each inner iterator.
        $mapdl_of_macs->FileIO->add_macs($backbone);
        # Target-independent: Not initialized
        $mapdl_of_macs_all->FileIO->add_macs(
            $phits->FileIO->subdir.        # beam_fwhm_0p3
            $phits->FileIO->path_delim.    # \
            $tar_of_int->flag.             # wrcc
            $phits->FileIO->fname_sep.     # -
            $phits->FileIO->varying_flag.  # vhgt
            $phits->FileIO->fname_sep.     # _
            $phits->FileIO->fixed_flag.    # frad-fgap
            $phits->FileIO->path_delim.    # \
            $backbone  # wrcc-vhgt0p10-frad1p00-fgap0p15 <= .mac
        );


        #
        # PHITS input file writing
        #

        #
        # Shared-memory parallel computing
        #
        push @{$phits->sects->{omp}},
            sprintf(
                "\$OMP=%s",
                $phits->Ctrls->openmp,
            ),
            "";  # End

        #
        # List of abbreviations
        #
        push @{$phits->sects->{abbr}},
            sprintf("%s List of abbreviations used", $phits->Cmt->symb);
        push @{$phits->sects->{abbr}}, map {
            sprintf(
                "%s %-7s => %s",
                $phits->Cmt->symb,
                $phits->Cmt->abbrs->{$_}[0],
                $phits->Cmt->abbrs->{$_}[1]
            );
        } qw(
            varying
            fixed
            bottom
            radius
            height
        );
        push @{$phits->sects->{abbr}}, "";  # End

        #
        # Title section: phitar front matter
        #
        push @{$phits->sects->{title}},
            "[Title]",
            show_front_matter(
                $prog_info_href,
                'prog',
                'auth',
                'timestamp',
                'no_trailing_blkline',
                'no_newline',
                'copy',
#                $phits->Cmt->symb,
            ),
            "";  # End

        #
        # Parameters section
        #
        my @_parameters_sect = ();

        # Common parameters
        push @_parameters_sect, map {
            $phits->params->{$_}
        } (             # Instead of qw to add comments as below
            'icntl',    # MC run options
            'istdev',   # Batch control
            'maxcas',   # Number of histories per batch
            'maxbch',   # Number of batches
            'ipnint',   # Photonuclear reaction considered
            'negs',     # EGS5
            'nucdata',  # Neutron data emin and dmax
        );

        # Cutoff energies: Conditional
        # The author has deactivated the use of proton nuclear data option
        # (that is, dmax--not emin, which is not related to nuclear data
        # but a cutoff energy), because the materials used in the simulations
        # of this program do not have the corresponding proton nuclear data.
        # For example, with a Ta converter, MoO3 target and vacuum MC space
        # used, the following fatal error occurs:
        # Error: There is no cross-section table(s) in xsdir.
        #    8016.  h
        #   42092.  h
        #   42094.  h
        #   42095.  h
        #   42096.  h
        #   42097.  h
        #   42098.  h
        #   42100.  h
        #   73181.  h
        # Please check [material] section,
        # or set nucdata=0 to disable nuclear data
        foreach my $cutoff_type (qw /emin dmax/) {
            foreach my $part (qw/neut elec posi phot/) {  # No 'prot'
                # e.g.
                # $phits->params->{emin}{neut}
                # $phits->params->{emin}{elec}
                # ...
                # $phits->params->{dmax}{neut}
                # $phits->params->{dmax}{elec}
                push @_parameters_sect, $phits->params->{$cutoff_type}{$part}
                    if defined $phits->params->{$cutoff_type}{$part}{val};
            }
        }
        push @_parameters_sect, map {
            $phits->params->{$_}
        } qw(
            ipcut
            incut
            igcut
        );

        # File I/O: Conditional
        my @_file_types = ();
        # file(1)
        push @_file_types, 'phits_dname'
            if $phits->params->{file}{phits_dname}{swc} == 1;
        # file(6)
        push @_file_types, 'summary_out_fname';
        # file(7)
        push @_file_types, 'xs_dname' if (
            $phits->params->{file}{phits_dname}{swc} == 0 and
            $t_shared->is_neut_of_int
        );
        # file(11)
        push @_file_types, 'nucl_react_out_fname';
        # file(10)
        push @_file_types, 'cut_prot_out_fname'
            if $phits->params->{ipcut}{val} == 1;
        # file(12)
        push @_file_types, 'cut_neut_out_fname'
            if $phits->params->{incut}{val} == 1;
        # file(13)
        push @_file_types, 'cut_gamm_out_fname'
            if $phits->params->{igcut}{val} == 1;
        # file(20)
        push @_file_types, 'egs5_xs_dname' if (
            $phits->params->{file}{phits_dname}{swc} == 0 and
            $phits->params->{negs}{val} == 1
        );
        # file(22)
        push @_file_types, 'curr_bat_fname';
        # file(23)
        push @_file_types, 'pegs5_out_fname'
            if $phits->params->{negs}{val} == 1;
        push @_parameters_sect, map {
            $phits->params->{file}{$_}
        } @_file_types;

        # Fill in the section array.
        push @{$phits->sects->{parameters}}, "[Parameters]";
        push @{$phits->sects->{parameters}}, map {
            sprintf("%-8s = %6s  %s", @{$_}{'key', 'val', 'cmt'})
        } @_parameters_sect;
        push @{$phits->sects->{parameters}}, "";  # End

        #
        # Source section
        #

        # (i) Common parameters
        my @_source_sect_common = (
            [  # s-type
                $phits->source->spat_dist_of_int->{type}{key},
                $phits->source->spat_dist_of_int->{type}{val},
                $phits->source->spat_dist_of_int->{type}{cmt},
            ],
            [  # Projectile
                $phits->source->spat_dist_of_int->{proj}{key},
                $phits->source->spat_dist_of_int->{proj}{val},
                $phits->source->spat_dist_of_int->{proj}{cmt},
            ],
        );
        # (ii) Parameters dependent on source->nrg_dist_of_int
        my @_source_sect_nrg_dist_of_int = ();
        if ($phits->source->nrg_dist_of_int->{type}{val} == 2) {
            # Energy distribution bound to the 'nrg' key of spat_dist_of_int
            @_source_sect_nrg_dist_of_int = (
                [
                    $phits->source->nrg_dist_of_int->{type}{key},
                    $phits->source->nrg_dist_of_int->{type}{val},
                    $phits->source->nrg_dist_of_int->{type}{cmt},
                ],
                [
                    $phits->source->nrg_dist_of_int->{eg0}{key},
                    $source_eg0,  # <= One of the control vars
                    $phits->source->nrg_dist_of_int->{eg0}{cmt},
                ],
                [
                    $phits->source->nrg_dist_of_int->{fwhm}{key},
                    $phits->source->nrg_dist_of_int->{fwhm}{val},
                    $phits->source->nrg_dist_of_int->{fwhm}{cmt},
                ],
                [
                    $phits->source->nrg_dist_of_int->{cutoff_min}{key},
                    $phits->source->nrg_dist_of_int->{cutoff_min}{val},
                    $phits->source->nrg_dist_of_int->{cutoff_min}{cmt},
                ],
                [
                    $phits->source->nrg_dist_of_int->{cutoff_max}{key},
                    $phits->source->nrg_dist_of_int->{cutoff_max}{val},
                    $phits->source->nrg_dist_of_int->{cutoff_max}{cmt},
                ],
            );
            # Used in run_and_rpt_calc_rn_yield() (2/2) Postprocessing Part
            $phits->set_curr_src_nrg_dist(
                name   => $phits->source->nrg_dist_of_int->{type}{abbr},
                param1 => sprintf(
                    "Center energy: %s MeV",
                    $source_eg0,
                ),
                param2 => sprintf(
                    "FWHM: %s MeV, cutoff min: %s MeV, cutoff max: %s MeV",
                    $phits->source->nrg_dist_of_int->{fwhm}{val},
                    $phits->source->nrg_dist_of_int->{cutoff_min}{val},
                    $phits->source->nrg_dist_of_int->{cutoff_max}{val},
                ),
            );
        }
        elsif ($phits->source->nrg_dist_of_int->{type}{val} == 22) {
            @_source_sect_nrg_dist_of_int = (
                [
                    $phits->source->nrg_dist_of_int->{type}{key},
                    $phits->source->nrg_dist_of_int->{type}{val},
                    $phits->source->nrg_dist_of_int->{type}{cmt},
                ],
                [
                    $phits->source->nrg_dist_of_int->{ne}{key},
                    $phits->source->nrg_dist_of_int->{ne}{val},
                    $phits->source->nrg_dist_of_int->{ne}{cmt},
                ],
            );
            $phits->set_curr_src_nrg_dist(
                name   => $phits->source->nrg_dist_of_int->{type}{abbr},
                param1 => sprintf(
                    "File: %s",
                    $phits->source->nrg_dist_of_int->{file},
                ),
                param2 => sprintf(
                    "ne: %s, emin: %s MeV, emax: %s MeV",
                    $phits->source->nrg_dist_of_int->{ne}{val},
                    $phits->source->nrg_dist_of_int->{cutoff_min}{val},
                    $phits->source->nrg_dist_of_int->{cutoff_max}{val},
                ),
            );
        }
        # (iii) Parameters dependent on source->spat_dist_of_int
        my @_source_sect_spat_dist_of_int = ();
        # Spatial distribution parameters of source->gaussian_xy
        if ($phits->source->spat_dist_of_int->{type}{val} == 13) {
            @_source_sect_spat_dist_of_int = (
                [
                    $phits->source->spat_dist_of_int->{x_center}{key},
                    $phits->source->spat_dist_of_int->{x_center}{val},
                    $phits->source->spat_dist_of_int->{x_center}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{y_center}{key},
                    $phits->source->spat_dist_of_int->{y_center}{val},
                    $phits->source->spat_dist_of_int->{y_center}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{xy_fwhms}{key},
                    $source_size,  # <= One of the control vars
                    $phits->source->spat_dist_of_int->{xy_fwhms}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{z_beg}{key},
                    $phits->source->spat_dist_of_int->{z_beg}{val},
                    $phits->source->spat_dist_of_int->{z_beg}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{z_end}{key},
                    $phits->source->spat_dist_of_int->{z_end}{val},
                    $phits->source->spat_dist_of_int->{z_end}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{dir}{key},
                    $phits->source->spat_dist_of_int->{dir}{val},
                    $phits->source->spat_dist_of_int->{dir}{cmt},
                ],
            );
            # Used in run_and_rpt_calc_rn_yield() (2/2) Postprocessing Part
            $phits->set_curr_src_spat_dist(
                name   => $phits->source->spat_dist_of_int->{type}{abbr},
                param1 => sprintf(
                    "FWHM on the xy plane: %s mm",
                    $source_size * 10,
                ),
                param2 => sprintf(
                    "z-axis coordinates: %s mm to %s mm",
                    $phits->source->spat_dist_of_int->{z_beg}{val} * 10,
                    $phits->source->spat_dist_of_int->{z_end}{val} * 10,
                ),
            );
        }
        # Spatial distribution parameters of source->gaussian_xyz
        elsif ($phits->source->spat_dist_of_int->{type}{val} == 3) {
            # Three independent variables
            $phits->source->spat_dist_of_int->{x_fwhm}{val} =
                $phits->source->iter_param =~ /x[\-_]?fwhm/i ?
                    $source_size :
                    $phits->source->spat_dist_of_int->{x_fwhm}{val_fixed};
            $phits->source->spat_dist_of_int->{y_fwhm}{val} =
                $phits->source->iter_param =~ /y[\-_]?fwhm/i ?
                    $source_size :
                    $phits->source->spat_dist_of_int->{y_fwhm}{val_fixed};
            $phits->source->spat_dist_of_int->{z_fwhm}{val} =
                $phits->source->iter_param =~ /z[\-_]?fwhm/i ?
                    $source_size :
                    $phits->source->spat_dist_of_int->{z_fwhm}{val_fixed};
            @_source_sect_spat_dist_of_int = (
                [
                    $phits->source->spat_dist_of_int->{x_center}{key},
                    $phits->source->spat_dist_of_int->{x_center}{val},
                    $phits->source->spat_dist_of_int->{x_center}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{x_fwhm}{key},
                    $phits->source->spat_dist_of_int->{x_fwhm}{val},
                    $phits->source->spat_dist_of_int->{x_fwhm}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{y_center}{key},
                    $phits->source->spat_dist_of_int->{y_center}{val},
                    $phits->source->spat_dist_of_int->{y_center}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{y_fwhm}{key},
                    $phits->source->spat_dist_of_int->{y_fwhm}{val},
                    $phits->source->spat_dist_of_int->{y_fwhm}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{z_center}{key},
                    $phits->source->spat_dist_of_int->{z_center}{val},
                    $phits->source->spat_dist_of_int->{z_center}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{z_fwhm}{key},
                    $phits->source->spat_dist_of_int->{z_fwhm}{val},
                    $phits->source->spat_dist_of_int->{z_fwhm}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{dir}{key},
                    $phits->source->spat_dist_of_int->{dir}{val},
                    $phits->source->spat_dist_of_int->{dir}{cmt},
                ],
            );
            $phits->set_curr_src_spat_dist(
                name   => $phits->source->spat_dist_of_int->{type}{abbr},
                param1 => sprintf(
                    "x-FWHM: %s mm, y-FWHM: %s mm, z-FWHM: %s mm",
                    $phits->source->spat_dist_of_int->{x_fwhm}{val} * 10,
                    $phits->source->spat_dist_of_int->{y_fwhm}{val} * 10,
                    $phits->source->spat_dist_of_int->{z_fwhm}{val} * 10,
                ),
                param2 => sprintf(
                    "Beginning z-coordinate: %s mm",
                    $phits->source->spat_dist_of_int->{z_center}{val} * 10,
                ),
            );
        }
        # Spatial distribution parameters of source->cylind
        elsif ($phits->source->spat_dist_of_int->{type}{val} == 1) {
            @_source_sect_spat_dist_of_int = (
                [
                    $phits->source->spat_dist_of_int->{x_center}{key},
                    $phits->source->spat_dist_of_int->{x_center}{val},
                    $phits->source->spat_dist_of_int->{x_center}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{y_center}{key},
                    $phits->source->spat_dist_of_int->{y_center}{val},
                    $phits->source->spat_dist_of_int->{y_center}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{rad}{key},
                    $source_size,  # <= One of the control vars
                    $phits->source->spat_dist_of_int->{rad}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{z_beg}{key},
                    $phits->source->spat_dist_of_int->{z_beg}{val},
                    $phits->source->spat_dist_of_int->{z_beg}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{z_end}{key},
                    $phits->source->spat_dist_of_int->{z_end}{val},
                    $phits->source->spat_dist_of_int->{z_end}{cmt},
                ],
                [
                    $phits->source->spat_dist_of_int->{dir}{key},
                    $phits->source->spat_dist_of_int->{dir}{val},
                    $phits->source->spat_dist_of_int->{dir}{cmt},
                ],
            );
            $phits->set_curr_src_spat_dist(
                name   => $phits->source->spat_dist_of_int->{type}{abbr},
                param1 => sprintf(
                    "Radius on the xy plane: %s mm",
                    $source_size * 10,
                ),
                param2 => sprintf(
                    "z-axis coordinates: %s mm to %s mm",
                    $phits->source->spat_dist_of_int->{z_beg}{val} * 10,
                    $phits->source->spat_dist_of_int->{z_end}{val} * 10,
                ),
            );
        }
        push @{$phits->sects->{source}}, "[Source]";
        push @{$phits->sects->{source}},
            map { sprintf("%-6s = %8s  %s", @{$_}[0, 1, 2]) } (
                @_source_sect_common,
                @_source_sect_nrg_dist_of_int,
                @_source_sect_spat_dist_of_int,
            );
        push @{$phits->sects->{source}}, "";  # End

        #
        # "Dump" source section
        #
        my $_suffix = $t_cross_dump->dump->{suffix};
        $phits->source->dump->{file}{val} =
            $t_cross_dump->nrg_motar_ent_dump->fname;
        $phits->source->dump->{file}{val} =~
            s/([.](?:ang|out))$/$_suffix$1/i;
        push @{$phits->sects->{source_dump}},
            "[Source]",
            sprintf(
                "%-6s = %4s %s",
                $phits->source->dump->{type}{key},
                $phits->source->dump->{type}{val},
                $phits->source->dump->{type}{cmt}
            ),
            sprintf(
                "%-6s = %s",
                $phits->source->dump->{file}{key},
                $phits->source->dump->{file}{val}
            ),
            sprintf(
                "%-6s = %4s",
                'dump',
                $t_cross_dump->dump->{num_dat},
            ),
            sprintf(
                "%11s %s",
                ' ',
                $t_cross_dump->dump->{dat}
            ),
            "";  # End

        #
        # Material section
        #
        my @mc_cells;
        push @mc_cells, $bconv         if $bconv->flag !~ /none/i;
        push @mc_cells, $motar;
        push @mc_cells, $flux_mnt_up   if $flux_mnt_up->height   > 0;
        push @mc_cells, $flux_mnt_down if $flux_mnt_down->height > 0;
        push @mc_cells, $tar_wrap      if $tar_wrap->thickness   > 0;
        push @mc_cells, $mc_space;  # Ignored if set to be a vacuum
        push @{$phits->sects->{material}}, "[Material]";
        foreach my $mc_cell (@mc_cells) {
            push @{$phits->sects->{material}}, sprintf(
                "mat[%3s] %s",
                $mc_cell->cell_props->{mat_id},
                $mc_cell->cell_props->{mat_comp},
            ) if $mc_cell->cell_props->{mat_comp};
        }
        # Dummy for preventing a fatal error (owing to nonmaterial)
        $phits->sects->{material}[1] = "mat[180] Ar 1\n"
            unless $phits->sects->{material}[1];
        # Remove duplicate material IDs.
        # > Must be performed to prevent a fatal error of PHITS.
        rm_duplicates($phits->sects->{material});
        rm_empty($phits->sects->{material});
        push @{$phits->sects->{material}}, "";  # End

        #
        # Mat Name Color section for T-Gshow and T-3Dshow
        #
        push @{$phits->sects->{mat_name_color}},
            "[Mat Name Color]",
            sprintf(
                "%-3s %-10s %-4s %s",
                'mat',
                'name',
                'size',
                'color',
            );
        foreach my $mc_cell (@mc_cells) {
            push @{$phits->sects->{mat_name_color}}, sprintf(
                "%-3s %-10s %-4s %s",
                $mc_cell->cell_props->{mat_id},
                $mc_cell->cell_props->{mat_lab_name},
                $mc_cell->cell_props->{mat_lab_size},
                $mc_cell->cell_props->{mat_lab_color},
            );
        }
        # Remove duplicate mat_name_color designations.
        # > Optional (unlike the material section, no fatal error occurs
        #   even if duplicate material IDs are designated
        #   in the mat_name_color section)
        rm_duplicates($phits->sects->{mat_name_color});
        push @{$phits->sects->{mat_name_color}}, "";  # End

        #
        # Surface section
        #
        push @{$phits->sects->{surface}},
            "[Surface]";
            # (1) Bremsstrahlung converter (conditional)
            if ($bconv->flag !~ /none/i) {
                push @{$phits->sects->{surface}},
                    sprintf(
                        "%s %3s  0.00 0.00 %s",
                        $bconv->cell_props->{macrobody_id},
                        $bconv->cell_props->{macrobody_str},
                        $bconv->beam_ent
                    ),
                    sprintf(
                        "%9s"."0.00 0.00 %s",
                        ' ', $bconv->height
                    ),
                    sprintf(
                        "%9s"."%s  %s",
                        ' ', $bconv->radius, $bconv->cell_props->{cmt}
                    );
            }
        push @{$phits->sects->{surface}},
            # (2) Molybdenum target, RCC
            sprintf(
                "%s %3s  0.00 0.00 %s",
                $motar_rcc->cell_props->{macrobody_id},
                $motar_rcc->cell_props->{macrobody_str},
                $motar_rcc->beam_ent,
            ),
            sprintf(
                "%9s"."0.00 0.00 %s",
                ' ', $motar_rcc->height
            ),
            sprintf(
                "%9s"."%s  %s",
                ' ', $motar_rcc->radius, $motar_rcc->cell_props->{cmt}
            ),
            # Molybdenum target, TRC
            sprintf(
                "%s %3s  0.00 0.00 %s",
                $motar_trc->cell_props->{macrobody_id},
                $motar_trc->cell_props->{macrobody_str},
                $motar_trc->beam_ent,
            ),
            sprintf(
                "%9s"."0.00 0.00 %s",
                ' ', $motar_trc->height
            ),
            sprintf(
                "%9s"."%s",
                ' ', $motar_trc->bot_radius
            ),
            sprintf(
                "%9s"."%s  %s",
                ' ', $motar_trc->top_radius, $motar_trc->cell_props->{cmt}
            );
            # (3) Flux monitor, upstream (conditional)
            if ($flux_mnt_up->height > 0) {
                push @{$phits->sects->{surface}},
                    sprintf(
                        "%s %3s  0.00 0.00 %s",
                        $flux_mnt_up->cell_props->{macrobody_id},
                        $flux_mnt_up->cell_props->{macrobody_str},
                        $flux_mnt_up->beam_ent
                    ),
                    sprintf(
                        "%9s"."0.00 0.00 %s",
                        ' ', $flux_mnt_up->height
                    ),
                    sprintf(
                        "%9s".
                        "%s".
                        "  %s",
                        ' ',
                        $flux_mnt_up->radius,
                        $flux_mnt_up->cell_props->{cmt}
                    );
            }
            # (4) Flux monitor, downstream (conditional)
            if ($flux_mnt_down->height > 0) {
                push @{$phits->sects->{surface}},
                    sprintf(
                        "%s %3s  0.00 0.00 %s",
                        $flux_mnt_down->cell_props->{macrobody_id},
                        $flux_mnt_down->cell_props->{macrobody_str},
                        $flux_mnt_down->beam_ent
                    ),
                    sprintf(
                        "%9s"."0.00 0.00 %s",
                        ' ', $flux_mnt_down->height
                    ),
                    sprintf(
                        "%9s".
                        "%s".
                        "  %s",
                        ' ',
                        $flux_mnt_down->radius,
                        $flux_mnt_down->cell_props->{cmt}
                    );
            }
            # (5) Target wrap (conditional)
            if ($tar_wrap->thickness > 0) {
                push @{$phits->sects->{surface}},
                    sprintf(
                        "%s %3s  0.00 0.00 %s",
                        $tar_wrap->cell_props->{macrobody_id},
                        $tar_wrap->cell_props->{macrobody_str},
                        $tar_wrap->beam_ent
                    ),
                    sprintf(
                        "%9s"."0.00 0.00 %s",
                        ' ', $tar_wrap->height
                    ),
                    sprintf(
                        "%9s"."%s  %s",
                        ' ', $tar_wrap->radius, $tar_wrap->cell_props->{cmt}
                    );
            }
            # (6) Molybdenum target entrance
            push @{$phits->sects->{surface}},
                sprintf(
                    "%s %3s  0.00 0.00 %s",
                    $motar_ent->cell_props->{macrobody_id},
                    $motar_ent->cell_props->{macrobody_str},
                    $motar_ent->beam_ent
                ),
                sprintf(
                    "%9s"."0.00 0.00 %s",
                    ' ', $motar_ent->height
                ),
                sprintf(
                    "%9s"."%s  %s",
                    ' ', $motar_ent->radius, $motar_ent->cell_props->{cmt}
                );
            # (7) MC space: Inner
            push @{$phits->sects->{surface}},
                sprintf(
                    "%s %3s %.2f  %s",
                    $mc_space->cell_props->{macrobody_id},
                    $mc_space->cell_props->{macrobody_str},
                    $mc_space->radius_fixed,
                    $mc_space->cell_props->{cmt},
                ),
                "";  # End

        # Cell section
        my %_excluded = (  # Must also be initialized
            bconv     => '',
            motar     => '',
            flux_mnt  => '',
            tar_wrap  => '',
            motar_ent => '',
        );
        $_excluded{bconv} = ' #'.$bconv->cell_props->{cell_id}
            if $bconv->flag !~ /none/i;
        $_excluded{motar} = ' #'.$motar->cell_props->{cell_id};
        push @{$phits->sects->{cell}},
            "[Cell]";
            # (1) Bremsstrahlung converter (conditional)
            if ($bconv->flag !~ /none/i) {
                push @{$phits->sects->{cell}},
                    sprintf(
                        "%-2s %3s %-9s -%s",
                        $bconv->cell_props->{cell_id},
                        $bconv->cell_props->{mat_id},
                        (
                            $bconv->cell_props->{dens} ?
                                -$bconv->cell_props->{dens} : ' '
                        ),
                        $bconv->cell_props->{macrobody_id}
                    );
            }
        push @{$phits->sects->{cell}},
            # (2) Molybdenum target
            sprintf(
                "%-2s %3s %-9s -%s",
                $motar->cell_props->{cell_id},
                $motar->cell_props->{mat_id},
                (
                    $motar->cell_props->{dens} ?
                        -$motar->cell_props->{dens} : ' '
                ),
                (  # Conditional
                    $tar_of_int->flag eq $motar_trc->flag ?
                        $motar_trc->cell_props->{macrobody_id} :
                        $motar_rcc->cell_props->{macrobody_id}  # Default
                )
            );
            # (3) Flux monitor, upstream (conditional)
            if ($flux_mnt_up->height > 0) {
                $_excluded{flux_mnt} =
                    ' #'.$flux_mnt_up->cell_props->{cell_id};

                push @{$phits->sects->{cell}},
                    sprintf(
                        "%-2s %3s %-9s -%s",
                        $flux_mnt_up->cell_props->{cell_id},
                        $flux_mnt_up->cell_props->{mat_id},
                        (
                            $flux_mnt_up->cell_props->{dens} ?
                                -$flux_mnt_up->cell_props->{dens} : ' '
                        ),
                        $flux_mnt_up->cell_props->{macrobody_id}
                    );
            }
            # (4) Flux monitor, downstream (conditional)
            if ($flux_mnt_down->height > 0) {
                $_excluded{flux_mnt} .=
                    ' #'.$flux_mnt_down->cell_props->{cell_id};

                push @{$phits->sects->{cell}},
                    sprintf(
                        "%-2s %3s %-9s -%s",
                        $flux_mnt_down->cell_props->{cell_id},
                        $flux_mnt_down->cell_props->{mat_id},
                        (
                            $flux_mnt_down->cell_props->{dens} ?
                                -$flux_mnt_down->cell_props->{dens} : ' '
                        ),
                        $flux_mnt_down->cell_props->{macrobody_id}
                    );
            }
            # (5) Target wrap (conditional)
            if ($tar_wrap->thickness > 0) {
                $_excluded{tar_wrap} =
                    ' #'.$tar_wrap->cell_props->{cell_id};

                push @{$phits->sects->{cell}},
                sprintf(
                    "%-2s %3s %-9s -%s #%s #%s%s",
                    $tar_wrap->cell_props->{cell_id},
                    $tar_wrap->cell_props->{mat_id},
                    (
                        $tar_wrap->cell_props->{dens} ?
                            -$tar_wrap->cell_props->{dens} : ' '
                    ),
                    $tar_wrap->cell_props->{macrobody_id},
                    $bconv->cell_props->{cell_id},
                    $motar->cell_props->{cell_id},
                    $_excluded{flux_mnt}
                );
            }
            # (6) Molybdenum target entrance
            $_excluded{motar_ent} =
                ' #'.$motar_ent->cell_props->{cell_id};
            push @{$phits->sects->{cell}},
                sprintf(
                    "%-2s %3s %-9s -%s",
                    $motar_ent->cell_props->{cell_id},
                    $motar_ent->cell_props->{mat_id},
                    (
                        $motar_ent->cell_props->{dens} ?
                            -$motar_ent->cell_props->{dens} : ' '
                    ),
                    $motar_ent->cell_props->{macrobody_id}
                );
            push @{$phits->sects->{cell}},
                # (7) MC space: Inner
                sprintf(
                    "%-2s %3s %-9s -%s".
                    "%s%s%s%s%s",  # Excluded
                    $mc_space->cell_props->{cell_id},
                    $mc_space->cell_props->{mat_id},
                    (
                        $mc_space->cell_props->{dens} ?
                            -$mc_space->cell_props->{dens} : ' '
                    ),
                    $mc_space->cell_props->{macrobody_id},
                    # Excluded
                    $_excluded{bconv},
                    $_excluded{motar},
                    $_excluded{flux_mnt},
                    $_excluded{tar_wrap},
                    $_excluded{motar_ent}
                ),
                # (8) MC space: Outer
                sprintf(
                    "%-2s %3s %-9s  %s",
                    $void->cell_props->{cell_id},
                    $void->cell_props->{mat_id},
                    ' ',
                    $mc_space->cell_props->{macrobody_id}
                ),
                "";  # End

        # Volume section
        my @_volume_sect = ();
        push @_volume_sect, $bconv if $bconv->flag !~ /none/i;
        push @_volume_sect, $tar_of_int->flag eq $motar_trc->flag ?
            $motar_trc : $motar_rcc;
        push @_volume_sect, $flux_mnt_up   if $flux_mnt_up->height   > 0;
        push @_volume_sect, $flux_mnt_down if $flux_mnt_down->height > 0;
        push @_volume_sect, $tar_wrap      if $tar_wrap->thickness   > 0;
        push @_volume_sect, $motar_ent;
        push @{$phits->sects->{volume}}, "[Volume]", "reg vol";
        push @{$phits->sects->{volume}}, map {
            sprintf(
                "%-3s %s  %s",  # %-3s <= length('reg')
                $_->cell_props->{cell_id},
                $_->vol,
                $_->cell_props->{cmt},
            );
        } @_volume_sect;
        push @{$phits->sects->{volume}}, "";  # End

        # T-Track 1
        # > Mesh: xyz
        # > Axis: xz
        # > Particle distributions on xz plane
        push @{$phits->sects->{t_track_xz}},
            # sect_begin: defined by the tally flag; e.g. [T-Track]
            $t_track->Ctrls->switch =~ /off/i ?
                $t_track->sect_begin." off" :
                $t_track->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_track->flag,    $t_track->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s",    'mesh',   $t_track->mesh_shape->{xyz}   ),
            sprintf("%-6s = %4s",    'x-type', $t_track->mesh_types->{x}     ),
            sprintf("%-6s = %4s",    'nx',     $t_track->mesh_sizes->{x}     ),
            sprintf("%-6s = %4s",    'xmin',   $t_shared->mesh_ranges->{xmin}),
            sprintf("%-6s = %4s",    'xmax',   $t_shared->mesh_ranges->{xmax}),
            sprintf("%-6s = %4s",    'y-type', $t_track->mesh_types->{y}     ),
            sprintf("%-6s = %4s",    'ny',     $t_track->mesh_sizes->{1}     ),
            sprintf("%-6s = %4s",    'ymin',   $t_shared->mesh_ranges->{ymin}),
            sprintf("%-6s = %4s",    'ymax',   $t_shared->mesh_ranges->{ymax}),
            sprintf("%-6s = %4s",    'z-type', $t_track->mesh_types->{z}     ),
            sprintf("%-6s = %4s",    'nz',     $t_track->mesh_sizes->{z}     ),
            sprintf("%-6s = %10.5f", 'zmin',   $t_shared->mesh_ranges->{zmin}),
            sprintf("%-6s = %10.5f", 'zmax',   $t_shared->mesh_ranges->{zmax}),
            sprintf("%-6s = %4s",    'e-type', $t_track->mesh_types->{e}     ),
            sprintf("%-6s = %4s",    'ne',     $t_track->mesh_sizes->{1}     ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_track->mesh_ranges->{emin}{tot_nrg_range},
                $t_track->mesh_ranges->{emin_cmt}{tot_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_track->mesh_ranges->{emax}{tot_nrg_range},
                $t_track->mesh_ranges->{emax_cmt}{tot_nrg_range}
            ),
            # Particles of interest
            sprintf("%-6s = @{$t_track->particles_of_int}", 'part'),
            # Output settings
            sprintf("%-6s = %4s", 'axis', $t_track->xz->name ),
            sprintf("%-6s = %s",  'file', $t_track->xz->fname),
            sprintf("%-6s = %4s", 'unit', $t_track->unit     ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_track->factor->{val},
                eval { $t_track->factor->{cmt} } // ''
            ),
            sprintf("%-6s = %s",  'title',  $t_track->xz->title        ),
            sprintf("%-6s = %4s", 'epsout', $t_track->epsout           ),
            sprintf("%-6s = %4s", 'vtkout', $t_track->vtkout           ),
            sprintf("%-6s = %s",  'angel',  $t_track->xz->angel        ),
            sprintf("%-6s = %s",  'sangel', $t_track->xz->sangel       ),
            sprintf("%-6s = %4s", 'gshow',  $t_track->gshow            ),
            sprintf("%-6s = %4s", 'resol',  $t_track->cell_bnd->{resol}),
            sprintf("%-6s = %4s", 'width',  $t_track->cell_bnd->{width}),
            "";  # End

        # T-Track 2
        # > Mesh: xyz
        # > Axis: yz
        # > Particle distributions on yz plane
        push @{$phits->sects->{t_track_yz}},
            $t_track->Ctrls->switch =~ /off/i ?
                $t_track->sect_begin." off" :
                $t_track->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_track->flag,    $t_track->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s",    'mesh',   $t_track->mesh_shape->{xyz}   ),
            sprintf("%-6s = %4s",    'x-type', $t_track->mesh_types->{x}     ),
            sprintf("%-6s = %4s",    'nx',     $t_track->mesh_sizes->{1}     ),
            sprintf("%-6s = %4s",    'xmin',   $t_shared->mesh_ranges->{xmin}),
            sprintf("%-6s = %4s",    'xmax',   $t_shared->mesh_ranges->{xmax}),
            sprintf("%-6s = %4s",    'y-type', $t_track->mesh_types->{y}     ),
            sprintf("%-6s = %4s",    'ny',     $t_track->mesh_sizes->{y}     ),
            sprintf("%-6s = %4s",    'ymin',   $t_shared->mesh_ranges->{ymin}),
            sprintf("%-6s = %4s",    'ymax',   $t_shared->mesh_ranges->{ymax}),
            sprintf("%-6s = %4s",    'z-type', $t_track->mesh_types->{z}     ),
            sprintf("%-6s = %4s",    'nz',     $t_track->mesh_sizes->{z}     ),
            sprintf("%-6s = %10.5f", 'zmin',   $t_shared->mesh_ranges->{zmin}),
            sprintf("%-6s = %10.5f", 'zmax',   $t_shared->mesh_ranges->{zmax}),
            sprintf("%-6s = %4s",    'e-type', $t_track->mesh_types->{e}     ),
            sprintf("%-6s = %4s",    'ne',     $t_track->mesh_sizes->{1}     ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_track->mesh_ranges->{emin}{tot_nrg_range},
                $t_track->mesh_ranges->{emin_cmt}{tot_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_track->mesh_ranges->{emax}{tot_nrg_range},
                $t_track->mesh_ranges->{emax_cmt}{tot_nrg_range}
            ),
            # Particles of interest
            sprintf("%-6s = @{$t_track->particles_of_int}", 'part'),
            # Output settings
            sprintf("%-6s = %4s", 'axis', $t_track->yz->name ),
            sprintf("%-6s = %s",  'file', $t_track->yz->fname),
            sprintf("%-6s = %4s", 'unit', $t_track->unit     ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_track->factor->{val},
                eval { $t_track->factor->{cmt} } // ''
            ),
            sprintf("%-6s = %s",  'title',  $t_track->yz->title        ),
            sprintf("%-6s = %4s", 'epsout', $t_track->epsout           ),
            sprintf("%-6s = %4s", 'vtkout', $t_track->vtkout           ),
            sprintf("%-6s = %s",  'angel',  $t_track->yz->angel        ),
            sprintf("%-6s = %s",  'sangel', $t_track->yz->sangel       ),
            sprintf("%-6s = %4s", 'gshow',  $t_track->gshow            ),
            sprintf("%-6s = %4s", 'resol',  $t_track->cell_bnd->{resol}),
            sprintf("%-6s = %4s", 'width',  $t_track->cell_bnd->{width}),
            "";  # End

        # T-Track 3
        # > Mesh: xyz
        # > Axis: xy
        # > Particle distributions on xy plane,
        #   at mid-z of bremsstrahlung converter
        push @{$phits->sects->{t_track_xy_bconv}},
            (
                $t_track->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
            ) ? $t_track->sect_begin." off" :
                $t_track->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_track->flag,    $t_track->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s",    'mesh',   $t_track->mesh_shape->{xyz}   ),
            sprintf("%-6s = %4s",    'x-type', $t_track->mesh_types->{x}     ),
            sprintf("%-6s = %4s",    'nx',     $t_track->mesh_sizes->{x}     ),
            sprintf("%-6s = %4s",    'xmin',   $t_shared->mesh_ranges->{xmin}),
            sprintf("%-6s = %4s",    'xmax',   $t_shared->mesh_ranges->{xmax}),
            sprintf("%-6s = %4s",    'y-type', $t_track->mesh_types->{y}     ),
            sprintf("%-6s = %4s",    'ny',     $t_track->mesh_sizes->{y}     ),
            sprintf("%-6s = %4s",    'ymin',   $t_shared->mesh_ranges->{ymin}),
            sprintf("%-6s = %4s",    'ymax',   $t_shared->mesh_ranges->{ymax}),
            sprintf("%-6s = %4s",    'z-type', $t_track->mesh_types->{z}     ),
            sprintf("%-6s = %4s",    'nz',     $t_track->mesh_sizes->{1}     ),
            sprintf("%-6s = %10.5f", 'zmin',   $bconv->beam_ent              ),
            sprintf("%-6s = %10.5f", 'zmax',   $bconv->height                ),
            sprintf("%-6s = %4s",    'e-type', $t_track->mesh_types->{e}     ),
            sprintf("%-6s = %4s",    'ne',     $t_track->mesh_sizes->{1}     ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_track->mesh_ranges->{emin}{tot_nrg_range},
                $t_track->mesh_ranges->{emin_cmt}{tot_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_track->mesh_ranges->{emax}{tot_nrg_range},
                $t_track->mesh_ranges->{emax_cmt}{tot_nrg_range}
            ),
            # Particles of interest
            sprintf("%-6s = @{$t_track->particles_of_int}", 'part'),
            # Output settings
            sprintf("%-6s = %4s", 'axis', $t_track->xy_bconv->name ),
            sprintf("%-6s = %s",  'file', $t_track->xy_bconv->fname),
            sprintf("%-6s = %4s", 'unit', $t_track->unit           ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_track->factor->{val},
                eval { $t_track->factor->{cmt} } // ''
            ),
            sprintf("%-6s = %s",  'title',  $t_track->xy_bconv->title  ),
            sprintf("%-6s = %4s", 'epsout', $t_track->epsout           ),
            sprintf("%-6s = %4s", 'vtkout', $t_track->vtkout           ),
            sprintf("%-6s = %s",  'angel',  $t_track->xy_bconv->angel  ),
            sprintf("%-6s = %s",  'sangel', $t_track->xy_bconv->sangel ),
            sprintf("%-6s = %4s", 'gshow',  $t_track->gshow            ),
            sprintf("%-6s = %4s", 'resol',  $t_track->cell_bnd->{resol}),
            sprintf("%-6s = %4s", 'width',  $t_track->cell_bnd->{width}),
            "";  # End

        # T-Track 4
        # > Mesh: xyz
        # > Axis: xy
        # > Particle distributions on xy plane,
        #   at mid-z of molybdenum target
        push @{$phits->sects->{t_track_xy_motar}},
            $t_track->Ctrls->switch =~ /off/i ?
                $t_track->sect_begin." off" :
                $t_track->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_track->flag,    $t_track->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s", 'mesh',   $t_track->mesh_shape->{xyz}   ),
            sprintf("%-6s = %4s", 'x-type', $t_track->mesh_types->{x}     ),
            sprintf("%-6s = %4s", 'nx',     $t_track->mesh_sizes->{x}     ),
            sprintf("%-6s = %4s", 'xmin',   $t_shared->mesh_ranges->{xmin}),
            sprintf("%-6s = %4s", 'xmax',   $t_shared->mesh_ranges->{xmax}),
            sprintf("%-6s = %4s", 'y-type', $t_track->mesh_types->{y}     ),
            sprintf("%-6s = %4s", 'ny',     $t_track->mesh_sizes->{y}     ),
            sprintf("%-6s = %4s", 'ymin',   $t_shared->mesh_ranges->{ymin}),
            sprintf("%-6s = %4s", 'ymax',   $t_shared->mesh_ranges->{ymax}),
            sprintf("%-6s = %4s", 'z-type', $t_track->mesh_types->{z}     ),
            sprintf("%-6s = %4s", 'nz',     $t_track->mesh_sizes->{1}     ),
            sprintf(
                "%-6s = %10.5f",
                'zmin',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->beam_ent : $motar_rcc->beam_ent
            ),
            sprintf(
                "%-6s = %10.5f",
                'zmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    ($motar_trc->beam_ent + $motar_trc->height) :
                    ($motar_rcc->beam_ent + $motar_rcc->height)
            ),
            sprintf("%-6s = %4s", 'e-type', $t_track->mesh_types->{e}),
            sprintf("%-6s = %4s", 'ne',     $t_track->mesh_sizes->{1}),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_track->mesh_ranges->{emin}{tot_nrg_range},
                $t_track->mesh_ranges->{emin_cmt}{tot_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_track->mesh_ranges->{emax}{tot_nrg_range},
                $t_track->mesh_ranges->{emax_cmt}{tot_nrg_range}
            ),
            # Particles of interest
            sprintf("%-6s = @{$t_track->particles_of_int}", 'part'),
            # Output settings
            sprintf("%-6s = %4s", 'axis', $t_track->xy_motar->name ),
            sprintf("%-6s = %s",  'file', $t_track->xy_motar->fname),
            sprintf("%-6s = %4s", 'unit', $t_track->unit           ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_track->factor->{val},
                eval { $t_track->factor->{cmt} } // ''
            ),
            sprintf("%-6s = %s",  'title',  $t_track->xy_motar->title    ),
            sprintf("%-6s = %4s", 'epsout', $t_track->epsout             ),
            sprintf("%-6s = %4s", 'vtkout', $t_track->vtkout             ),
            sprintf("%-6s = %s",  'angel',  $t_track->xy_motar->angel_mo ),
            sprintf("%-6s = %s",  'sangel', $t_track->xy_motar->sangel_mo),
            sprintf("%-6s = %4s", 'gshow',  $t_track->gshow              ),
            sprintf("%-6s = %4s", 'resol',  $t_track->cell_bnd->{resol}  ),
            sprintf("%-6s = %4s", 'width',  $t_track->cell_bnd->{width}  ),
            "";  # End

        # T-Track 5
        # > Mesh: reg
        # > Axis: eng
        # > Particle fluences in bremsstrahlung converter volume
        push @{$phits->sects->{t_track_nrg_bconv}},
            (
                $t_track->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
            ) ? $t_track->sect_begin." off" :
                $t_track->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_track->flag,    $t_track->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s", 'mesh',   $t_track->mesh_shape->{reg}    ),
            sprintf("%-6s = %4s", 'reg',    $bconv->cell_props->{cell_id}  ),
            sprintf("%-6s = %4s", 'e-type', $t_track->mesh_types->{e}      ),
            sprintf("%-6s = %4s", 'ne',     $t_track->mesh_sizes->{e}      ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_track->mesh_ranges->{emin}{tot_nrg_range},
                $t_track->mesh_ranges->{emin_cmt}{tot_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_track->mesh_ranges->{emax}{tot_nrg_range},
                $t_track->mesh_ranges->{emax_cmt}{tot_nrg_range}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_track->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_track->nrg_bconv->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_track->nrg_bconv->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_track->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_track->factor->{val},
                eval { $t_track->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_track->nrg_bconv->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_track->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_track->nrg_bconv->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_track->nrg_bconv->sangel
            ),
            "";  # End

        # T-Track 6
        # > Mesh: reg
        # > Axis: eng
        # > Particle fluences in bremsstrahlung converter volume
        # > Low emax for photoneutrons (ceil(emax of [source] / 8))
        push @{$phits->sects->{t_track_nrg_bconv_low_emax}},
            (
                $t_track->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
                or not $t_track->is_neut_of_int
            ) ? $t_track->sect_begin." off" :
                $t_track->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_track->flag,    $t_track->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf(
                "%-6s = %4s",
                'mesh',
                $t_track->mesh_shape->{reg}
            ),
            sprintf(
                "%-6s = %4s",
                'reg',
                $bconv->cell_props->{cell_id}
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                $t_track->mesh_types->{e}
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $t_track->mesh_sizes->{e}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_track->mesh_ranges->{emin}{lower_nrg_range},
                $t_track->mesh_ranges->{emin_cmt}{lower_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_track->mesh_ranges->{emax}{lower_nrg_range},
                $t_track->mesh_ranges->{emax_cmt}{lower_nrg_range}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_track->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_track->nrg_bconv_low_emax->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_track->nrg_bconv_low_emax->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_track->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_track->factor->{val},
                eval { $t_track->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_track->nrg_bconv_low_emax->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_track->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_track->nrg_bconv_low_emax->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_track->nrg_bconv_low_emax->sangel
            ),
            "";  # End

        # T-Track 7
        # > Mesh: reg
        # > Axis: eng
        # > Particle fluences in molybdenum target volume
        # > *** Its bremsstrahlung fluences are used for yield calc. ***
        push @{$phits->sects->{t_track_nrg_motar}},
            $t_track->Ctrls->switch =~ /off/i ?
                $t_track->sect_begin." off" :
                $t_track->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_track->flag,    $t_track->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf(
                "%-6s = %4s",
                'mesh',
                $t_track->mesh_shape->{reg}
            ),
            sprintf(
                "%-6s = %4s",
                'reg',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->cell_props->{cell_id} :
                    $motar_rcc->cell_props->{cell_id}
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                2  # Fixed to use ne
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $yield_mo99->num_of_nrg_bins
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_track->mesh_ranges->{emin}{eff_nrg_range_interval_mo99},
                $t_track->mesh_ranges->{emin_cmt}{eff_nrg_range_interval_mo99}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_track->mesh_ranges->{emax}{eff_nrg_range_interval_mo99},
                $t_track->mesh_ranges->{emax_cmt}{eff_nrg_range_interval_mo99}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_track->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_track->nrg_motar->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_track->nrg_motar->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_track->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_track->factor->{val},
                eval { $t_track->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_track->nrg_motar->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_track->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_track->nrg_motar->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_track->nrg_motar->sangel
            ),
            "";  # End

        # T-Track 8
        # > Mesh: reg
        # > Axis: eng
        # > Particle fluences at molybdenum target volume
        # > Low emax for photoneutrons
        push @{$phits->sects->{t_track_nrg_motar_low_emax}},
            (
                $t_track->Ctrls->switch =~ /off/i
                or not $t_track->is_neut_of_int
            ) ? $t_track->sect_begin." off" :
                $t_track->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_track->flag,    $t_track->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf(
                "%-6s = %4s",
                'mesh',
                $t_track->mesh_shape->{reg}
            ),
            sprintf(
                "%-6s = %4s",
                'reg',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->cell_props->{cell_id} :
                    $motar_rcc->cell_props->{cell_id}
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                $t_track->mesh_types->{e}
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $t_track->mesh_sizes->{e}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_track->mesh_ranges->{emin}{lower_nrg_range},
                $t_track->mesh_ranges->{emin_cmt}{lower_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_track->mesh_ranges->{emax}{lower_nrg_range},
                $t_track->mesh_ranges->{emax_cmt}{lower_nrg_range}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_track->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s", 'axis',
                $t_track->nrg_motar_low_emax->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_track->nrg_motar_low_emax->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_track->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_track->factor->{val},
                eval { $t_track->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_track->nrg_motar_low_emax->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_track->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_track->nrg_motar_low_emax->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_track->nrg_motar_low_emax->sangel
            ),
            "";  # End

        # T-Track 9
        # > Mesh: reg
        # > Axis: eng
        # > Particle fluences in upstream flux monitor volume
        # > *** Its bremsstrahlung fluences are used for yield calc. ***
        push @{$phits->sects->{t_track_nrg_flux_mnt_up}},
            (
                $t_track->Ctrls->switch =~ /off/i
                or $flux_mnt_up->height == 0
            ) ? $t_track->sect_begin." off" :
                $t_track->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_track->flag,    $t_track->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf(
                "%-6s = %4s",
                'mesh',
                $t_track->mesh_shape->{reg}
            ),
            sprintf(
                "%-6s = %4s",
                'reg',
                $flux_mnt_up->cell_props->{cell_id}
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                2
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $yield_au196->num_of_nrg_bins
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_track->mesh_ranges->{emin}{eff_nrg_range_interval_au196},
                $t_track->mesh_ranges->{emin_cmt}{eff_nrg_range_interval_au196}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_track->mesh_ranges->{emax}{eff_nrg_range_interval_au196},
                $t_track->mesh_ranges->{emax_cmt}{eff_nrg_range_interval_au196}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_track->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_track->nrg_flux_mnt_up->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_track->nrg_flux_mnt_up->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_track->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_track->factor->{val},
                eval { $t_track->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_track->nrg_flux_mnt_up->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_track->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_track->nrg_flux_mnt_up->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_track->nrg_flux_mnt_up->sangel
            ),
            "";  # End

        # T-Track 10
        # > Mesh: reg
        # > Axis: eng
        # > Particle fluences in downstream flux monitor volume
        # > *** Its bremsstrahlung fluences are used for yield calc. ***
        push @{$phits->sects->{t_track_nrg_flux_mnt_down}},
            (
                $t_track->Ctrls->switch =~ /off/i
                or $flux_mnt_down->height == 0
            ) ? $t_track->sect_begin." off" :
                $t_track->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_track->flag,    $t_track->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf(
                "%-6s = %4s",
                'mesh',
                $t_track->mesh_shape->{reg}
            ),
            sprintf(
                "%-6s = %4s",
                'reg',
                $flux_mnt_down->cell_props->{cell_id}
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                2
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $yield_au196->num_of_nrg_bins
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_track->mesh_ranges->{emin}{eff_nrg_range_interval_au196},
                $t_track->mesh_ranges->{emin_cmt}{eff_nrg_range_interval_au196}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_track->mesh_ranges->{emax}{eff_nrg_range_interval_au196},
                $t_track->mesh_ranges->{emax_cmt}{eff_nrg_range_interval_au196}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_track->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_track->nrg_flux_mnt_down->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_track->nrg_flux_mnt_down->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_track->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_track->factor->{val},
                eval { $t_track->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_track->nrg_flux_mnt_down->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_track->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_track->nrg_flux_mnt_down->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_track->nrg_flux_mnt_down->sangel
            ),
            "";  # End

        # T-Cross 1
        # > Mesh: r-z
        # > Axis: eng
        # > Intact particle fluences
        push @{$phits->sects->{t_cross_intact}},
            (
                $t_cross->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
            ) ? $t_cross->sect_begin." off" :
                $t_cross->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_cross->flag,    $t_cross->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s",     'mesh',   $t_cross->mesh_shape->{rz}),
            sprintf("%-6s = %4s",     'r-type', $t_cross->mesh_types->{r} ),
            sprintf("%-6s = %4s",     'nr',     $t_cross->mesh_sizes->{1} ),
            sprintf("%-6s = %10.5f",  'rmin',   0                         ),
            sprintf("%-6s = %10.5f",  'rmax',   $bconv->radius            ),
            sprintf("%-6s = %4s",     'z-type', $t_cross->mesh_types->{z} ),
            sprintf("%-6s = %4s",     'nz',     $t_cross->mesh_sizes->{1} ),
            sprintf(
                "%-6s = %17.12f",
                'zmin',
                $phits->source->spat_dist_of_int->{t_cross_intact}{z_beg},
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmax',
                $phits->source->spat_dist_of_int->{t_cross_intact}{z_end},
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                2
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $yield_mo99->num_of_nrg_bins
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_cross->mesh_ranges->{emin}{eff_nrg_range_interval_mo99},
                $t_cross->mesh_ranges->{emin_cmt}{eff_nrg_range_interval_mo99}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_cross->mesh_ranges->{emax}{eff_nrg_range_interval_mo99},
                $t_cross->mesh_ranges->{emax_cmt}{eff_nrg_range_interval_mo99}
            ),
            # Particles of interest
            sprintf("%-6s = @{$t_cross->particles_of_int}", 'part'),
            # Output settings
            sprintf("%-6s = %4s", 'axis',  $t_cross->nrg_intact->name ),
            sprintf("%-6s = %s",  'file',  $t_cross->nrg_intact->fname),
            sprintf("%-6s = %4s", 'unit',  $t_cross->unit             ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_cross->factor->{val},
                eval { $t_cross->factor->{cmt} } // ''
            ),
            sprintf("%-6s = %s",  'title',  $t_cross->nrg_intact->title ),
            sprintf("%-6s = %4s", 'epsout', $t_cross->epsout            ),
            sprintf("%-6s = %s",  'angel',  $t_cross->nrg_intact->angel ),
            sprintf("%-6s = %s",  'sangel', $t_cross->nrg_intact->sangel),
            sprintf("%-6s = %4s", 'output', $t_cross->output            ),
            "";  # End

        # T-Cross 2
        # > Mesh: r-z
        # > Axis: eng
        # > Intact particle fluences
        # > Low emax for photoneutrons
        push @{$phits->sects->{t_cross_intact_low_emax}},
            (
                $t_cross->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
                or not $t_cross->is_neut_of_int
            ) ? $t_cross->sect_begin." off" :
                $t_cross->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_cross->flag,    $t_cross->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf(
                "%-6s = %4s",
                'mesh',
                $t_cross->mesh_shape->{rz}
            ),
            sprintf(
                "%-6s = %4s",
                'r-type',
                $t_cross->mesh_types->{r}
            ),
            sprintf(
                "%-6s = %4s",
                'nr',
                $t_cross->mesh_sizes->{1}
            ),
            sprintf(
                "%-6s = %10.5f",
                'rmin',
                0
            ),
            sprintf(
                "%-6s = %10.5f",
                'rmax',
                $bconv->radius
            ),
            sprintf(
                "%-6s = %4s",
                'z-type',
                $t_cross->mesh_types->{z}
            ),
            sprintf(
                "%-6s = %4s",
                'nz',
                $t_cross->mesh_sizes->{1}
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmin',
                $phits->source->spat_dist_of_int->{t_cross_intact}{z_beg},
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmax',
                $phits->source->spat_dist_of_int->{t_cross_intact}{z_end},
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                $t_cross->mesh_types->{e}
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $t_cross->mesh_sizes->{e}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_cross->mesh_ranges->{emin}{lower_nrg_range},
                $t_cross->mesh_ranges->{emin_cmt}{lower_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_cross->mesh_ranges->{emax}{lower_nrg_range},
                $t_cross->mesh_ranges->{emax_cmt}{lower_nrg_range}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_cross->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_cross->nrg_intact_low_emax->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_cross->nrg_intact_low_emax->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_cross->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_cross->factor->{val},
                eval { $t_cross->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_cross->nrg_intact_low_emax->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_cross->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_cross->nrg_intact_low_emax->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_cross->nrg_intact_low_emax->sangel
            ),
            sprintf(
                "%-6s = %4s",
                'output',
                $t_cross->output
            ),
            "";  # End

        # T-Cross 3
        # > Mesh: r-z
        # > Axis: eng
        # > Particle fluences at bremsstrahlung converter entrance
        push @{$phits->sects->{t_cross_bconv_ent}},
            (
                $t_cross->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
            ) ? $t_cross->sect_begin." off" :
                $t_cross->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_cross->flag,    $t_cross->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s",     'mesh',   $t_cross->mesh_shape->{rz}),
            sprintf("%-6s = %4s",     'r-type', $t_cross->mesh_types->{r} ),
            sprintf("%-6s = %4s",     'nr',     $t_cross->mesh_sizes->{1} ),
            sprintf("%-6s = %10.5f",  'rmin',   0                         ),
            sprintf("%-6s = %10.5f",  'rmax',   $bconv->radius            ),
            sprintf("%-6s = %4s",     'z-type', $t_cross->mesh_types->{z} ),
            sprintf("%-6s = %4s",     'nz',     $t_cross->mesh_sizes->{1} ),
            sprintf("%-6s = %17.12f", 'zmin',   $bconv->beam_ent          ),
            sprintf("%-6s = %17.12f", 'zmax',   ($bconv->beam_ent + 1e-07)),
            sprintf(
                "%-6s = %4s",
                'e-type',
                2
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $yield_mo99->num_of_nrg_bins
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_cross->mesh_ranges->{emin}{eff_nrg_range_interval_mo99},
                $t_cross->mesh_ranges->{emin_cmt}{eff_nrg_range_interval_mo99}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_cross->mesh_ranges->{emax}{eff_nrg_range_interval_mo99},
                $t_cross->mesh_ranges->{emax_cmt}{eff_nrg_range_interval_mo99}
            ),
            # Particles of interest
            sprintf("%-6s = @{$t_cross->particles_of_int}", 'part'),
            # Output settings
            sprintf("%-6s = %4s", 'axis',  $t_cross->nrg_bconv_ent->name ),
            sprintf("%-6s = %s",  'file',  $t_cross->nrg_bconv_ent->fname),
            sprintf("%-6s = %4s", 'unit',  $t_cross->unit                ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_cross->factor->{val},
                eval { $t_cross->factor->{cmt} } // ''
            ),
            sprintf("%-6s = %s",  'title',  $t_cross->nrg_bconv_ent->title ),
            sprintf("%-6s = %4s", 'epsout', $t_cross->epsout               ),
            sprintf("%-6s = %s",  'angel',  $t_cross->nrg_bconv_ent->angel ),
            sprintf("%-6s = %s",  'sangel', $t_cross->nrg_bconv_ent->sangel),
            sprintf("%-6s = %4s", 'output', $t_cross->output               ),
            "";  # End

        # T-Cross 4
        # > Mesh: r-z
        # > Axis: eng
        # > Particle fluences at bremsstrahlung converter entrance
        # > Low emax for photoneutrons
        push @{$phits->sects->{t_cross_bconv_ent_low_emax}},
            (
                $t_cross->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
                or not $t_cross->is_neut_of_int
            ) ? $t_cross->sect_begin." off" :
                $t_cross->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_cross->flag,    $t_cross->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf(
                "%-6s = %4s",
                'mesh',
                $t_cross->mesh_shape->{rz}
            ),
            sprintf(
                "%-6s = %4s",
                'r-type',
                $t_cross->mesh_types->{r}
            ),
            sprintf(
                "%-6s = %4s",
                'nr',
                $t_cross->mesh_sizes->{1}
            ),
            sprintf(
                "%-6s = %10.5f",
                'rmin',
                0
            ),
            sprintf(
                "%-6s = %10.5f",
                'rmax',
                $bconv->radius
            ),
            sprintf(
                "%-6s = %4s",
                'z-type',
                $t_cross->mesh_types->{z}
            ),
            sprintf(
                "%-6s = %4s",
                'nz',
                $t_cross->mesh_sizes->{1}
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmin',
                $bconv->beam_ent
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmax',
                ($bconv->beam_ent + 1e-07)
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                $t_cross->mesh_types->{e}
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $t_cross->mesh_sizes->{e}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_cross->mesh_ranges->{emin}{lower_nrg_range},
                $t_cross->mesh_ranges->{emin_cmt}{lower_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_cross->mesh_ranges->{emax}{lower_nrg_range},
                $t_cross->mesh_ranges->{emax_cmt}{lower_nrg_range}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_cross->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_cross->nrg_bconv_ent_low_emax->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_cross->nrg_bconv_ent_low_emax->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_cross->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_cross->factor->{val},
                eval { $t_cross->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_cross->nrg_bconv_ent_low_emax->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_cross->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_cross->nrg_bconv_ent_low_emax->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_cross->nrg_bconv_ent_low_emax->sangel
            ),
            sprintf(
                "%-6s = %4s",
                'output',
                $t_cross->output
            ),
            "";  # End

        # T-Cross 5
        # > Mesh: r-z
        # > Axis: eng
        # > Particle fluences at bremsstrahlung converter exit
        push @{$phits->sects->{t_cross_bconv_exit}},
            (
                $t_cross->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
            ) ? $t_cross->sect_begin." off" :
                $t_cross->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_cross->flag,    $t_cross->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s",    'mesh',   $t_cross->mesh_shape->{rz}),
            sprintf("%-6s = %4s",    'r-type', $t_cross->mesh_types->{r} ),
            sprintf("%-6s = %4s",    'nr',     $t_cross->mesh_sizes->{1} ),
            sprintf("%-6s = %10.5f", 'rmin',   0                         ),
            sprintf("%-6s = %10.5f", 'rmax',   $bconv->radius            ),
            sprintf("%-6s = %4s",    'z-type', $t_cross->mesh_types->{z} ),
            sprintf("%-6s = %4s",    'nz',     $t_cross->mesh_sizes->{1} ),
            sprintf(
                "%-6s = %17.12f",
                'zmin',
                ($bconv->beam_ent + $bconv->height)
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmax',
                ($bconv->beam_ent + $bconv->height + 1e-07)
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                2
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $yield_mo99->num_of_nrg_bins
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_cross->mesh_ranges->{emin}{eff_nrg_range_interval_mo99},
                $t_cross->mesh_ranges->{emin_cmt}{eff_nrg_range_interval_mo99}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_cross->mesh_ranges->{emax}{eff_nrg_range_interval_mo99},
                $t_cross->mesh_ranges->{emax_cmt}{eff_nrg_range_interval_mo99}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_cross->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_cross->nrg_bconv_exit->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_cross->nrg_bconv_exit->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_cross->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_cross->factor->{val},
                eval { $t_cross->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_cross->nrg_bconv_exit->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_cross->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_cross->nrg_bconv_exit->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_cross->nrg_bconv_exit->sangel
            ),
            sprintf(
                "%-6s = %4s",
                'output',
                $t_cross->output
            ),
            "";  # End

        # T-Cross 6
        # > Mesh: r-z
        # > Axis: eng
        # > Particle fluences at bremsstrahlung converter exit
        # > Low emax for photoneutrons
        push @{$phits->sects->{t_cross_bconv_exit_low_emax}},
            (
                $t_cross->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
                or not $t_cross->is_neut_of_int
            ) ? $t_cross->sect_begin." off" :
                $t_cross->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_cross->flag,    $t_cross->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf(
                "%-6s = %4s",
                'mesh',
                $t_cross->mesh_shape->{rz}
            ),
            sprintf(
                "%-6s = %4s",
                'r-type',
                $t_cross->mesh_types->{r}
            ),
            sprintf(
                "%-6s = %4s",
                'nr',
                $t_cross->mesh_sizes->{1}
            ),
            sprintf(
                "%-6s = %10.5f",
                'rmin',
                0
            ),
            sprintf(
                "%-6s = %10.5f",
                'rmax',
                $bconv->radius
            ),
            sprintf(
                "%-6s = %4s",
                'z-type',
                $t_cross->mesh_types->{z}
            ),
            sprintf(
                "%-6s = %4s",
                'nz',
                $t_cross->mesh_sizes->{1}
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmin',
                ($bconv->beam_ent + $bconv->height)
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmax',
                ($bconv->beam_ent + $bconv->height + 1e-07)
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                $t_cross->mesh_types->{e}
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $t_cross->mesh_sizes->{e}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_cross->mesh_ranges->{emin}{lower_nrg_range},
                $t_cross->mesh_ranges->{emin_cmt}{lower_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_cross->mesh_ranges->{emax}{lower_nrg_range},
                $t_cross->mesh_ranges->{emax_cmt}{lower_nrg_range}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_cross->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_cross->nrg_bconv_exit_low_emax->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_cross->nrg_bconv_exit_low_emax->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_cross->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_cross->factor->{val},
                eval { $t_cross->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_cross->nrg_bconv_exit_low_emax->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_cross->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_cross->nrg_bconv_exit_low_emax->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_cross->nrg_bconv_exit_low_emax->sangel
            ),
            sprintf(
                "%-6s = %4s",
                'output',
                $t_cross->output
            ),
            "";  # End

        # T-Cross 7
        # > Mesh: r-z
        # > Axis: eng
        # > Particle fluences at molybdenum target entrance
        push @{$phits->sects->{t_cross_motar_ent}},
            $t_cross->Ctrls->switch =~ /off/i ?
                $t_cross->sect_begin." off" :
                $t_cross->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_cross->flag,    $t_cross->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s",    'mesh',   $t_cross->mesh_shape->{rz}),
            sprintf("%-6s = %4s",    'r-type', $t_cross->mesh_types->{r} ),
            sprintf("%-6s = %4s",    'nr',     $t_cross->mesh_sizes->{1} ),
            sprintf("%-6s = %10.5f", 'rmin',   0                         ),
            sprintf(
                "%-6s = %10.5f",
                'rmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->bot_radius : $motar_rcc->radius
            ),
            sprintf("%-6s = %4s", 'z-type', $t_cross->mesh_types->{z}),
            sprintf("%-6s = %4s", 'nz',     $t_cross->mesh_sizes->{1}),
            sprintf(
                "%-6s = %17.12f",
                'zmin',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->beam_ent : $motar_rcc->beam_ent
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    ($motar_trc->beam_ent + 1e-07) :
                    ($motar_rcc->beam_ent + 1e-07)
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                2
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $yield_mo99->num_of_nrg_bins
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_cross->mesh_ranges->{emin}{eff_nrg_range_interval_mo99},
                $t_cross->mesh_ranges->{emin_cmt}{eff_nrg_range_interval_mo99}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_cross->mesh_ranges->{emax}{eff_nrg_range_interval_mo99},
                $t_cross->mesh_ranges->{emax_cmt}{eff_nrg_range_interval_mo99}
            ),
            # Particles of interest
            sprintf("%-6s = @{$t_cross->particles_of_int}", 'part'),
            # Output settings
            sprintf("%-6s = %4s", 'axis', $t_cross->nrg_motar_ent->name ),
            sprintf("%-6s = %s",  'file', $t_cross->nrg_motar_ent->fname),
            sprintf("%-6s = %4s", 'unit', $t_cross->unit                ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_cross->factor->{val},
                eval { $t_cross->factor->{cmt} } // ''
            ),
            sprintf("%-6s = %s",  'title',  $t_cross->nrg_motar_ent->title ),
            sprintf("%-6s = %4s", 'epsout', $t_cross->epsout               ),
            sprintf("%-6s = %s",  'angel',  $t_cross->nrg_motar_ent->angel ),
            sprintf("%-6s = %s",  'sangel', $t_cross->nrg_motar_ent->sangel),
            sprintf("%-6s = %4s", 'output', $t_cross->output               ),
            "";  # End

        # T-Cross 8
        # > Mesh: r-z
        # > Axis: eng
        # > Particle fluences at molybdenum target entrance
        # > Low emax for photoneutrons
        push @{$phits->sects->{t_cross_motar_ent_low_emax}},
            (
                $t_cross->Ctrls->switch =~ /off/i
                or not $t_cross->is_neut_of_int
            ) ? $t_cross->sect_begin." off" :
                $t_cross->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_cross->flag,    $t_cross->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf(
                "%-6s = %4s",
                'mesh',
                $t_cross->mesh_shape->{rz}
            ),
            sprintf(
                "%-6s = %4s",
                'r-type',
                $t_cross->mesh_types->{r}
            ),
            sprintf(
                "%-6s = %4s",
                'nr',
                $t_cross->mesh_sizes->{1}
            ),
            sprintf(
                "%-6s = %10.5f",
                'rmin',
                0
            ),
            sprintf(
                "%-6s = %10.5f",
                'rmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->bot_radius : $motar_rcc->radius
            ),
            sprintf("%-6s = %4s", 'z-type', $t_cross->mesh_types->{z}),
            sprintf("%-6s = %4s", 'nz',     $t_cross->mesh_sizes->{1}),
            sprintf(
                "%-6s = %17.12f",
                'zmin',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->beam_ent : $motar_rcc->beam_ent
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    ($motar_trc->beam_ent + 1e-07) :
                    ($motar_rcc->beam_ent + 1e-07)
            ),
            sprintf("%-6s = %4s", 'e-type', $t_cross->mesh_types->{e}),
            sprintf("%-6s = %4s", 'ne',     $t_cross->mesh_sizes->{e}),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_cross->mesh_ranges->{emin}{lower_nrg_range},
                $t_cross->mesh_ranges->{emin_cmt}{lower_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_cross->mesh_ranges->{emax}{lower_nrg_range},
                $t_cross->mesh_ranges->{emax_cmt}{lower_nrg_range}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_cross->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_cross->nrg_motar_ent_low_emax->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_cross->nrg_motar_ent_low_emax->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_cross->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_cross->factor->{val},
                eval { $t_cross->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_cross->nrg_motar_ent_low_emax->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_cross->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_cross->nrg_motar_ent_low_emax->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_cross->nrg_motar_ent_low_emax->sangel
            ),
            sprintf(
                "%-6s = %4s",
                'output',
                $t_cross->output
            ),
            "";  # End

        # T-Cross dump
        # > Generates a dump source entering the molybdenum target.
        push @{$phits->sects->{t_cross_motar_ent_dump}},
            sprintf(
                "%s".
                "  %s ".
                "%s No. %s",
                $t_cross_dump->sect_begin,
                $phits->Cmt->symb,
                $t_cross_dump->flag, $t_cross_dump->inc_t_counter(),
            ),
            # Meshing
            sprintf("%-6s = %4s", 'mesh', $t_cross_dump->mesh_shape->{reg}),
            sprintf("%-6s = %4s", 'reg',  1                               ),
            sprintf(
                "%10s %3s %6s %4s %4s",
                ' ',
                'non',
                'r-from',
                'r-to',
                'area'
            ),
            sprintf(
                "%10s %3s %6s %4s %4s",
                ' ',
                1,
                $motar_ent->cell_props->{cell_id},
                $motar_ent_to->cell_props->{cell_id},
                $motar_ent->area
            ),
            sprintf("%-6s = %4s", 'e-type', $t_cross_dump->mesh_types->{e}),
            sprintf("%-6s = %4s", 'ne',     $t_cross_dump->mesh_sizes->{e}),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_cross_dump->mesh_ranges->{emin},
                $t_cross_dump->mesh_ranges->{emin_cmt}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_cross_dump->mesh_ranges->{emax},
                $t_cross_dump->mesh_ranges->{emax_cmt}
            ),
            # Particles of interest
            sprintf(
                "%-6s = %s",
                'part',
                $t_cross_dump->particles_of_int->[0]
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_cross_dump->nrg_motar_ent_dump->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_cross_dump->nrg_motar_ent_dump->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_cross_dump->unit
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_cross_dump->nrg_motar_ent_dump->title
            ),
            sprintf(
                "%-6s = %4s",
                'output',
                $t_cross_dump->output
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_cross_dump->epsout
            ),
            sprintf(
                "%-6s = %4s",
                'dump',
                $t_cross_dump->dump->{num_dat},
            ),
            sprintf(
                "%11s %s",
                ' ',
                $t_cross_dump->dump->{dat}
            ),
            "";  # End

        # T-Cross 9
        # > Mesh: r-z
        # > Axis: eng
        # > Particle fluences at molybdenum target exit
        push @{$phits->sects->{t_cross_motar_exit}},
            $t_cross->Ctrls->switch =~ /off/i ?
                $t_cross->sect_begin." off" :
                $t_cross->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_cross->flag,    $t_cross->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s",    'mesh',   $t_cross->mesh_shape->{rz}),
            sprintf("%-6s = %4s",    'r-type', $t_cross->mesh_types->{r} ),
            sprintf("%-6s = %4s",    'nr',     $t_cross->mesh_sizes->{1} ),
            sprintf("%-6s = %10.5f", 'rmin',   0    ),
            sprintf(
                "%-6s = %10.5f",
                'rmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->top_radius : $motar_rcc->radius
            ),
            sprintf("%-6s = %4s", 'z-type', $t_cross->mesh_types->{z}),
            sprintf("%-6s = %4s", 'nz',     $t_cross->mesh_sizes->{1}),
            sprintf(
                "%-6s = %17.12f",
                'zmin',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->beam_ent + $motar_trc->height :
                    $motar_rcc->beam_ent + $motar_rcc->height
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    ($motar_trc->beam_ent + $motar_trc->height + 1e-07) :
                    ($motar_rcc->beam_ent + $motar_rcc->height + 1e-07)
            ),
            sprintf(
                "%-6s = %4s",
                'e-type',
                2
            ),
            sprintf(
                "%-6s = %4s",
                'ne',
                $yield_mo99->num_of_nrg_bins
            ),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_cross->mesh_ranges->{emin}{eff_nrg_range_interval_mo99},
                $t_cross->mesh_ranges->{emin_cmt}{eff_nrg_range_interval_mo99}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_cross->mesh_ranges->{emax}{eff_nrg_range_interval_mo99},
                $t_cross->mesh_ranges->{emax_cmt}{eff_nrg_range_interval_mo99}
            ),
            # Particles of interest
            sprintf("%-6s = @{$t_cross->particles_of_int}", 'part'),
            # Output settings
            sprintf("%-6s = %4s", 'axis', $t_cross->nrg_motar_exit->name ),
            sprintf("%-6s = %s",  'file', $t_cross->nrg_motar_exit->fname),
            sprintf("%-6s = %4s", 'unit', $t_cross->unit                 ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_cross->factor->{val},
                eval { $t_cross->factor->{cmt} } // ''
            ),
            sprintf("%-6s = %s",  'title',  $t_cross->nrg_motar_exit->title ),
            sprintf("%-6s = %4s", 'epsout', $t_cross->epsout                ),
            sprintf("%-6s = %s",  'angel',  $t_cross->nrg_motar_exit->angel ),
            sprintf("%-6s = %s",  'sangel', $t_cross->nrg_motar_exit->sangel),
            sprintf("%-6s = %4s", 'output', $t_cross->output                ),
            "";  # End

        # T-Cross 10
        # > Mesh: r-z
        # > Axis: eng
        # > Particle fluences at molybdenum target exit
        # > Low emax for photoneutrons
        push @{$phits->sects->{t_cross_motar_exit_low_emax}},
            (
                $t_cross->Ctrls->switch =~ /off/i
                or not $t_cross->is_neut_of_int
            ) ? $t_cross->sect_begin." off" :
                $t_cross->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_cross->flag,    $t_cross->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf(
                "%-6s = %4s",
                'mesh',
                $t_cross->mesh_shape->{rz}
            ),
            sprintf(
                "%-6s = %4s",
                'r-type',
                $t_cross->mesh_types->{r}
            ),
            sprintf(
                "%-6s = %4s",
                'nr',
                $t_cross->mesh_sizes->{1}
            ),
            sprintf(
                "%-6s = %10.5f",
                'rmin',
                0
            ),
            sprintf(
                "%-6s = %10.5f",
                'rmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->top_radius : $motar_rcc->radius
            ),
            sprintf("%-6s = %4s", 'z-type', $t_cross->mesh_types->{z}),
            sprintf("%-6s = %4s", 'nz',     $t_cross->mesh_sizes->{1}),
            sprintf(
                "%-6s = %17.12f",
                'zmin',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->beam_ent + $motar_trc->height :
                    $motar_rcc->beam_ent + $motar_rcc->height
            ),
            sprintf(
                "%-6s = %17.12f",
                'zmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    ($motar_trc->beam_ent + $motar_trc->height + 1e-07) :
                    ($motar_rcc->beam_ent + $motar_rcc->height + 1e-07)
            ),
            sprintf("%-6s = %4s", 'e-type', $t_cross->mesh_types->{e}),
            sprintf("%-6s = %4s", 'ne',     $t_cross->mesh_sizes->{e}),
            sprintf(
                "%-6s = %4s%s",
                'emin',
                $t_cross->mesh_ranges->{emin}{lower_nrg_range},
                $t_cross->mesh_ranges->{emin_cmt}{lower_nrg_range}
            ),
            sprintf(
                "%-6s = %4s%s",
                'emax',
                $t_cross->mesh_ranges->{emax}{lower_nrg_range},
                $t_cross->mesh_ranges->{emax_cmt}{lower_nrg_range}
            ),
            # Particles of interest
            sprintf(
                "%-6s = @{$t_cross->particles_of_int}",
                'part'
            ),
            # Output settings
            sprintf(
                "%-6s = %4s",
                'axis',
                $t_cross->nrg_motar_exit_low_emax->name
            ),
            sprintf(
                "%-6s = %s",
                'file',
                $t_cross->nrg_motar_exit_low_emax->fname
            ),
            sprintf(
                "%-6s = %4s",
                'unit',
                $t_cross->unit
            ),
            sprintf(
                "%-6s = %4g%s",
                'factor',
                $t_cross->factor->{val},
                eval { $t_cross->factor->{cmt} } // ''
            ),
            sprintf(
                "%-6s = %s",
                'title',
                $t_cross->nrg_motar_exit_low_emax->title
            ),
            sprintf(
                "%-6s = %4s",
                'epsout',
                $t_cross->epsout
            ),
            sprintf(
                "%-6s = %s",
                'angel',
                $t_cross->nrg_motar_exit_low_emax->angel
            ),
            sprintf(
                "%-6s = %s",
                'sangel',
                $t_cross->nrg_motar_exit_low_emax->sangel
            ),
            sprintf(
                "%-6s = %4s",
                'output',
                $t_cross->output
            ),
            "";  # End

        # T-Heat 1
        # > Mesh: xyz
        # > Axis: xz
        # > Heat energy distribution on xz plane
        push @{$phits->sects->{t_heat_xz}},
            $t_heat->Ctrls->switch =~ /off/i ?
                $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s", 'mesh',   $t_heat->mesh_shape->{xyz}    ),
            sprintf("%-8s = %4s", 'x-type', $t_heat->mesh_types->{x}      ),
            sprintf("%-8s = %4s", 'nx',     $t_heat->mesh_sizes->{x}      ),
            sprintf("%-8s = %4s", 'xmin',   $t_shared->mesh_ranges->{xmin}),
            sprintf("%-8s = %4s", 'xmax',   $t_shared->mesh_ranges->{xmax}),
            sprintf("%-8s = %4s", 'y-type', $t_heat->mesh_types->{y}      ),
            sprintf("%-8s = %4s", 'ny',     $t_shared->mesh_sizes->{1}    ),
            sprintf("%-8s = %4s", 'ymin',   $t_shared->mesh_ranges->{ymin}),
            sprintf("%-8s = %4s", 'ymax',   $t_shared->mesh_ranges->{ymax}),
            sprintf("%-8s = %4s", 'z-type', $t_heat->mesh_types->{z}      ),
            sprintf("%-8s = %4s", 'nz',     $t_heat->mesh_sizes->{z}      ),
            sprintf("%-8s = %10.5f", 'zmin', $t_shared->mesh_ranges->{zmin}),
            sprintf("%-8s = %10.5f", 'zmax', $t_shared->mesh_ranges->{zmax}),
            # Output settings
            sprintf("%-8s = %4s", 'axis',   $t_heat->xz->name  ),
            sprintf("%-8s = %s",  'file',   $t_heat->xz->fname ),
            sprintf("%-8s = %4s", 'unit',   $t_heat->unit      ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat->factor->{val},
                eval { $t_heat->factor->{cmt} } // ''
            ),
            sprintf("%-8s = %s",  'title',    $t_heat->xz->title        ),
            sprintf("%-8s = %4s", 'epsout',   $t_heat->epsout           ),
            sprintf("%-8s = %4s", 'vtkout',   $t_heat->vtkout           ),
            sprintf("%-8s = %s",  'angel',    $t_heat->xz->angel        ),
            sprintf("%-8s = %s",  'sangel',   $t_heat->xz->sangel       ),
            sprintf("%-8s = %4s", 'output',   $t_heat->output           ),
            sprintf("%-8s = %4s", 'gshow',    $t_heat->gshow            ),
            sprintf("%-8s = %4s", 'resol',    $t_heat->cell_bnd->{resol}),
            sprintf("%-8s = %4s", 'width',    $t_heat->cell_bnd->{width}),
            sprintf("%-8s = %4s", 'material', $t_heat->material         ),
            sprintf("%-8s = %4s", 'electron', $t_heat->electron         ),
            "";  # End

        # T-Heat 2
        # > Mesh: xyz
        # > Axis: yz
        # > Heat energy distribution on yz plane
        push @{$phits->sects->{t_heat_yz}},
            $t_heat->Ctrls->switch =~ /off/i ?
                $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s", 'mesh',   $t_heat->mesh_shape->{xyz}    ),
            sprintf("%-8s = %4s", 'x-type', $t_heat->mesh_types->{x}      ),
            sprintf("%-8s = %4s", 'nx',     $t_heat->mesh_sizes->{1}      ),
            sprintf("%-8s = %4s", 'xmin',   $t_shared->mesh_ranges->{xmin}),
            sprintf("%-8s = %4s", 'xmax',   $t_shared->mesh_ranges->{xmax}),
            sprintf("%-8s = %4s", 'y-type', $t_heat->mesh_types->{y}      ),
            sprintf("%-8s = %4s", 'ny',     $t_heat->mesh_sizes->{y}      ),
            sprintf("%-8s = %4s", 'ymin',   $t_shared->mesh_ranges->{ymin}),
            sprintf("%-8s = %4s", 'ymax',   $t_shared->mesh_ranges->{ymax}),
            sprintf("%-8s = %4s", 'z-type', $t_heat->mesh_types->{z}      ),
            sprintf("%-8s = %4s", 'nz',     $t_heat->mesh_sizes->{z}      ),
            sprintf("%-8s = %10.5f", 'zmin', $t_shared->mesh_ranges->{zmin}),
            sprintf("%-8s = %10.5f", 'zmax', $t_shared->mesh_ranges->{zmax}),
            # Output settings
            sprintf("%-8s = %4s", 'axis',   $t_heat->yz->name  ),
            sprintf("%-8s = %s",  'file',   $t_heat->yz->fname ),
            sprintf("%-8s = %4s", 'unit',   $t_heat->unit      ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat->factor->{val},
                eval { $t_heat->factor->{cmt} } // ''
            ),
            sprintf("%-8s = %s",  'title',    $t_heat->yz->title        ),
            sprintf("%-8s = %4s", 'epsout',   $t_heat->epsout           ),
            sprintf("%-8s = %4s", 'vtkout',   $t_heat->vtkout           ),
            sprintf("%-8s = %s",  'angel',    $t_heat->yz->angel        ),
            sprintf("%-8s = %s",  'sangel',   $t_heat->yz->sangel       ),
            sprintf("%-8s = %4s", 'output',   $t_heat->output           ),
            sprintf("%-8s = %4s", 'gshow',    $t_heat->gshow            ),
            sprintf("%-8s = %4s", 'resol',    $t_heat->cell_bnd->{resol}),
            sprintf("%-8s = %4s", 'width',    $t_heat->cell_bnd->{width}),
            sprintf("%-8s = %4s", 'material', $t_heat->material         ),
            sprintf("%-8s = %4s", 'electron', $t_heat->electron         ),
            "";  # End

        # T-Heat 3
        # > Mesh: xyz
        # > Axis: xy
        # > Heat energy distribution on xy plane,
        #   at z of bremsstrahlung converter
        push @{$phits->sects->{t_heat_xy_bconv}},
            (
                $t_heat->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
            ) ? $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s",    'mesh',   $t_heat->mesh_shape->{xyz}    ),
            sprintf("%-8s = %4s",    'x-type', $t_heat->mesh_types->{x}      ),
            sprintf("%-8s = %4s",    'nx',     $t_heat->mesh_sizes->{x}      ),
            sprintf("%-8s = %4s",    'xmin',   $t_shared->mesh_ranges->{xmin}),
            sprintf("%-8s = %4s",    'xmax',   $t_shared->mesh_ranges->{xmax}),
            sprintf("%-8s = %4s",    'y-type', $t_heat->mesh_types->{y}      ),
            sprintf("%-8s = %4s",    'ny',     $t_heat->mesh_sizes->{y}      ),
            sprintf("%-8s = %4s",    'ymin',   $t_shared->mesh_ranges->{ymin}),
            sprintf("%-8s = %4s",    'ymax',   $t_shared->mesh_ranges->{ymax}),
            sprintf("%-8s = %4s",    'z-type', $t_heat->mesh_types->{z}      ),
            sprintf("%-8s = %4s",    'nz',     $t_heat->mesh_sizes->{1}      ),
            sprintf("%-8s = %10.5f", 'zmin',   $bconv->beam_ent              ),
            sprintf("%-8s = %10.5f", 'zmax',   $bconv->height                ),
            # Output settings
            sprintf("%-8s = %4s", 'axis', $t_heat->xy_bconv->name ),
            sprintf("%-8s = %s",  'file', $t_heat->xy_bconv->fname),
            sprintf("%-8s = %4s", 'unit', $t_heat->unit           ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat->factor->{val},
                eval { $t_heat->factor->{cmt} } // ''
            ),
            sprintf("%-8s = %s",  'title',    $t_heat->xy_bconv->title  ),
            sprintf("%-8s = %4s", 'epsout',   $t_heat->epsout           ),
            sprintf("%-8s = %4s", 'vtkout',   $t_heat->vtkout           ),
            sprintf("%-8s = %s",  'angel',    $t_heat->xy_bconv->angel  ),
            sprintf("%-8s = %s",  'sangel',   $t_heat->xy_bconv->sangel ),
            sprintf("%-8s = %4s", 'output',   $t_heat->output           ),
            sprintf("%-8s = %4s", 'gshow',    $t_heat->gshow            ),
            sprintf("%-8s = %4s", 'resol',    $t_heat->cell_bnd->{resol}),
            sprintf("%-8s = %4s", 'width',    $t_heat->cell_bnd->{width}),
            sprintf("%-8s = %4s", 'material', $t_heat->material         ),
            sprintf("%-8s = %4s", 'electron', $t_heat->electron         ),
            "";  # End

        # T-Heat 4
        # > Mesh: xyz
        # > Axis: xy
        # > Heat energy distribution on xy plane,
        #   at z of bremsstrahlung converter
        # > *********************************************
        # > ***** To be converted to an MAPDL table *****
        #   ***** DO NOT USE ANGEL CMD LIKE 'cmmm'  *****
        # > *********************************************
        push @{$phits->sects->{t_heat_xy_bconv_ansys}},
            (
                $t_heat->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
            ) ? $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s", 'mesh',  $t_heat_mapdl->mesh_shape->{xyz}),
            sprintf("%-8s = %4s", 'x-type', $t_heat_mapdl->mesh_types->{x} ),
            sprintf("%-8s = %4s", 'nx',     $t_heat_mapdl->mesh_sizes->{x} ),
            sprintf("%-8s = %4s", 'xmin',   $t_shared->mesh_ranges->{xmin} ),
            sprintf("%-8s = %4s", 'xmax',   $t_shared->mesh_ranges->{xmax} ),
            sprintf("%-8s = %4s", 'y-type', $t_heat_mapdl->mesh_types->{y} ),
            sprintf("%-8s = %4s", 'ny',     $t_heat_mapdl->mesh_sizes->{y} ),
            sprintf("%-8s = %4s", 'ymin',   $t_shared->mesh_ranges->{ymin} ),
            sprintf("%-8s = %4s", 'ymax',   $t_shared->mesh_ranges->{ymax} ),
            sprintf("%-8s = %4s", 'z-type', $t_heat_mapdl->mesh_types->{z} ),
            sprintf("%-8s = %4s", 'nz',     $t_heat_mapdl->mesh_sizes->{z} ),
            sprintf("%-8s = %10.5f", 'zmin', $bconv->beam_ent),
            sprintf("%-8s = %10.5f", 'zmax', $bconv->height  ),
            # Output settings
            sprintf(
                "%-8s = %4s",
                'axis',
                $t_heat_mapdl->xy_bconv_mapdl->name
            ),
            sprintf(
                "%-8s = %s",
                'file',
                $t_heat_mapdl->xy_bconv_mapdl->fname
            ),
            sprintf(
                "%-8s = %4s",
                'unit',
                $t_heat_mapdl->unit
            ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat_mapdl->factor->{val},
                eval { $t_heat_mapdl->factor->{cmt} } // ''
            ),
            sprintf(
                "%-8s = %s",
                'title',
                $t_heat_mapdl->xy_bconv_mapdl->title
            ),
            sprintf(
                "%-8s = %4s",
                'output',
                $t_heat_mapdl->output
            ),
            sprintf(
                "%-8s = %4s",
                '2d-type',
                $t_heat_mapdl->two_dim_type
            ),
            sprintf(
                "%-8s = %4s",
                'material',
                $t_heat_mapdl->material
            ),
            sprintf(
                "%-8s = %4s",
                'electron',
                $t_heat_mapdl->electron
            ),
            "";  # End

        # T-Heat 5
        # > Mesh: xyz
        # > Axis: xy
        # > Heat energy distribution on xy plane, at z of molybdenum target
        push @{$phits->sects->{t_heat_xy_motar}},
            $t_heat->Ctrls->switch =~ /off/i ?
                $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s", 'mesh',   $t_heat->mesh_shape->{xyz}    ),
            sprintf("%-8s = %4s", 'x-type', $t_heat->mesh_types->{x}      ),
            sprintf("%-8s = %4s", 'nx',     $t_heat->mesh_sizes->{x}      ),
            sprintf("%-8s = %4s", 'xmin',   $t_shared->mesh_ranges->{xmin}),
            sprintf("%-8s = %4s", 'xmax',   $t_shared->mesh_ranges->{xmax}),
            sprintf("%-8s = %4s", 'y-type', $t_heat->mesh_types->{y}      ),
            sprintf("%-8s = %4s", 'ny',     $t_heat->mesh_sizes->{y}      ),
            sprintf("%-8s = %4s", 'ymin',   $t_shared->mesh_ranges->{ymin}),
            sprintf("%-8s = %4s", 'ymax',   $t_shared->mesh_ranges->{ymax}),
            sprintf("%-8s = %4s", 'z-type', $t_heat->mesh_types->{z}      ),
            sprintf("%-8s = %4s", 'nz',     $t_heat->mesh_sizes->{1}      ),
            sprintf(
                "%-8s = %10.5f",
                'zmin',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->beam_ent : $motar_rcc->beam_ent
            ),
            sprintf(
                "%-8s = %10.5f",
                'zmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    ($motar_trc->beam_ent + $motar_trc->height) :
                    ($motar_rcc->beam_ent + $motar_rcc->height)
            ),
            # Output settings
            sprintf("%-8s = %4s", 'axis', $t_heat->xy_motar->name ),
            sprintf("%-8s = %s",  'file', $t_heat->xy_motar->fname),
            sprintf("%-8s = %4s", 'unit', $t_heat->unit           ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat->factor->{val},
                eval { $t_heat->factor->{cmt} } // ''
            ),
            sprintf("%-8s = %s",  'title',    $t_heat->xy_motar->title    ),
            sprintf("%-8s = %4s", 'epsout',   $t_heat->epsout             ),
            sprintf("%-8s = %4s", 'vtkout',   $t_heat->vtkout             ),
            sprintf("%-8s = %s",  'angel',    $t_heat->xy_motar->angel_mo ),
            sprintf("%-8s = %s",  'sangel',   $t_heat->xy_motar->sangel_mo),
            sprintf("%-8s = %4s", 'output',   $t_heat->output             ),
            sprintf("%-8s = %4s", 'gshow',    $t_heat->gshow              ),
            sprintf("%-8s = %4s", 'resol',    $t_heat->cell_bnd->{resol}  ),
            sprintf("%-8s = %4s", 'width',    $t_heat->cell_bnd->{width}  ),
            sprintf("%-8s = %4s", 'material', $t_heat->material           ),
            sprintf("%-8s = %4s", 'electron', $t_heat->electron           ),
            "";  # End

        # T-Heat 6
        # > Mesh: xyz
        # > Axis: xy
        # > Heat energy distribution on xy plane, at z of molybdenum target
        # > *********************************************
        # > ***** To be converted to an MAPDL table *****
        #   ***** DO NOT USE ANGEL CMD LIKE 'cmmm'  *****
        # > *********************************************
        push @{$phits->sects->{t_heat_xy_motar_ansys}},
            $t_heat->Ctrls->switch =~ /off/i ?
                $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s", 'mesh',   $t_heat_mapdl->mesh_shape->{xyz}),
            sprintf("%-8s = %4s", 'x-type', $t_heat_mapdl->mesh_types->{x}  ),
            sprintf("%-8s = %4s", 'nx',     $t_heat_mapdl->mesh_sizes->{x}  ),
            sprintf("%-8s = %4s", 'xmin',   $t_shared->mesh_ranges->{xmin}  ),
            sprintf("%-8s = %4s", 'xmax',   $t_shared->mesh_ranges->{xmax}  ),
            sprintf("%-8s = %4s", 'y-type', $t_heat_mapdl->mesh_types->{y}  ),
            sprintf("%-8s = %4s", 'ny',     $t_heat_mapdl->mesh_sizes->{y}  ),
            sprintf("%-8s = %4s", 'ymin',   $t_shared->mesh_ranges->{ymin}  ),
            sprintf("%-8s = %4s", 'ymax',   $t_shared->mesh_ranges->{ymax}  ),
            sprintf("%-8s = %4s", 'z-type', $t_heat_mapdl->mesh_types->{z}  ),
            sprintf("%-8s = %4s", 'nz',     $t_heat_mapdl->mesh_sizes->{z}  ),
            sprintf(
                "%-8s = %10.5f",
                'zmin',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->beam_ent : $motar_rcc->beam_ent
            ),
            sprintf(
                "%-8s = %10.5f",
                'zmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    ($motar_trc->beam_ent + $motar_trc->height) :
                    ($motar_rcc->beam_ent + $motar_rcc->height)
            ),
            # Output settings
            sprintf(
                "%-8s = %4s",
                'axis',
                $t_heat_mapdl->xy_motar_mapdl->name
            ),
            sprintf(
                "%-8s = %s",
                'file',
                $t_heat_mapdl->xy_motar_mapdl->fname
            ),
            sprintf(
                "%-8s = %4s",
                'unit',
                $t_heat_mapdl->unit
            ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat_mapdl->factor->{val},
                eval { $t_heat_mapdl->factor->{cmt} } // ''
            ),
            sprintf(
                "%-8s = %s",
                'title',
                $t_heat_mapdl->xy_motar_mapdl->title
            ),
            sprintf(
                "%-8s = %4s",
                'output',
                $t_heat_mapdl->output
            ),
            sprintf(
                "%-8s = %4s",
                '2d-type',
                $t_heat_mapdl->two_dim_type
            ),
            sprintf(
                "%-8s = %4s",
                'material',
                $t_heat_mapdl->material
            ),
            sprintf(
                "%-8s = %4s",
                'electron',
                $t_heat_mapdl->electron
            ),
            "";  # End

        # T-Heat 7
        # > Mesh: r-z
        # > Axis: rz
        # > Heat energy distribution over the rz plane of
        #   a bremsstrahlung converter
        push @{$phits->sects->{t_heat_rz_bconv}},
            (
                $t_heat->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
            ) ? $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s",    'mesh',   $t_heat->mesh_shape->{rz}),
            sprintf("%-8s = %4s",    'r-type', $t_heat->mesh_types->{r} ),
            sprintf("%-8s = %4s",    'nr',     $t_heat->mesh_sizes->{r} ),
            sprintf("%-8s = %4s",    'rmin',   0                        ),
            sprintf("%-8s = %4s",    'rmax',   $bconv->radius           ),
            sprintf("%-8s = %4s",    'z-type', $t_heat->mesh_types->{z} ),
            sprintf("%-8s = %4s",    'nz',     $t_heat->mesh_sizes->{z} ),
            sprintf("%-8s = %10.5f", 'zmin',   $bconv->beam_ent         ),
            sprintf("%-8s = %10.5f", 'zmax',   $bconv->height + 1e-07   ),
            # Output settings
            sprintf("%-8s = %4s", 'axis', $t_heat->rz_bconv->name ),
            sprintf("%-8s = %s",  'file', $t_heat->rz_bconv->fname),
            sprintf("%-8s = %4s", 'unit', $t_heat->unit           ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat->factor->{val},
                eval { $t_heat->factor->{cmt} } // ''
            ),
            sprintf("%-8s = %s",  'title',    $t_heat->rz_bconv->title  ),
            sprintf("%-8s = %4s", 'epsout',   $t_heat->epsout           ),
            sprintf("%-8s = %4s", 'vtkout',   $t_heat->vtkout           ),
            sprintf("%-8s = %s",  'angel',    $t_heat->rz_bconv->angel  ),
            sprintf("%-8s = %s",  'sangel',   $t_heat->rz_bconv->sangel ),
            sprintf("%-8s = %4s", 'output',   $t_heat->output           ),
            sprintf("%-8s = %4s", 'gshow',    $t_heat->gshow            ),
            sprintf("%-8s = %4s", 'resol',    $t_heat->cell_bnd->{resol}),
            sprintf("%-8s = %4s", 'width',    $t_heat->cell_bnd->{width}),
            sprintf("%-8s = %4s", 'material', $t_heat->material         ),
            sprintf("%-8s = %4s", 'electron', $t_heat->electron         ),
            "";  # End

        # T-Heat 8
        # > Mesh: r-z
        # > Axis: rz
        # > 2d-type: 4
        # > Heat energy distribution over the rz plane of
        #   a bremsstrahlung converter, for explicit plotting
        push @{$phits->sects->{t_heat_rz_bconv_twodtype4}},
            (
                $t_heat->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
            ) ? $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s",    'mesh',   $t_heat->mesh_shape->{rz}),
            sprintf("%-8s = %4s",    'r-type', $t_heat->mesh_types->{r} ),
            sprintf("%-8s = %4s",    'nr',     $t_heat->mesh_sizes->{r} ),
            sprintf("%-8s = %4s",    'rmin',   0                        ),
            sprintf("%-8s = %4s",    'rmax',   $bconv->radius           ),
            sprintf("%-8s = %4s",    'z-type', $t_heat->mesh_types->{z} ),
            sprintf("%-8s = %4s",    'nz',     $t_heat->mesh_sizes->{z} ),
            sprintf("%-8s = %10.5f", 'zmin',   $bconv->beam_ent         ),
            sprintf("%-8s = %10.5f", 'zmax',   $bconv->height + 1e-07   ),
            # Output settings
            sprintf("%-8s = %4s", 'axis', $t_heat->rz_bconv->name           ),
            sprintf("%-8s = %s",  'file', $t_heat->rz_bconv_twodtype4->fname),
            sprintf("%-8s = %4s", 'unit', $t_heat->unit                     ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat->factor->{val},
                eval { $t_heat->factor->{cmt} } // ''
            ),
            sprintf("%-8s = %s",  'title',    $t_heat->rz_bconv->title  ),
            sprintf("%-8s = %4s", 'output',   $t_heat->output           ),
            sprintf(
                "%-8s = %4s",
                '2d-type',
                $t_heat_mapdl->two_dim_type
            ),
            sprintf("%-8s = %4s", 'material', $t_heat->material         ),
            sprintf("%-8s = %4s", 'electron', $t_heat->electron         ),
            "";  # End

        # T-Heat 9
        # > Mesh: r-z
        # > Axis: rz
        # > Heat energy distribution over the rz plane of
        #   a Mo target
        push @{$phits->sects->{t_heat_rz_motar}},
            $t_heat->Ctrls->switch =~ /off/i ?
                $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s",    'mesh',   $t_heat->mesh_shape->{rz}),
            sprintf("%-8s = %4s",    'r-type', $t_heat->mesh_types->{r} ),
            sprintf("%-8s = %4s",    'nr',     $t_heat->mesh_sizes->{r} ),
            sprintf(
                "%-8s = %4s",
                'rmin',
                0,
            ),
            sprintf(
                "%-8s = %4s",
                'rmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->top_radius : $motar_rcc->radius
            ),
            sprintf(
                "%-8s = %4s",
                'z-type',
                $t_heat->mesh_types->{z},
            ),
            sprintf(
                "%-8s = %4s",
                'nz',
                $t_heat->mesh_sizes->{z},
            ),
            sprintf(
                "%-8s = %10.5f",
                'zmin',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->beam_ent : $motar_rcc->beam_ent
            ),
            sprintf(
                "%-8s = %10.5f",
                'zmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    ($motar_trc->beam_ent + $motar_trc->height) :
                    ($motar_rcc->beam_ent + $motar_rcc->height)
            ),
            # Output settings
            sprintf("%-8s = %4s", 'axis', $t_heat->rz_motar->name ),
            sprintf("%-8s = %s",  'file', $t_heat->rz_motar->fname),
            sprintf("%-8s = %4s", 'unit', $t_heat->unit           ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat->factor->{val},
                eval { $t_heat->factor->{cmt} } // ''
            ),
            sprintf("%-8s = %s",  'title',    $t_heat->rz_motar->title  ),
            sprintf("%-8s = %4s", 'epsout',   $t_heat->epsout           ),
            sprintf("%-8s = %4s", 'vtkout',   $t_heat->vtkout           ),
            sprintf("%-8s = %s",  'angel',    $t_heat->rz_motar->angel  ),
            sprintf("%-8s = %s",  'sangel',   $t_heat->rz_motar->sangel ),
            sprintf("%-8s = %4s", 'output',   $t_heat->output           ),
            sprintf("%-8s = %4s", 'gshow',    $t_heat->gshow            ),
            sprintf("%-8s = %4s", 'resol',    $t_heat->cell_bnd->{resol}),
            sprintf("%-8s = %4s", 'width',    $t_heat->cell_bnd->{width}),
            sprintf("%-8s = %4s", 'material', $t_heat->material         ),
            sprintf("%-8s = %4s", 'electron', $t_heat->electron         ),
            "";  # End

        # T-Heat 10
        # > Mesh: r-z
        # > Axis: rz
        # > Heat energy distribution over the rz plane of
        #   a Mo target, for explicit plotting
        push @{$phits->sects->{t_heat_rz_motar_twodtype4}},
            $t_heat->Ctrls->switch =~ /off/i ?
                $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s",    'mesh',   $t_heat->mesh_shape->{rz}),
            sprintf("%-8s = %4s",    'r-type', $t_heat->mesh_types->{r} ),
            sprintf("%-8s = %4s",    'nr',     $t_heat->mesh_sizes->{r} ),
            sprintf(
                "%-8s = %4s",
                'rmin',
                0,
            ),
            sprintf(
                "%-8s = %4s",
                'rmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->top_radius : $motar_rcc->radius
            ),
            sprintf(
                "%-8s = %4s",
                'z-type',
                $t_heat->mesh_types->{z},
            ),
            sprintf(
                "%-8s = %4s",
                'nz',
                $t_heat->mesh_sizes->{z},
            ),
            sprintf(
                "%-8s = %10.5f",
                'zmin',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->beam_ent : $motar_rcc->beam_ent
            ),
            sprintf(
                "%-8s = %10.5f",
                'zmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    ($motar_trc->beam_ent + $motar_trc->height) :
                    ($motar_rcc->beam_ent + $motar_rcc->height)
            ),
            # Output settings
            sprintf("%-8s = %4s", 'axis', $t_heat->rz_motar->name           ),
            sprintf("%-8s = %s",  'file', $t_heat->rz_motar_twodtype4->fname),
            sprintf("%-8s = %4s", 'unit', $t_heat->unit                     ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat->factor->{val},
                eval { $t_heat->factor->{cmt} } // ''
            ),
            sprintf("%-8s = %s",  'title',    $t_heat->rz_motar->title  ),
            sprintf("%-8s = %4s", 'output',   $t_heat->output           ),
            sprintf(
                "%-8s = %4s",
                '2d-type',
                $t_heat_mapdl->two_dim_type
            ),
            sprintf("%-8s = %4s", 'material', $t_heat->material         ),
            sprintf("%-8s = %4s", 'electron', $t_heat->electron         ),
            "";  # End

        # T-Heat 11
        # > Mesh: reg
        # > Axis: reg
        # > Heat energy distribution in bremsstrahlung converter volume
        push @{$phits->sects->{t_heat_reg_bconv}},
            (
                $t_heat->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
            ) ? $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s", 'mesh', $t_heat->mesh_shape->{reg}   ),
            sprintf("%-8s = %4s", 'reg',  $bconv->cell_props->{cell_id}),
            # Output settings
            sprintf("%-8s = %4s", 'axis', $t_heat->reg_bconv->name     ),
            sprintf("%-8s = %s",  'file', $t_heat->reg_bconv->fname    ),
            sprintf("%-8s = %4s", 'unit', $t_heat->unit                ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat->factor->{val},
                eval { $t_heat->factor->{cmt} } // ''
            ),
            sprintf("%-8s = %s",  'title',    $t_heat->reg_bconv->title),
            sprintf("%-8s = %4s", 'output',   $t_heat->output          ),
            sprintf("%-8s = %4s", 'epsout',   $t_heat->epsout          ),
            sprintf("%-8s = %4s", 'material', $t_heat->material        ),
            sprintf("%-8s = %4s", 'electron', $t_heat->electron        ),
            "";  # End

        # T-Heat 12
        # > Mesh: reg
        # > Axis: reg
        # > Heat energy distribution in molybdenum target volume
        push @{$phits->sects->{t_heat_reg_motar}},
            $t_heat->Ctrls->switch =~ /off/i ?
                $t_heat->sect_begin." off" :
                $t_heat->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_heat->flag,     $t_heat->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-8s = %4s", 'mesh', $t_heat->mesh_shape->{reg}),
            sprintf(
                "%-8s = %4s",
                'reg',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->cell_props->{cell_id} :
                    $motar_rcc->cell_props->{cell_id}
            ),
            # Output settings
            sprintf("%-8s = %4s", 'axis', $t_heat->reg_motar->name ),
            sprintf("%-8s = %s",  'file', $t_heat->reg_motar->fname),
            sprintf("%-8s = %4s", 'unit', $t_heat->unit            ),
            sprintf(
                "%-8s = %4g%s",
                'factor',
                $t_heat->factor->{val},
                eval { $t_heat->factor->{cmt} } // ''
            ),
            sprintf("%-8s = %s",  'title',    $t_heat->reg_motar->title),
            sprintf("%-8s = %4s", 'output',   $t_heat->output          ),
            sprintf("%-8s = %4s", 'epsout',   $t_heat->epsout          ),
            sprintf("%-8s = %4s", 'material', $t_heat->material        ),
            sprintf("%-8s = %4s", 'electron', $t_heat->electron        ),
            "";  # End

        # T-Gshow 1
        # > Mesh: xyz
        # > Axis: xz
        # > Geometries on xz plane
        push @{$phits->sects->{t_gshow_xz}},
            $t_gshow->Ctrls->switch =~ /off/i ?
                $t_gshow->sect_begin." off" :
                $t_gshow->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_gshow->flag,    $t_gshow->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s", 'mesh',   $t_gshow->mesh_shape->{xyz}    ),
            sprintf("%-6s = %4s", 'x-type', $t_gshow->mesh_types->{x}      ),
            sprintf("%-6s = %4s", 'nx',     $t_gshow->mesh_sizes->{x}      ),
            sprintf("%-6s = %4s", 'xmin',   $t_shared->mesh_ranges->{xmin} ),
            sprintf("%-6s = %4s", 'xmax',   $t_shared->mesh_ranges->{xmax} ),
            sprintf("%-6s = %4s", 'y-type', $t_gshow->mesh_types->{y}      ),
            sprintf("%-6s = %4s", 'ny',     $t_gshow->mesh_sizes->{1}      ),
            sprintf("%-6s = %4s", 'ymin',   $t_shared->mesh_ranges->{ymin} ),
            sprintf("%-6s = %4s", 'ymax',   $t_shared->mesh_ranges->{ymax} ),
            sprintf("%-6s = %4s", 'z-type', $t_gshow->mesh_types->{z}      ),
            sprintf("%-6s = %4s", 'nz',     $t_gshow->mesh_sizes->{z}      ),
            sprintf("%-6s = %10.5f", 'zmin', $t_shared->mesh_ranges->{zmin}),
            sprintf("%-6s = %10.5f", 'zmax', $t_shared->mesh_ranges->{zmax}),
            # Output settings
            sprintf("%-6s = %4s", 'axis',   $t_gshow->xz->name         ),
            sprintf("%-6s = %s",  'file',   $t_gshow->xz->fname        ),
            sprintf("%-6s = %4s", 'output', $t_gshow->output           ),
            sprintf("%-6s = %4s", 'resol',  $t_gshow->cell_bnd->{resol}),
            sprintf("%-6s = %4s", 'width',  $t_gshow->cell_bnd->{width}),
            sprintf("%-6s = %s",  'title',  $t_gshow->xz->title        ),
            sprintf("%-6s = %4s", 'epsout', $t_gshow->epsout           ),
            sprintf("%-6s = %4s", 'vtkout', $t_gshow->vtkout           ),
            sprintf("%-6s = %s",  'angel',  $t_gshow->xz->angel        ),
            sprintf("%-6s = %s",  'sangel', $t_gshow->xz->sangel       ),
            "";  # End

        # T-Gshow 2
        # > Mesh: xyz
        # > Axis: yz
        # > Geometries on yz plane
        push @{$phits->sects->{t_gshow_yz}},
            $t_gshow->Ctrls->switch =~ /off/i ?
                $t_gshow->sect_begin." off" :
                $t_gshow->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_gshow->flag,    $t_gshow->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s", 'mesh',   $t_gshow->mesh_shape->{xyz}    ),
            sprintf("%-6s = %4s", 'x-type', $t_gshow->mesh_types->{x}      ),
            sprintf("%-6s = %4s", 'nx',     $t_gshow->mesh_sizes->{1}      ),
            sprintf("%-6s = %4s", 'xmin',   $t_shared->mesh_ranges->{xmin} ),
            sprintf("%-6s = %4s", 'xmax',   $t_shared->mesh_ranges->{xmax} ),
            sprintf("%-6s = %4s", 'y-type', $t_gshow->mesh_types->{y}      ),
            sprintf("%-6s = %4s", 'ny',     $t_gshow->mesh_sizes->{y}      ),
            sprintf("%-6s = %4s", 'ymin',   $t_shared->mesh_ranges->{ymin} ),
            sprintf("%-6s = %4s", 'ymax',   $t_shared->mesh_ranges->{ymax} ),
            sprintf("%-6s = %4s", 'z-type', $t_gshow->mesh_types->{z}      ),
            sprintf("%-6s = %4s", 'nz',     $t_gshow->mesh_sizes->{z}      ),
            sprintf("%-6s = %10.5f", 'zmin', $t_shared->mesh_ranges->{zmin}),
            sprintf("%-6s = %10.5f", 'zmax', $t_shared->mesh_ranges->{zmax}),
            # Output settings
            sprintf("%-6s = %4s", 'axis',   $t_gshow->yz->name         ),
            sprintf("%-6s = %s",  'file',   $t_gshow->yz->fname        ),
            sprintf("%-6s = %4s", 'output', $t_gshow->output           ),
            sprintf("%-6s = %4s", 'resol',  $t_gshow->cell_bnd->{resol}),
            sprintf("%-6s = %4s", 'width',  $t_gshow->cell_bnd->{width}),
            sprintf("%-6s = %s",  'title',  $t_gshow->yz->title        ),
            sprintf("%-6s = %4s", 'epsout', $t_gshow->epsout           ),
            sprintf("%-6s = %4s", 'vtkout', $t_gshow->vtkout           ),
            sprintf("%-6s = %s",  'angel',  $t_gshow->yz->angel        ),
            sprintf("%-6s = %s",  'sangel', $t_gshow->yz->sangel       ),
            "";  # End

        # T-Gshow 3
        # > Mesh: xyz
        # > Axis: yz
        # > Geometries on xy plane, at z of bremsstrahlung converter
        push @{$phits->sects->{t_gshow_xy_bconv}},
            (
                $t_gshow->Ctrls->switch =~ /off/i
                or $bconv->flag =~ /none/i
            ) ? $t_gshow->sect_begin." off" :
                $t_gshow->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_gshow->flag,    $t_gshow->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s",    'mesh',   $t_gshow->mesh_shape->{xyz}   ),
            sprintf("%-6s = %4s",    'x-type', $t_gshow->mesh_types->{x}     ),
            sprintf("%-6s = %4s",    'nx',     $t_gshow->mesh_sizes->{x}     ),
            sprintf("%-6s = %4s",    'xmin',   $t_shared->mesh_ranges->{xmin}),
            sprintf("%-6s = %4s",    'xmax',   $t_shared->mesh_ranges->{xmax}),
            sprintf("%-6s = %4s",    'y-type', $t_gshow->mesh_types->{y}     ),
            sprintf("%-6s = %4s",    'ny',     $t_gshow->mesh_sizes->{y}     ),
            sprintf("%-6s = %4s",    'ymin',   $t_shared->mesh_ranges->{ymin}),
            sprintf("%-6s = %4s",    'ymax',   $t_shared->mesh_ranges->{ymax}),
            sprintf("%-6s = %4s",    'z-type', $t_gshow->mesh_types->{z}     ),
            sprintf("%-6s = %4s",    'nz',     $t_gshow->mesh_sizes->{1}     ),
            sprintf("%-6s = %10.5f", 'zmin',   $bconv->beam_ent              ),
            sprintf("%-6s = %10.5f", 'zmax',   $bconv->height                ),
            # Output settings
            sprintf("%-6s = %4s", 'axis',   $t_gshow->xy_bconv->name   ),
            sprintf("%-6s = %s",  'file',   $t_gshow->xy_bconv->fname  ),
            sprintf("%-6s = %4s", 'output', $t_gshow->output           ),
            sprintf("%-6s = %4s", 'resol',  $t_gshow->cell_bnd->{resol}),
            sprintf("%-6s = %4s", 'width',  $t_gshow->cell_bnd->{width}),
            sprintf("%-6s = %s",  'title',  $t_gshow->xy_bconv->title  ),
            sprintf("%-6s = %4s", 'epsout', $t_gshow->epsout           ),
            sprintf("%-6s = %4s", 'vtkout', $t_gshow->vtkout           ),
            sprintf("%-6s = %s",  'angel',  $t_gshow->xy_bconv->angel  ),
            sprintf("%-6s = %s",  'sangel', $t_gshow->xy_bconv->sangel ),
            "";  # End

        # T-Gshow 4
        # > Mesh: xyz
        # > Axis: yz
        # > Geometries on xy plane, at z of molybdenum target
        push @{$phits->sects->{t_gshow_xy_motar}},
            $t_gshow->Ctrls->switch =~ /off/i ?
                $t_gshow->sect_begin." off" :
                $t_gshow->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_gshow->flag,    $t_gshow->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # Meshing
            sprintf("%-6s = %4s", 'mesh',   $t_gshow->mesh_shape->{xyz}   ),
            sprintf("%-6s = %4s", 'x-type', $t_gshow->mesh_types->{x}     ),
            sprintf("%-6s = %4s", 'nx',     $t_gshow->mesh_sizes->{x}     ),
            sprintf("%-6s = %4s", 'xmin',   $t_shared->mesh_ranges->{xmin}),
            sprintf("%-6s = %4s", 'xmax',   $t_shared->mesh_ranges->{xmax}),
            sprintf("%-6s = %4s", 'y-type', $t_gshow->mesh_types->{y}     ),
            sprintf("%-6s = %4s", 'ny',     $t_gshow->mesh_sizes->{y}     ),
            sprintf("%-6s = %4s", 'ymin',   $t_shared->mesh_ranges->{ymin}),
            sprintf("%-6s = %4s", 'ymax',   $t_shared->mesh_ranges->{ymax}),
            sprintf("%-6s = %4s", 'z-type', $t_gshow->mesh_types->{z}     ),
            sprintf("%-6s = %4s", 'nz',     $t_gshow->mesh_sizes->{1}     ),
            sprintf(
                "%-6s = %10.5f",
                'zmin',
                $tar_of_int->flag eq $motar_trc->flag ?
                    $motar_trc->beam_ent :
                    $motar_rcc->beam_ent
            ),
            sprintf(
                "%-6s = %10.5f",
                'zmax',
                $tar_of_int->flag eq $motar_trc->flag ?
                    ($motar_trc->beam_ent + $motar_trc->height) :
                    ($motar_rcc->beam_ent + $motar_rcc->height)
            ),
            # Output settings
            sprintf("%-6s = %4s", 'axis',   $t_gshow->xy_motar->name     ),
            sprintf("%-6s = %s",  'file',   $t_gshow->xy_motar->fname    ),
            sprintf("%-6s = %4s", 'output', $t_gshow->output             ),
            sprintf("%-6s = %4s", 'resol',  $t_gshow->cell_bnd->{resol}  ),
            sprintf("%-6s = %4s", 'width',  $t_gshow->cell_bnd->{width}  ),
            sprintf("%-6s = %s",  'title',  $t_gshow->xy_motar->title    ),
            sprintf("%-6s = %4s", 'epsout', $t_gshow->epsout             ),
            sprintf("%-6s = %4s", 'vtkout', $t_gshow->vtkout             ),
            sprintf("%-6s = %s",  'angel',  $t_gshow->xy_motar->angel_mo ),
            sprintf("%-6s = %s",  'sangel', $t_gshow->xy_motar->sangel_mo),
            "";  # End

        # T-3Dshow 1
        # > Left-to-right beam view
        push @{$phits->sects->{t_3dshow}},
            $t_3dshow->Ctrls->switch =~ /off/i ?
                $t_3dshow->sect_begin." off" :
                $t_3dshow->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_3dshow->flag,   $t_3dshow->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # View settings
            sprintf("%-8s = %4s", 'output',   $t_3dshow->output  ),
            sprintf("%-8s = %4s", 'material', $t_3dshow->material),
            sprintf("%-8s = %4s", 'x0', $t_3dshow->origin->{x} ),
            sprintf("%-8s = %4s", 'y0', $t_3dshow->origin->{y} ),
            sprintf("%-8s = %4s", 'z0', $t_3dshow->origin->{z1}),
            sprintf("%-8s = %4s", 'w-wdt', $t_3dshow->frame->{width}   ),
            sprintf("%-8s = %4s", 'w-hgt', $t_3dshow->frame->{height}  ),
            sprintf("%-8s = %4s", 'w-dst', $t_3dshow->frame->{distance}),
            sprintf("%-8s = %4s", 'w-mnw', $t_3dshow->frame->{wdt_num_meshes}),
            sprintf("%-8s = %4s", 'w-mnh', $t_3dshow->frame->{hgt_num_meshes}),
            sprintf("%-8s = %4s", 'w-ang', $t_3dshow->frame->{angle}         ),
            sprintf("%-8s = %4s", 'e-the', $t_3dshow->eye->{polar_angle1}    ),
            sprintf("%-8s = %4s", 'e-phi', $t_3dshow->eye->{azimuth_angle}   ),
            sprintf("%-8s = %4s", 'e-dst', $t_3dshow->eye->{distance}        ),
            sprintf("%-8s = %4s", 'l-the', $t_3dshow->light->{polar_angle1}  ),
            sprintf("%-8s = %4s", 'l-phi', $t_3dshow->light->{azimuth_angle} ),
            sprintf("%-8s = %4s", 'l-dst', $t_3dshow->light->{distance}      ),
            sprintf("%-8s = %4s", 'shadow', $t_3dshow->light->{shadow}),
            # Output settings
            sprintf("%-8s = %4s", 'heaven', $t_3dshow->axis_info->{to_sky}),
            sprintf(
                "%-8s = %4s",
                'axishow',
                $t_3dshow->axis_info->{crd_frame}
            ),
            sprintf("%-8s = %4s", 'resol',  $t_3dshow->cell_bnd->{resol}),
            sprintf("%-8s = %4s", 'width',  $t_3dshow->cell_bnd->{width}),
            sprintf("%-8s = %4s", 'line',   $t_3dshow->cell_bnd->{line} ),
            sprintf("%-8s = %s",  'title',  $t_3dshow->polar1->title    ),
            sprintf("%-8s = %4s", 'epsout', $t_3dshow->epsout           ),
            sprintf("%-8s = %s",  'angel',  $t_3dshow->polar1->angel    ),
            sprintf("%-8s = %s",  'sangel', $t_3dshow->polar1->sangel   ),
            sprintf("%-8s = %s",  'file',   $t_3dshow->polar1a->fname   ),
            "";  # End

        # T-3Dshow 2
        # > Left-to-right beam view
        # > Cutaway
        push @{$phits->sects->{t_3dshow}},
            $t_3dshow->Ctrls->switch =~ /off/i ?
                $t_3dshow->sect_begin." off" :
                $t_3dshow->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_3dshow->flag,   $t_3dshow->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # View settings
            sprintf("%-8s = %4s", 'output',   $t_3dshow->output          ),
            sprintf("%-8s = %4s", 'material', $t_3dshow->material_cutaway),
            sprintf("%-8s = %4s", 'x0',    $t_3dshow->origin->{x}            ),
            sprintf("%-8s = %4s", 'y0',    $t_3dshow->origin->{y}            ),
            sprintf("%-8s = %4s", 'z0',    $t_3dshow->origin->{z1}           ),
            sprintf("%-8s = %4s", 'w-wdt', $t_3dshow->frame->{width}         ),
            sprintf("%-8s = %4s", 'w-hgt', $t_3dshow->frame->{height}        ),
            sprintf("%-8s = %4s", 'w-dst', $t_3dshow->frame->{distance}      ),
            sprintf("%-8s = %4s", 'w-mnw', $t_3dshow->frame->{wdt_num_meshes}),
            sprintf("%-8s = %4s", 'w-mnh', $t_3dshow->frame->{hgt_num_meshes}),
            sprintf("%-8s = %4s", 'w-ang', $t_3dshow->frame->{angle}         ),
            sprintf("%-8s = %4s", 'e-the', $t_3dshow->eye->{polar_angle1}    ),
            sprintf("%-8s = %4s", 'e-phi', $t_3dshow->eye->{azimuth_angle}   ),
            sprintf("%-8s = %4s", 'e-dst', $t_3dshow->eye->{distance}        ),
            sprintf("%-8s = %4s", 'l-the', $t_3dshow->light->{polar_angle1}  ),
            sprintf("%-8s = %4s", 'l-phi', $t_3dshow->light->{azimuth_angle} ),
            sprintf("%-8s = %4s", 'l-dst', $t_3dshow->light->{distance}      ),
            sprintf("%-8s = %4s", 'shadow', $t_3dshow->light->{shadow}),
            # Output settings
            sprintf("%-8s = %4s", 'heaven', $t_3dshow->axis_info->{to_sky}),
            sprintf(
                "%-8s = %4s",
                'axishow',
                $t_3dshow->axis_info->{crd_frame}
            ),
            sprintf("%-8s = %4s", 'resol',  $t_3dshow->cell_bnd->{resol}),
            sprintf("%-8s = %4s", 'width',  $t_3dshow->cell_bnd->{width}),
            sprintf("%-8s = %4s", 'line',   $t_3dshow->cell_bnd->{line} ),
            sprintf("%-8s = %s",  'title',  $t_3dshow->polar1->title    ),
            sprintf("%-8s = %4s", 'epsout', $t_3dshow->epsout           ),
            sprintf("%-8s = %s",  'angel',  $t_3dshow->polar1->angel    ),
            sprintf("%-8s = %s",  'sangel', $t_3dshow->polar1->sangel   ),
            sprintf("%-8s = %s",  'file',   $t_3dshow->polar1b->fname   ),
            "";  # End

        # T-3Dshow 3
        # > Right-to-left beam view
        push @{$phits->sects->{t_3dshow}},
            $t_3dshow->Ctrls->switch =~ /off/i ?
                $t_3dshow->sect_begin." off" :
                $t_3dshow->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_3dshow->flag,   $t_3dshow->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # View settings
            sprintf("%-8s = %4s", 'output',   $t_3dshow->output  ),
            sprintf("%-8s = %4s", 'material', $t_3dshow->material),
            sprintf("%-8s = %4s", 'x0',    $t_3dshow->origin->{x}            ),
            sprintf("%-8s = %4s", 'y0',    $t_3dshow->origin->{y}            ),
            sprintf("%-8s = %4s", 'z0',    $t_3dshow->origin->{z2}           ),
            sprintf("%-8s = %4s", 'w-wdt', $t_3dshow->frame->{width}         ),
            sprintf("%-8s = %4s", 'w-hgt', $t_3dshow->frame->{height}        ),
            sprintf("%-8s = %4s", 'w-dst', $t_3dshow->frame->{distance}      ),
            sprintf("%-8s = %4s", 'w-mnw', $t_3dshow->frame->{wdt_num_meshes}),
            sprintf("%-8s = %4s", 'w-mnh', $t_3dshow->frame->{hgt_num_meshes}),
            sprintf("%-8s = %4s", 'w-ang', $t_3dshow->frame->{angle}         ),
            sprintf("%-8s = %4s", 'e-the', $t_3dshow->eye->{polar_angle2}    ),
            sprintf("%-8s = %4s", 'e-phi', $t_3dshow->eye->{azimuth_angle}   ),
            sprintf("%-8s = %4s", 'e-dst', $t_3dshow->eye->{distance}        ),
            sprintf("%-8s = %4s", 'l-the', $t_3dshow->light->{polar_angle2}  ),
            sprintf("%-8s = %4s", 'l-phi', $t_3dshow->light->{azimuth_angle} ),
            sprintf("%-8s = %4s", 'l-dst', $t_3dshow->light->{distance}      ),
            sprintf("%-8s = %4s", 'shadow', $t_3dshow->light->{shadow}),
            # Output settings
            sprintf("%-8s = %4s", 'heaven', $t_3dshow->axis_info->{to_sky}),
            sprintf(
                "%-8s = %4s",
                'axishow',
                $t_3dshow->axis_info->{crd_frame}
            ),
            sprintf("%-8s = %4s", 'resol',  $t_3dshow->cell_bnd->{resol}),
            sprintf("%-8s = %4s", 'width',  $t_3dshow->cell_bnd->{width}),
            sprintf("%-8s = %4s", 'line',   $t_3dshow->cell_bnd->{line} ),
            sprintf("%-8s = %s",  'title',  $t_3dshow->polar2->title    ),
            sprintf("%-8s = %4s", 'epsout', $t_3dshow->epsout           ),
            sprintf("%-8s = %s",  'angel',  $t_3dshow->polar2->angel    ),
            sprintf("%-8s = %s",  'sangel', $t_3dshow->polar2->sangel   ),
            sprintf("%-8s = %s",  'file',   $t_3dshow->polar2a->fname   ),
            "";  # End

        # T-3Dshow 4
        # > Right-to-left beam view
        # > Cutaway
        push @{$phits->sects->{t_3dshow}},
            $t_3dshow->Ctrls->switch =~ /off/i ?
                $t_3dshow->sect_begin." off" :
                $t_3dshow->sect_begin.sprintf(
                    "  %s ".
                    "%s No. %s, ".
                    "%s No. %s, ".
                    "%s No. %s",
                    $phits->Cmt->symb,
                    $t_3dshow->flag,   $t_3dshow->inc_t_counter(),
                    $t_subtotal->flag, $t_subtotal->inc_t_counter(),
                    $t_total->flag,    $t_total->inc_t_counter(),
                ),
            # View settings
            sprintf("%-8s = %4s", 'output',   $t_3dshow->output          ),
            sprintf("%-8s = %4s", 'material', $t_3dshow->material_cutaway),
            sprintf("%-8s = %4s", 'x0',    $t_3dshow->origin->{x}            ),
            sprintf("%-8s = %4s", 'y0',    $t_3dshow->origin->{y}            ),
            sprintf("%-8s = %4s", 'z0',    $t_3dshow->origin->{z2}           ),
            sprintf("%-8s = %4s", 'w-wdt', $t_3dshow->frame->{width}         ),
            sprintf("%-8s = %4s", 'w-hgt', $t_3dshow->frame->{height}        ),
            sprintf("%-8s = %4s", 'w-dst', $t_3dshow->frame->{distance}      ),
            sprintf("%-8s = %4s", 'w-mnw', $t_3dshow->frame->{wdt_num_meshes}),
            sprintf("%-8s = %4s", 'w-mnh', $t_3dshow->frame->{hgt_num_meshes}),
            sprintf("%-8s = %4s", 'w-ang', $t_3dshow->frame->{angle}         ),
            sprintf("%-8s = %4s", 'e-the', $t_3dshow->eye->{polar_angle2}    ),
            sprintf("%-8s = %4s", 'e-phi', $t_3dshow->eye->{azimuth_angle}   ),
            sprintf("%-8s = %4s", 'e-dst', $t_3dshow->eye->{distance}        ),
            sprintf("%-8s = %4s", 'l-the', $t_3dshow->light->{polar_angle2}  ),
            sprintf("%-8s = %4s", 'l-phi', $t_3dshow->light->{azimuth_angle} ),
            sprintf("%-8s = %4s", 'l-dst', $t_3dshow->light->{distance}      ),
            sprintf("%-8s = %4s", 'shadow', $t_3dshow->light->{shadow}),
            # Output settings
            sprintf("%-8s = %4s", 'heaven', $t_3dshow->axis_info->{to_sky}),
            sprintf(
                "%-8s = %4s",
                'axishow',
                $t_3dshow->axis_info->{crd_frame}
            ),
            sprintf("%-8s = %4s", 'resol',  $t_3dshow->cell_bnd->{resol}),
            sprintf("%-8s = %4s", 'width',  $t_3dshow->cell_bnd->{width}),
            sprintf("%-8s = %4s", 'line',   $t_3dshow->cell_bnd->{line} ),
            sprintf("%-8s = %s",  'title',  $t_3dshow->polar2->title    ),
            sprintf("%-8s = %4s", 'epsout', $t_3dshow->epsout           ),
            sprintf("%-8s = %s",  'angel',  $t_3dshow->polar2->angel    ),
            sprintf("%-8s = %s",  'sangel', $t_3dshow->polar2->sangel   ),
            sprintf("%-8s = %s",  'file',   $t_3dshow->polar2b->fname   ),
            "";  # End

        # End section
        push @{$phits->sects->{end}},
            "[End]",
            "";

        # Note (optional)
        push @{$phits->sects->{note}},
            "",
            "Note on shared-memory parallel computing",
            "",
            "To use shared-memory parallel computing,",
            "add the following environment variable:",
            "OMP_NUM_THREADS = n",
            "where n is the number of physical cores,",
            "NOT the number of threads that can be simultaneously processed.",
            "This is because if OMP_NUM_THREADS is set to be larger than",
            "the number of physical cores, competition takes place",
            "among the threads that involve file writing, which will in turn",
            "unnecessarily increase the CPU time.",
            "For an Intel Core i7-2600 Processor, for example,",
            "which provides 8 threads from 4 cores using its hyper-threading,",
            "the maximum OMP_NUM_THREADS should be 4, not 8.",
            "More detailed explanations are found in:",
            "PHITS v3.02 User's Manual (Jp), p. 295",
            "PHITS v3.02 User's Manual (En), p. 256",
            '';
        $_ = $phits->Cmt->symb.($_ ? " " : "").$_
            for @{$phits->sects->{note}};
        push @{$phits->sects->{note}},
            "";  # End

        #
        # Write to the PHITS input file.
        #
        my @_inp_dmp_sects = qw(
            omp
            abbr
            title
            parameters
            source
            material
            mat_name_color
            surface
            cell
            volume
            t_cross_motar_ent_dump
            end
            note
        );
        my @_inp_sects = qw(
            omp
            abbr
            title
            parameters
            source
            material
            mat_name_color
            surface
            cell
            volume
            t_track_xz
            t_track_yz
            t_track_xy_bconv
            t_track_xy_motar
            t_track_nrg_bconv
            t_track_nrg_bconv_low_emax
            t_track_nrg_motar
            t_track_nrg_motar_low_emax
            t_track_nrg_flux_mnt_up
            t_track_nrg_flux_mnt_down
            t_cross_intact
            t_cross_intact_low_emax
            t_cross_bconv_ent
            t_cross_bconv_ent_low_emax
            t_cross_bconv_exit
            t_cross_bconv_exit_low_emax
            t_cross_motar_ent
            t_cross_motar_ent_low_emax
            t_cross_motar_exit
            t_cross_motar_exit_low_emax
            t_heat_xz
            t_heat_yz
            t_heat_xy_bconv
            t_heat_xy_bconv_ansys
            t_heat_xy_motar
            t_heat_xy_motar_ansys
            t_heat_rz_bconv
            t_heat_rz_bconv_twodtype4
            t_heat_rz_motar
            t_heat_rz_motar_twodtype4
            t_heat_reg_bconv
            t_heat_reg_motar
            t_gshow_xz
            t_gshow_yz
            t_gshow_xy_bconv
            t_gshow_xy_motar
            t_3dshow
            end
            note
        );
        # Exclude those tallies to be turned off.
        my @the_inp_sects;
        foreach my $t (@_inp_sects) {
            # Toggled off tallies
            next if $t_track->Ctrls->switch  =~ /off/i and $t =~ /track/i;
            next if $t_cross->Ctrls->switch  =~ /off/i and $t =~ /cross/i;
            next if $t_heat->Ctrls->switch   =~ /off/i and $t =~ /heat/i;
            next if $t_gshow->Ctrls->switch  =~ /off/i and $t =~ /gshow/i;
            next if $t_3dshow->Ctrls->switch =~ /off/i and $t =~ /3dshow/i;

            # To be suppressed depending on simulation parameters
            next if $bconv->flag =~ /none/i     and $t =~ /bconv/i;
            next if $flux_mnt_up->height   <= 0 and $t =~ /flux_mnt_up/i;
            next if $flux_mnt_down->height <= 0 and $t =~ /flux_mnt_down/i;

            # Low emax
            next if (
                not $t_track->is_neut_of_int
                and $t =~ /t_track.*low_emax/i
            );
            next if (
                not $t_cross->is_neut_of_int
                and $t =~ /t_cross.*low_emax/i
            );

            # None of the above apply
            push @the_inp_sects, $t;
        }

        # Input file generating a dump file
        if ($phits->source->mode =~ /du?mp/i) {
            open my $phi_inp_dmp_fh,
                '>:encoding(UTF-8)',
                $phits->FileIO->inp_dmp;
            select($phi_inp_dmp_fh);

            map { say for @{$phits->sects->{$_}} } @_inp_dmp_sects;
            print $phits->Data->eof;

            select(STDOUT);
            close $phi_inp_dmp_fh;

            # Notify the file generation.
            say "";
            say $phits->Cmt->borders->{'='};
            printf(
                "%s [%s] generating a dump-source-generating PHITS input...\n",
                $phits->Cmt->symb, (caller(0))[3]
            );
            say $phits->Cmt->borders->{'='};
            printf("[%s] generated.\n", $phits->FileIO->inp_dmp);
        }

        # Input file performing the simulation
        if ($phits->Ctrls->switch =~ /on/i) {
            # Use 'source_dump' for dump mode.
            if ($phits->source->mode =~ /du?mp/i) {
                s/source/source_dump/ for @the_inp_sects;
            }

            open my $phi_inp_fh, '>:encoding(UTF-8)', $phits->FileIO->inp;
            select($phi_inp_fh);

            map { say for @{$phits->sects->{$_}} } @the_inp_sects;
            print $phits->Data->eof;

            select(STDOUT);
            close $phi_inp_fh;

            # Notify the file generation.
            say "";
            say $phits->Cmt->borders->{'='};
            printf(
                "%s [%s] generating a simulation-running PHITS input...\n",
                $phits->Cmt->symb, (caller(0))[3]
            );
            say $phits->Cmt->borders->{'='};
            printf("[%s] generated.\n", $phits->FileIO->inp);
        }

        #
        # MAPDL macro file writing
        #

        # Initialization
        $mapdl->clear_sects();

        # List of abbreviations used
        push @{$mapdl->sects->{abbr}},
            $mapdl->Cmt->borders->{'='},
            sprintf("%s List of abbreviations used", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'='},
            sprintf(
                "%s %-7s => %s",
                $mapdl->Cmt->symb,
                $phits->Cmt->abbrs->{varying}[0],
                $phits->Cmt->abbrs->{varying}[1]
            ),
            sprintf(
                "%s %-7s => %s",
                $mapdl->Cmt->symb,
                $phits->Cmt->abbrs->{fixed}[0],
                $phits->Cmt->abbrs->{fixed}[1]
            ),
            sprintf(
                "%s %-7s => %s",
                $mapdl->Cmt->symb,
                $phits->Cmt->abbrs->{bottom}[0],
                $phits->Cmt->abbrs->{bottom}[1]
            ),
            sprintf(
                "%s %-7s => %s",
                $mapdl->Cmt->symb,
                $phits->Cmt->abbrs->{radius}[0],
                $phits->Cmt->abbrs->{radius}[1]
            ),
            sprintf(
                "%s %-7s => %s",
                $mapdl->Cmt->symb,
                $phits->Cmt->abbrs->{height}[0],
                $phits->Cmt->abbrs->{height}[1]
            ),
            $mapdl->Cmt->borders->{'='},
            "\n";  # End

        # Set entity indices.
        $mapdl->entities->set_area(
            # e.g. $mapdl->entities->area->{gconv}[0]
            #      $mapdl->entities->area->{gconv}[1]
            gconv => [1..4],
            motar => [5..8],
        );
        $mapdl->entities->set_vol(
            gconv => [
                1,
            ],
            motar => [
                2,
            ],
        );
        $mapdl->entities->set_elem(
            gconv => [
                1,
            ],
            motar => [
                1,
            ],
        );
        $mapdl->entities->set_mat(
            gconv => [
                1,
            ],
            motar => [
                2,
            ],
        );

        # Parameters
        # Caution: A parameter name must be no more than 32 chars.
        $mapdl->set_params(
            tab_bname => {
                gconv => [
                    'tab_bname_'.$bconv->cell_mat,
                    $t_heat->xy_bconv_mapdl->bname
                ],
                motar => [
                    'tab_bname_'.$motar->cell_mat,
                    $t_heat->xy_motar_mapdl->bname
                ],
            },
            tab_x_size => ['tab_x_size', $t_heat_mapdl->mesh_sizes->{x}],
            tab_y_size => ['tab_y_size', $t_heat_mapdl->mesh_sizes->{y}],
            tab_z_size => ['tab_z_size', $t_heat_mapdl->mesh_sizes->{z}],
            heat_transfer_coeff => {
                gconv => [
                    'heat_transfer_coeff_'.$bconv->cell_mat,
                    1e+04  # !! <= Must be corrected to a calculated value !!
                ],
                motar => [
                    'heat_transfer_coeff_'.$motar->cell_mat,
                    1e+04  # !! <= Must be corrected to a calculated value !!
                ],
            },
            bulk_temperature => {
                gconv => ['bulk_temperature_'.$bconv->cell_mat, 25],
                motar => ['bulk_temperature_'.$motar->cell_mat, 25],
            },
        );

        # Shared settings
        my $_conv = $tar_of_int->flag eq $bconv->flag ? "%-21s" : "%-22s";
        push @{$mapdl->sects->{parameters}},
            $mapdl->Cmt->borders->{'='},
            sprintf(
                "%s Parameters (Must be no more than 32 chars)",
                $mapdl->Cmt->symb
            ),
            $mapdl->Cmt->borders->{'='},
            sprintf(
                "$_conv='%s'",
                $mapdl->params->{tab_ext}[0],  # Parameter name
                $mapdl->params->{tab_ext}[1]   # Parameter value
            ),
            sprintf(
                "$_conv='%s'",
                $mapdl->params->{eps_ext}[0],
                $mapdl->params->{eps_ext}[1]
            ),
            sprintf(
                "$_conv=%s",
                $mapdl->params->{tab_x_size}[0],
                $mapdl->params->{tab_x_size}[1]
            ),
            sprintf(
                "$_conv=%s",
                $mapdl->params->{tab_y_size}[0],
                $mapdl->params->{tab_y_size}[1]
            ),
            sprintf(
                "$_conv=%s",
                $mapdl->params->{tab_z_size}[0],
                $mapdl->params->{tab_z_size}[1]
            ),
            $mapdl->materials->gconv->{begin},
            sprintf(
                "$_conv='%s'",
                $mapdl->params->{tab_bname}{gconv}[0],
                $mapdl->params->{tab_bname}{gconv}[1]
            ),
            sprintf(
                "$_conv=%s",
                $mapdl->params->{heat_transfer_coeff}{gconv}[0],
                $mapdl->params->{heat_transfer_coeff}{gconv}[1]
            ),
            sprintf(
                "$_conv=%s",
                $mapdl->params->{bulk_temperature}{gconv}[0],
                $mapdl->params->{bulk_temperature}{gconv}[1]
            );

            # Mo-specific settings
            if ($tar_of_int->flag ne $bconv->flag) {
                push @{$mapdl->sects->{parameters}},
                    $mapdl->materials->motar->{begin},
                    sprintf(
                        "$_conv='%s'",
                        $mapdl->params->{tab_bname}{motar}[0],
                        $mapdl->params->{tab_bname}{motar}[1]
                    ),
                    sprintf(
                        "$_conv=%s",
                        $mapdl->params->{heat_transfer_coeff}{motar}[0],
                        $mapdl->params->{heat_transfer_coeff}{motar}[1]
                    ),
                    sprintf(
                        "$_conv=%s",
                        $mapdl->params->{bulk_temperature}{motar}[0],
                        $mapdl->params->{bulk_temperature}{motar}[1]
                    );
            }
            push @{$mapdl->sects->{parameters}},
                "\n";  # End

        # Title section:
        # > Defined after the parameter section as the setter method
        #   $mapdl->commands->set_title uses some values
        #   defined in the parameter section.
        # > Written, however, before the parameter section
        #   in the macro file.
        $mapdl->commands->set_title(
            title => '%'.(
                $tar_of_int->flag eq $bconv->flag ?
                    $mapdl->params->{tab_bname}{gconv}[0] :
                    $mapdl->params->{tab_bname}{motar}[0]
            ).'%',
        );
        push @{$mapdl->sects->{title}},
            # phitar front matter
            show_front_matter(
                $prog_info_href,
                'prog',
                'auth',
                'timestamp',
                'no_trailing_blkline',
                'no_newline',
                'copy',
                $mapdl->Cmt->symb,
            ),
            # MAPDL problem title
            sprintf(
                "%s,%s",
                $mapdl->commands->title->{cmd},
                $mapdl->commands->title->{title}
            ),
            "\n";  # End

        # [1/3] Preprocessor
        # Begin: Preprocessor
        push @{$mapdl->sects->{preproc_begin}},
            $mapdl->Cmt->borders->{'#'},
            sprintf("%s [1/3] Preprocessor", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'#'},
            $mapdl->processors->pre->{begin},
            "";  # End

        # Primitives (Units in MKS, Kelvin and degree)
        # Bremsstrahlung converter
        $mapdl->primitives->set_cylinder(
            r1 => $bconv->radius   * 1e-02,  #            Inner radius
            r2 => '',                        # "Optional" outer radius
            z1 => $bconv->beam_ent * 1e-02,  # Starting z coordinate
            z2 => $bconv->height   * 1e-02,  # Ending   z coordinate
        );
        push @{$mapdl->sects->{primitives}},
            $mapdl->Cmt->borders->{'='},
            sprintf("%s (1/3) Primitives", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'='},
            $mapdl->materials->gconv->{begin},
            sprintf(
                "%s,%s,%s,%s,%s,%s,%s",
                $mapdl->primitives->cylinder->{cmd},     # Predefined
                $mapdl->primitives->cylinder->{r1},
                $mapdl->primitives->cylinder->{r2},
                $mapdl->primitives->cylinder->{z1},
                $mapdl->primitives->cylinder->{z2},
                $mapdl->primitives->cylinder->{theta1},  # Predefined
                $mapdl->primitives->cylinder->{theta2}   # Predefined
            );
            # Molybdenum target, RCC
            if ($tar_of_int->flag eq $motar_rcc->flag) {
                $mapdl->primitives->set_cylinder(
                    r1 => $motar_rcc->radius   * 1e-02,
                    r2 => '',
                    z1 => $motar_rcc->beam_ent * 1e-02,
                    z2 => ($motar_rcc->beam_ent + $motar_rcc->height) * 1e-02,
                );
                push @{$mapdl->sects->{primitives}},
                    $mapdl->materials->motar->{begin},
                    sprintf(
                        "%s,%s,%s,%s,%s,%s,%s",
                        $mapdl->primitives->cylinder->{cmd},
                        $mapdl->primitives->cylinder->{r1},
                        $mapdl->primitives->cylinder->{r2},
                        $mapdl->primitives->cylinder->{z1},
                        $mapdl->primitives->cylinder->{z2},
                        $mapdl->primitives->cylinder->{theta1},
                        $mapdl->primitives->cylinder->{theta2}
                    );
            }
            # Molybdenum target, TRC
            if ($tar_of_int->flag eq $motar_trc->flag) {
                $mapdl->primitives->set_cone(
                    r1 => $motar_trc->bot_radius * 1e-02,  # Bottom radius
                    r2 => $motar_trc->top_radius * 1e-02,  # Top    radius
                    z1 => $motar_trc->beam_ent   * 1e-02,
                    z2 => ($motar_trc->beam_ent + $motar_trc->height) * 1e-02,
                );
                push @{$mapdl->sects->{primitives}},
                    $mapdl->materials->motar->{begin},
                    sprintf(
                        "%s,%s,%s,%s,%s,%s,%s",
                        $mapdl->primitives->cone->{cmd},
                        $mapdl->primitives->cone->{r1},
                        $mapdl->primitives->cone->{r2},
                        $mapdl->primitives->cone->{z1},
                        $mapdl->primitives->cone->{z2},
                        $mapdl->primitives->cone->{theta1},
                        $mapdl->primitives->cone->{theta2}
                    );
            }
            push @{$mapdl->sects->{primitives}},
            "";  # End

        # Material properties
        # Bremsstrahlung converter
        $mapdl->materials->set_mptemp(
            sloc => 1,
            t1   => 0,
            # t2, ..., t6
        );
        $mapdl->materials->set_mpdata(
            mat  => $mapdl->entities->mat->{gconv}[0],
            sloc => '',
            c1   => $bconv->cell_props->{thermal_cond} ?
                $bconv->cell_props->{thermal_cond} : '',
            # c2, ..., c6
        );
        push @{$mapdl->sects->{mat_props}},
            $mapdl->Cmt->borders->{'='},
            sprintf("%s (2/3) Material properties", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'='},
            $mapdl->materials->gconv->{begin},
            sprintf(
                "%s,,,,,,,,",
                $mapdl->materials->mptemp->{cmd}
            ),
            sprintf(
                "%s,%s,%s",
                $mapdl->materials->mptemp->{cmd},
                $mapdl->materials->mptemp->{sloc},
                $mapdl->materials->mptemp->{t1}
            ),
            sprintf(
                "%s,%s,%s,%s,%s",
                $mapdl->materials->mpdata->{cmd},
                $mapdl->materials->mpdata->{lab},
                $mapdl->materials->mpdata->{mat},
                $mapdl->materials->mpdata->{sloc},
                $mapdl->materials->mpdata->{c1}
            );
            # Molybdenum target, RCC "or" TRC
            if ($tar_of_int->flag ne $bconv->flag) {
                $mapdl->materials->set_mptemp(
                    sloc => 1,
                    t1   => 0,
                    # t2, ..., t6
                );
                $mapdl->materials->set_mpdata(
                    mat  => $mapdl->entities->mat->{motar}[0],
                    sloc => '',
                    # $motar_rcc and $motar_trc have the same thermal_cond's
                    c1   => $motar_rcc->cell_props->{thermal_cond} ?
                        $motar_rcc->cell_props->{thermal_cond} : '',
                    # c2, ..., c6
                );
                push @{$mapdl->sects->{mat_props}},
                    $mapdl->materials->motar->{begin},
                    sprintf(
                        "%s,,,,,,,,",
                        $mapdl->materials->mptemp->{cmd}
                    ),
                    sprintf(
                        "%s,%s,%s",
                        $mapdl->materials->mptemp->{cmd},
                        $mapdl->materials->mptemp->{sloc},
                        $mapdl->materials->mptemp->{t1}
                    ),
                    sprintf(
                        "%s,%s,%s,%s,%s",
                        $mapdl->materials->mpdata->{cmd},
                        $mapdl->materials->mpdata->{lab},
                        $mapdl->materials->mpdata->{mat},
                        $mapdl->materials->mpdata->{sloc},
                        $mapdl->materials->mpdata->{c1}
                    );
            }
            push @{$mapdl->sects->{mat_props}},
            "";  # End

        # Meshing
        $mapdl->meshing->set_et(
            itype => 1,
            ename => 'solid87',
            # kop1, kop2, ..., kop6
        );
        $mapdl->meshing->set_smrtsize(
            sizlvl => 1,
            # And many other complex arguments; see the ANSYS class.
        );
        $mapdl->meshing->set_mshape(
            key       => 1,
            dimension => '3d',
        );
        $mapdl->meshing->set_mshkey(
            key => 0,
        );
        push @{$mapdl->sects->{meshing}},
            $mapdl->Cmt->borders->{'='},
            sprintf("%s (3/3) Meshing", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'='},
            sprintf(
                "%s,%s,%s",
                $mapdl->meshing->et->{cmd},
                $mapdl->meshing->et->{itype},
                $mapdl->meshing->et->{ename}
            ),
            sprintf(
                "%s,%s",
                $mapdl->meshing->smrtsize->{cmd},
                $mapdl->meshing->smrtsize->{sizlvl}
            ),
            sprintf(
                "%s,%s,%s",
                $mapdl->meshing->mshape->{cmd},
                $mapdl->meshing->mshape->{key},
                $mapdl->meshing->mshape->{dimension}
            ),
            sprintf(
                "%s,%s",
                $mapdl->meshing->mshkey->{cmd},
                $mapdl->meshing->mshkey->{key}
            );
            # Bremsstrahlung converter
            $mapdl->meshing->set_attr_pointers(
                type   => ['type',   $mapdl->entities->elem->{gconv}[0]],
                mat    => ['mat',    $mapdl->entities->mat->{gconv}[0] ],
                real   => ['real',   1                                 ],
                esys   => ['esys',   0                                 ],
                secnum => ['secnum', 1                                 ],
            );
            $mapdl->meshing->set_vmesh(
                nv1  => $mapdl->entities->vol->{gconv}[0],
                nv2  => '',
                ninc => '',
            );
            push @{$mapdl->sects->{meshing}},
                $mapdl->materials->gconv->{begin},
                sprintf(
                    "%s,%s\n".
                    "%s,%s\n".
                    "%s,%s\n".
                    "%s,%s\n".
                    "%s,%s",
                    $mapdl->meshing->attr_pointers->{type}[0],
                    $mapdl->meshing->attr_pointers->{type}[1],
                    $mapdl->meshing->attr_pointers->{mat}[0],
                    $mapdl->meshing->attr_pointers->{mat}[1],
                    $mapdl->meshing->attr_pointers->{real}[0],
                    $mapdl->meshing->attr_pointers->{real}[1],
                    $mapdl->meshing->attr_pointers->{esys}[0],
                    $mapdl->meshing->attr_pointers->{esys}[1],
                    $mapdl->meshing->attr_pointers->{secnum}[0],
                    $mapdl->meshing->attr_pointers->{secnum}[1]
                ),
                sprintf(
                    "%s,%s,%s,%s",
                    $mapdl->meshing->vmesh->{cmd},
                    $mapdl->meshing->vmesh->{nv1},
                    $mapdl->meshing->vmesh->{nv2},
                    $mapdl->meshing->vmesh->{ninc}
                );
            # Molybdenum target, RCC "or" TRC
            if ($tar_of_int->flag ne $bconv->flag) {
                $mapdl->meshing->set_attr_pointers(
                    type   => [ 'type',   $mapdl->entities->elem->{motar}[0]],
                    mat    => [ 'mat',    $mapdl->entities->mat->{motar}[0] ],
                    real   => [ 'real',   1                                 ],
                    esys   => [ 'esys',   0                                 ],
                    secnum => [ 'secnum', 1                                 ],
                );
                $mapdl->meshing->set_vmesh(
                    nv1  => $mapdl->entities->vol->{motar}[0],
                    nv2  => '',
                    ninc => '',
                );
                push @{$mapdl->sects->{meshing}},
                    $mapdl->materials->motar->{begin},
                    sprintf(
                        "%s,%s\n".
                        "%s,%s\n".
                        "%s,%s\n".
                        "%s,%s\n".
                        "%s,%s",
                        $mapdl->meshing->attr_pointers->{type}[0],
                        $mapdl->meshing->attr_pointers->{type}[1],
                        $mapdl->meshing->attr_pointers->{mat}[0],
                        $mapdl->meshing->attr_pointers->{mat}[1],
                        $mapdl->meshing->attr_pointers->{real}[0],
                        $mapdl->meshing->attr_pointers->{real}[1],
                        $mapdl->meshing->attr_pointers->{esys}[0],
                        $mapdl->meshing->attr_pointers->{esys}[1],
                        $mapdl->meshing->attr_pointers->{secnum}[0],
                        $mapdl->meshing->attr_pointers->{secnum}[1]
                    ),
                    sprintf(
                        "%s,%s,%s,%s",
                        $mapdl->meshing->vmesh->{cmd},
                        $mapdl->meshing->vmesh->{nv1},
                        $mapdl->meshing->vmesh->{nv2},
                        $mapdl->meshing->vmesh->{ninc}
                    );
            }
            push @{$mapdl->sects->{meshing}},
                "";  # End

        # End: Preprocessor
        push @{$mapdl->sects->{preproc_end}},
            $mapdl->processors->pre->{end},
            "\n";  # End

        # [2/3] Solution processor
        # Begin: Solution processor
        push @{$mapdl->sects->{solproc_begin}},
            $mapdl->Cmt->borders->{'#'},
            sprintf("%s [2/3] Solution processor", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'#'},
            $mapdl->processors->sol->{begin},
            "";  # End

        # Loads
        $mapdl->set_params(
            heat_gen_rate => {
                gconv => ['heat_gen_rate_'.$bconv->cell_mat, ''],
                motar => ['heat_gen_rate_'.$motar->cell_mat, ''],
            },
        );
        # Bremsstrahlung converter
        $mapdl->loads->set_dim(
            par  => $mapdl->params->{heat_gen_rate}{gconv}[0],
            type => 'table',
            imax => '%'.$mapdl->params->{tab_x_size}[0].'%',
            jmax => '%'.$mapdl->params->{tab_y_size}[0].'%',
            kmax => '%'.$mapdl->params->{tab_z_size}[0].'%',
            var1 => 'x',
            var2 => 'y',
            var3 => 'z',
        );
        $mapdl->loads->set_tread(
            par   => $mapdl->loads->dim->{par},
            fname => '%'.$mapdl->params->{tab_bname}{gconv}[0].'%',
            ext   => '%'.$mapdl->params->{tab_ext}[0].'%',
            nskip => 0,
        );
        $mapdl->loads->set_bfv(
            volu => $mapdl->entities->vol->{gconv}[0],
            lab  => 'hgen',
            val1 => '%'.$mapdl->params->{heat_gen_rate}{gconv}[0].'%',
        );
        push @{$mapdl->sects->{loads}},
            $mapdl->Cmt->borders->{'='},
            sprintf("%s (1/2) Loads", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'='},
            $mapdl->materials->gconv->{begin},
            sprintf(
                "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
                $mapdl->loads->dim->{cmd},
                $mapdl->loads->dim->{par},
                $mapdl->loads->dim->{type},
                $mapdl->loads->dim->{imax},
                $mapdl->loads->dim->{jmax},
                $mapdl->loads->dim->{kmax},
                $mapdl->loads->dim->{var1},
                $mapdl->loads->dim->{var2},
                $mapdl->loads->dim->{var3},
                $mapdl->loads->dim->{csysid}
            ),
            sprintf(
                "%s,%s,%s,%s,%s,%s",
                $mapdl->loads->tread->{cmd},
                $mapdl->loads->tread->{par},
                $mapdl->loads->tread->{fname},
                $mapdl->loads->tread->{ext},
                $mapdl->loads->tread->{unused},
                $mapdl->loads->tread->{nskip}
            ),
            sprintf(
                "%s,%s,%s,%s",
                $mapdl->loads->bfv->{cmd},
                $mapdl->loads->bfv->{volu},
                $mapdl->loads->bfv->{lab},
                $mapdl->loads->bfv->{val1}
            );
            $mapdl->loads->set_sfa(
                area   => $mapdl->entities->area->{gconv}[0],
                lab    => 'conv',
                value  =>
                    '%'.$mapdl->params->{heat_transfer_coeff}{gconv}[0].'%',
                value2 =>
                    '%'.$mapdl->params->{bulk_temperature}{gconv}[0].'%',
            );
            push @{$mapdl->sects->{loads}},
                sprintf(
                    "%s,%s,%s,%s,%s,%s",
                    $mapdl->loads->sfa->{cmd},
                    $mapdl->loads->sfa->{area},
                    $mapdl->loads->sfa->{lkey},
                    $mapdl->loads->sfa->{lab},
                    $mapdl->loads->sfa->{value},
                    $mapdl->loads->sfa->{value2}
                );
            $mapdl->loads->set_sfa(
                area => $mapdl->entities->area->{gconv}[1],
            );
            push @{$mapdl->sects->{loads}},
                sprintf(
                    "%s,%s,%s,%s,%s,%s",
                    $mapdl->loads->sfa->{cmd},
                    $mapdl->loads->sfa->{area},
                    $mapdl->loads->sfa->{lkey},
                    $mapdl->loads->sfa->{lab},
                    $mapdl->loads->sfa->{value},
                    $mapdl->loads->sfa->{value2}
                );
            # Molybdenum target, RCC "or" TRC
            if ($tar_of_int->flag ne $bconv->flag) {
                $mapdl->loads->set_dim(
                    par  => $mapdl->params->{heat_gen_rate}{motar}[0],
                    type => 'table',
                    imax => '%'.$mapdl->params->{tab_x_size}[0].'%',
                    jmax => '%'.$mapdl->params->{tab_y_size}[0].'%',
                    kmax => '%'.$mapdl->params->{tab_z_size}[0].'%',
                    var1 => 'x',
                    var2 => 'y',
                    var3 => 'z',
                );
                $mapdl->loads->set_tread(
                    par   => $mapdl->loads->dim->{par},
                    fname => '%'.$mapdl->params->{tab_bname}{motar}[0].'%',
                    ext   => '%'.$mapdl->params->{tab_ext}[0].'%',
                    nskip => 0,
                );
                $mapdl->loads->set_bfv(
                    volu => $mapdl->entities->vol->{motar}[0],
                    lab  => 'hgen',
                    val1 => '%'.$mapdl->params->{heat_gen_rate}{motar}[0].'%',
                );
                push @{$mapdl->sects->{loads}},
                    $mapdl->materials->motar->{begin},
                    sprintf(
                        "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
                        $mapdl->loads->dim->{cmd},
                        $mapdl->loads->dim->{par},
                        $mapdl->loads->dim->{type},
                        $mapdl->loads->dim->{imax},
                        $mapdl->loads->dim->{jmax},
                        $mapdl->loads->dim->{kmax},
                        $mapdl->loads->dim->{var1},
                        $mapdl->loads->dim->{var2},
                        $mapdl->loads->dim->{var3},
                        $mapdl->loads->dim->{csysid}
                    ),
                    sprintf(
                        "%s,%s,%s,%s,%s,%s",
                        $mapdl->loads->tread->{cmd},
                        $mapdl->loads->tread->{par},
                        $mapdl->loads->tread->{fname},
                        $mapdl->loads->tread->{ext},
                        $mapdl->loads->tread->{unused},
                        $mapdl->loads->tread->{nskip}
                    ),
                    sprintf(
                        "%s,%s,%s,%s",
                        $mapdl->loads->bfv->{cmd},
                        $mapdl->loads->bfv->{volu},
                        $mapdl->loads->bfv->{lab},
                        $mapdl->loads->bfv->{val1}
                    );
                $mapdl->loads->set_sfa(
                    area   => $mapdl->entities->area->{motar}[0],
                    lab    => 'conv',
                    value  =>
                        '%'.$mapdl->params
                            ->{heat_transfer_coeff}{motar}[0].'%',
                    value2 =>
                        '%'.$mapdl->params
                            ->{bulk_temperature}{motar}[0].'%',
                );
                push @{$mapdl->sects->{loads}},
                    sprintf(
                        "%s,%s,%s,%s,%s,%s",
                        $mapdl->loads->sfa->{cmd},
                        $mapdl->loads->sfa->{area},
                        $mapdl->loads->sfa->{lkey},
                        $mapdl->loads->sfa->{lab},
                        $mapdl->loads->sfa->{value},
                        $mapdl->loads->sfa->{value2}
                    );
                $mapdl->loads->set_sfa(
                    area => $mapdl->entities->area->{motar}[1],
                );
                push @{$mapdl->sects->{loads}},
                    sprintf(
                        "%s,%s,%s,%s,%s,%s",
                        $mapdl->loads->sfa->{cmd},
                        $mapdl->loads->sfa->{area},
                        $mapdl->loads->sfa->{lkey},
                        $mapdl->loads->sfa->{lab},
                        $mapdl->loads->sfa->{value},
                        $mapdl->loads->sfa->{value2}
                    );
            }
            push @{$mapdl->sects->{loads}},
                "";  # End

        # Solver
        push @{$mapdl->sects->{solver}},
            $mapdl->Cmt->borders->{'='},
            sprintf("%s (2/2) Run the solver", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'='},
            $mapdl->commands->solve->{cmd},
            "";  # End

        # End: Solution processor
        push @{$mapdl->sects->{solproc_end}},
            $mapdl->processors->sol->{end},
            "\n";  # End

        # [3/3] General postprocessor
        # Begin: General postprocessor
        push @{$mapdl->sects->{gen_postproc_begin}},
            $mapdl->Cmt->borders->{'#'},
            sprintf("%s [3/3] General postprocessor", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'#'},
            $mapdl->processors->gen_post->{begin},
            "";  # End

        # Viewing direction and angle
        push @{$mapdl->sects->{viewpoint}},
            $mapdl->Cmt->borders->{'='},
            sprintf("%s Viewpoint", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'='},
            sprintf("%s,%s,%s,%s,%s", '/VIEW', 1, 0, 0.5, -0.866),
            sprintf("%s,%s,%s", '/VUP', 1, 'X'                  ),
            sprintf("%s,%s", '/REPLOT', 'FAST',                 ),
            "";  # End

        # Contours
        push @{$mapdl->sects->{contours}},
            $mapdl->Cmt->borders->{'='},
            sprintf("%s Contours", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'='},
            sprintf(
                "%s,%s",
                '/EFACET',
                1
            ),
            sprintf(
                "%s,%s,,%s",
                'PLNSOL',
                'TEMP',
                0
            ),
            "";  # End

        # Generate image files
        push @{$mapdl->sects->{image_files}},
            $mapdl->Cmt->borders->{'='},
            sprintf("%s Generate image files", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'='};  # End

        # PostScript
        $mapdl->commands->set_get(
            par    => $mapdl->params->{job_name}[0],
            entity => 'active',
            entnum => 0,
            item1  => 'jobname',
        );
        $mapdl->set_ps_settings(
            high_resol => 1,  # Overwrite
        );
        $mapdl->commands->set_rename(
            # Old fname
            fname1 => sprintf(
                "%s000", '%'.$mapdl->params->{job_name}[0].'%'
            ),
            ext1   => '%'.$mapdl->params->{eps_ext}[0].'%',

            # New fname
            fname2 => '%'.(
                $tar_of_int->flag eq $bconv->flag ?
                $mapdl->params->{tab_bname}{gconv}[0] :
                $mapdl->params->{tab_bname}{motar}[0]
            ).'%',
            ext2   => '%'.$mapdl->params->{eps_ext}[0].'%',
        );
        push @{$mapdl->sects->{postscript}},
            $mapdl->Cmt->borders->{'-'},
            sprintf("%s PostScript", $mapdl->Cmt->symb),
            $mapdl->Cmt->borders->{'-'},
            "/SHOW,PSCR",
            "!*",
            "/SHOW,PSCR",
            sprintf(
                "PSCR,HIRES,%s",
                $mapdl->ps_settings->{high_resol},
            ),
            "/DEVICE,VECTOR,0",
            "/GFILE,800,",
            "!*",
            "PSCR,PAPER,A,PORT ! Last arg: PORT or LAND",
            "PSCR,COLOR,2",
            "PSCR,TIFF,0",
            "PSCR,LWID,3",
            "!*",
            "/CMAP,_TEMPCMAP_,CMP,,SAVE",
            "/RGB,INDEX,100,100,100,0",
            "/RGB,INDEX,0,0,0,15",
            "/REPLOT",
            "/CMAP,_TEMPCMAP_,CMP",
            "/DELETE,_TEMPCMAP_,CMP",
            "/SHOW,CLOSE",
            "/DEVICE,VECTOR,0",
            sprintf(
                "%s,%s,%s,%s,%s",
                $mapdl->commands->get->{cmd},
                $mapdl->commands->get->{par},
                $mapdl->commands->get->{entity},
                $mapdl->commands->get->{entnum},
                $mapdl->commands->get->{item1}
            ),
            sprintf(
                "%s,%s,%s,%s,%s,%s,%s,%s",
                $mapdl->commands->rename->{cmd},
                $mapdl->commands->rename->{fname1},
                $mapdl->commands->rename->{ext1},
                $mapdl->commands->rename->{unused1},
                $mapdl->commands->rename->{fname2},
                $mapdl->commands->rename->{ext2},
                $mapdl->commands->rename->{unused2},
                $mapdl->commands->rename->{distkey},
            ),
            "";  # End

        # End: General postprocessor
        push @{$mapdl->sects->{gen_postproc_end}},
            $mapdl->processors->gen_post->{end},
            "\n";  # End

        # Write to the MAPDL macro file
        if ($mapdl->Ctrls->switch =~ /on/i) {
            open my $mapdl_fh, '>:encoding(UTF-8)', $mapdl->FileIO->inp;
            select($mapdl_fh);
            map { say for @{$mapdl->sects->{$_}} } qw(
                title
                abbr
                parameters

                preproc_begin
                primitives
                mat_props
                meshing
                preproc_end

                solproc_begin
                loads
                solver
                solproc_end

                gen_postproc_begin
                viewpoint
                contours
                image_files
                postscript
            );
            print $mapdl->Data->eof;

            select(STDOUT);
            close $mapdl_fh;

            # Notify the file generation.
            printf("[%s] generated.\n", $mapdl->FileIO->inp);
        }

        #-----------------------------------------------------------
        # Step 2
        # > Run phits.bat:            .inp --> .ang
        # > Modify and memorize .ang: .ang --> .ang
        # > For example:
        #   > Flux [cm^-2 source^-1] -->
        #     Monte Carlo fluence (cm^{-2} source{^-1})
        #   > Cluster plot min (cmin) and max (cmax)
        #     for a consistent range of color box.
        #   > [MeV] --> (MeV)
        #   > [cm] --> (cm)
        #     Works only when $angel->dim_unit eq 'cm'
        #     because, as of PHITS v3.02 and ANGEl v4.36,
        #     the ANGEL dimension commands like cmmm
        #     identify only square bracketed cm, or [cm].
        # > The tally filenames are memorized for future ANGEL running.
        # > Memorize nps from the summary output file (.out).
        #-----------------------------------------------------------
        if ($phits->Ctrls->switch =~ /on/i) {
            #
            # If the dump source mode has been turned on (via cmd-line opt),
            # run the dump-source-generating input file through PHITS.
            #
            if ($phits->source->mode =~ /du?mp/i) {
                say "";
                say $phits->Cmt->borders->{'='};
                printf(
                    "%s [%s] running\n".
                    "%s [%s] through [%s]...\n",
                    $phits->Cmt->symb, (caller(0))[3],
                    $phits->Cmt->symb, $phits->FileIO->inp_dmp, $phits->exe
                );
                say $phits->Cmt->borders->{'='};

                system sprintf("%s %s", $phits->exe, $phits->FileIO->inp_dmp);
            }

            #
            # If the T-Gshow tally switch has been turned on, temporarily
            # modify the icntl of PHITS input file to 7 and run it.
            #
            if ($t_gshow->Ctrls->switch =~ /on/i) {
                # Make a temporary file for T-Gshow.
                my $t_gshow_tmp = 't_gshow.inp';
                open my $t_gshow_tmp_fh, '>:encoding(UTF-8)', $t_gshow_tmp;
                open my $phits_inp_fh, '<', $phits->FileIO->inp;
                foreach (<$phits_inp_fh>) {
                    s/^\s*icntl.*/icntl    =     7/;
                    print $t_gshow_tmp_fh $_;
                }
                close $t_gshow_tmp_fh;
                close $phits_inp_fh;

                # Run PHITS with icntl = 7.
                say "";
                say $phits->Cmt->borders->{'='};
                printf(
                    "%s [%s] running\n".
                    "%s [%s] through [%s]...\n",
                    $phits->Cmt->symb, (caller(0))[3],
                    $phits->Cmt->symb, $t_gshow_tmp, $phits->exe
                );
                say $phits->Cmt->borders->{'='};

                system sprintf("%s %s", $phits->exe, $t_gshow_tmp);
            }

            #
            # If the T-3Dshow tally switch has been turned on, temporarily
            # modify the icntl of PHITS input file to 11 and run it.
            #
            if ($t_3dshow->Ctrls->switch =~ /on/i) {
                # Make a temporary file for T-3Dshow.
                my $t_3dshow_tmp = 't_3dshow.inp';
                open my $t_3dshow_tmp_fh, '>:encoding(UTF-8)', $t_3dshow_tmp;
                open my $phits_inp_fh, '<', $phits->FileIO->inp;
                foreach (<$phits_inp_fh>) {
                    s/^\s*icntl.*/icntl    =     11/;
                    print $t_3dshow_tmp_fh $_;
                }
                close $t_3dshow_tmp_fh;
                close $phits_inp_fh;

                # Run PHITS with icntl = 11.
                say "";
                say $phits->Cmt->borders->{'='};
                printf(
                    "%s [%s] running\n".
                    "%s [%s] through [%s]...\n",
                    $phits->Cmt->symb, (caller(0))[3],
                    $phits->Cmt->symb, $t_3dshow_tmp, $phits->exe
                );
                say $phits->Cmt->borders->{'='};

                system sprintf("%s %s", $phits->exe, $t_3dshow_tmp);
            }

            #
            # Run PHITS with icntl = 0.
            #
            say "";
            say $phits->Cmt->borders->{'='};
            printf(
                "%s [%s] running\n".
                "%s [%s] through [%s]...\n",
                $phits->Cmt->symb, (caller(0))[3],
                $phits->Cmt->symb, $phits->FileIO->inp, $phits->exe
            );
            say $phits->Cmt->borders->{'='};

            system sprintf("%s %s", $phits->exe, $phits->FileIO->inp);
        }

        #
        # Modify tally file strings and memorize their filenames
        # for future ANGEL running.
        #
        if (
            $phits->Ctrls->switch           =~ /on/i
            or $angel->Ctrls->switch        =~ /on/i
            or $angel->Ctrls->modify_switch =~ /on/i
        ) {
            # T-Track "particle distributions"
            $angel->modify_and_or_memorize_ang_files(
                # Source particle
                $phits->source->spat_dist_of_int->{proj}{val},
                $angel->Cmt->annot_type,
                $t_track->xz->fname,
                $t_track->Ctrls->err_switch =~ /on/i ?
                    $t_track->xz->err_fname : '',
                $t_track->yz->fname,
                $t_track->Ctrls->err_switch =~ /on/i ?
                    $t_track->yz->err_fname : '',
                $bconv->flag !~ /none/i ? (
                    $t_track->xy_bconv->fname,
                    $t_track->Ctrls->err_switch =~ /on/i ?
                        $t_track->xy_bconv->err_fname : '',
                ) : '',
                $t_track->xy_motar->fname,
                $t_track->Ctrls->err_switch =~ /on/i ?
                    $t_track->xy_motar->err_fname : '',
            );

            # T-Track "energy spectra"
            if ($phits->params->{icntl}{val} eq 0) {
                $angel->modify_and_or_memorize_ang_files(
                    $phits->source->spat_dist_of_int->{proj}{val},
                    $angel->Cmt->annot_type,
                    $bconv->flag !~ /none/i ? (
                        $t_track->nrg_bconv->fname,
                        $t_track->nrg_bconv_low_emax->fname,
                    ) : '',
                    $t_track->nrg_motar->fname,
                    $t_track->nrg_motar_low_emax->fname,
                    $flux_mnt_up->height == 0 ?
                        '' : $t_track->nrg_flux_mnt_up->fname,
                    $flux_mnt_down->height == 0 ?
                        '' : $t_track->nrg_flux_mnt_down->fname,
                );
            }

            # T-Cross
            if ($phits->params->{icntl}{val} eq 0) {
                $angel->modify_and_or_memorize_ang_files(
                    $phits->source->spat_dist_of_int->{proj}{val},
                    $angel->Cmt->annot_type,
                    $t_cross->nrg_intact->fname,
                    $t_cross->nrg_intact_low_emax->fname,
                    $bconv->flag !~ /none/i ? (
                        $t_cross->nrg_bconv_ent->fname,
                        $t_cross->nrg_bconv_ent_low_emax->fname,
                        $t_cross->nrg_bconv_exit->fname,
                        $t_cross->nrg_bconv_exit_low_emax->fname,
                    ) : '',
                    $t_cross->nrg_motar_ent->fname,
                    $t_cross->nrg_motar_ent_low_emax->fname,
                    $t_cross->nrg_motar_exit->fname,
                    $t_cross->nrg_motar_exit_low_emax->fname
                );
            }

            # T-Heat
            if (
                $phits->params->{icntl}{val} eq 0 and
                $t_heat->Ctrls->switch =~ /on/i
            ) {
                $angel->modify_and_or_memorize_ang_files(
                    $phits->source->spat_dist_of_int->{proj}{val},
                    $angel->Cmt->annot_type,
                    $t_heat->xz->fname,
                    $t_heat->Ctrls->err_switch =~ /on/i ?
                        $t_heat->xz->err_fname : '',
                    $t_heat->yz->fname,
                    $t_heat->Ctrls->err_switch =~ /on/i ?
                        $t_heat->yz->err_fname : '',
                    $bconv->flag !~ /none/i ? (
                        $t_heat->xy_bconv->fname,
                        $t_heat->rz_bconv->fname,
                        $t_heat->Ctrls->err_switch =~ /on/i ?
                            (
                                $t_heat->xy_bconv->err_fname,
                                $t_heat->rz_bconv->err_fname,
                            ) : '',
#                        $t_heat->reg_bconv->fname,
                    ) : '',
                    $t_heat->xy_motar->fname,
                    $t_heat->rz_motar->fname,
                    $t_heat->Ctrls->err_switch =~ /on/i ?
                        $t_heat->xy_motar->err_fname : '',
                        $t_heat->rz_motar->err_fname,
#                    $t_heat->reg_motar->fname,
                );
            }

            # T-Gshow
            $angel->modify_and_or_memorize_ang_files(
                $phits->source->spat_dist_of_int->{proj}{val},
                $angel->Cmt->annot_type,
                $t_gshow->xz->fname,
                $t_gshow->yz->fname,
                $bconv->flag !~ /none/i ? $t_gshow->xy_bconv->fname : '',
                $t_gshow->xy_motar->fname,
            );

            # T-3Dshow
            $angel->modify_and_or_memorize_ang_files(
                $phits->source->spat_dist_of_int->{proj}{val},
                $angel->Cmt->annot_type,
                $t_3dshow->polar1a->fname,
                $t_3dshow->polar1b->fname,
                $t_3dshow->polar2a->fname,
                $t_3dshow->polar2b->fname,
            );
        }

        #
        # Memorize nps.
        #
        open my $smr_fh, '<', $phits->params->{file}{summary_out_fname}{val};
        chomp(my @_smr = <$smr_fh>);
        $phits->set_retrieved(
            maxcas => (first { s/^\s*maxcas\s*=\s*([0-9]+).*/$1/ } @_smr)
                // 'Not found',
            maxbch => (first { s/^\s*maxbch\s*=\s*([0-9]+).*/$1/ } @_smr)
                // 'Not found',
        );
        close $smr_fh;

        #-----------------------------------------------------------
        # Step 3
        # Generate MAPDL tab files: .ang --> .tab
        # > Convert the tally files of $t_heat_mapdl to
        #   MAPDL table parameter files using xy-heat tallies.
        #-----------------------------------------------------------
        if ($mapdl->Ctrls->switch =~ /on/i) {
            $phits->ang_to_mapdl_tab(
                # Bremsstrahlung converter
                $t_heat->xy_bconv_mapdl->fname,
                # Molybdenum target
                $t_heat->xy_motar_mapdl->fname,
            );
        }

        #-----------------------------------------------------------
        # Step 4
        # Run angel.bat: .ang --> .eps
        # > Modify .eps: .eps --> .eps
        # > For example:
        #   > [mm] --> (mm)
        #     [um] --> (mm)
        #-----------------------------------------------------------
        if ($angel->Ctrls->switch =~ /on/i) {
            # Notify the beginning of ANGEL running.
            say "";
            say $angel->Cmt->borders->{'='};
            printf(
                "%s [%s] running [%s]...\n",
                $angel->Cmt->symb, (caller(0))[3], $angel->exe
            );
            say $angel->Cmt->borders->{'='};

            # @{$self->ang_fnames}:
            # Filled by $angel->modify_and_or_memorize_ang_files,
            # performed in the step 2 above.
            foreach (@{$angel->ang_fnames}) {
                say $angel->Cmt->borders->{'-'};
                printf(
                    "%s [%s] running through [%s]...\n",
                    $angel->Cmt->symb,
                    $_,
                    $angel->exe
                );
                say $angel->Cmt->borders->{'-'};

                system sprintf("%s %s", $angel->exe, $_);
            }
        }
        if ($angel->Ctrls->modify_switch =~ /on/i) {
            $angel->modify_eps_files(
                $angel->ang_fnames,
                $angel->dim_unit,
            );
        }

        #-----------------------------------------------------------
        # Step 5
        # > Run gs.exe (or Win ver) : .eps --> .pdf, .png, .jpg
        # > Run inkscape.exe:         .eps --> .svg, .emf, .wmf
        # > Memorize the names of the raster images for their
        #   animation by ImageMagick and/or FFmpeg at the Step 7.
        # > The Ghostscript's .eps --> .png/.jpg rasterization
        #   can also be performed via ImageMagick, which leverages
        #   Ghostscript for processing PostScript files.
        # > ImageMagick is a program that is used in the next step
        #   for animating the rasterized images to GIF files.
        #   Thus, if the PS rasterization via ImageMagick yields
        #   the same results as the direct use of Ghostscript,
        #   this step could be combined into the Step 7.
        # > Via ImageMagick, however, an ANGEL-generated PS file
        #   is not correctly rasterized except the first page.
        #   The author attributes the cause to their multipage
        #   nature:
        #   Although ANGEL-generated PS files are associated with
        #   the .eps extension and are referred to as EPS files
        #   by the developer's design, strictly speaking they are
        #   PS files, as are multipaged.
        # > Direct use of Ghostscript works just fine for this job!
        #-----------------------------------------------------------
        if (
            $image->Ctrls->pdf_switch        =~ /on/i
            or $image->Ctrls->svg_switch     =~ /on/i
            or $image->Ctrls->emf_switch     =~ /on/i
            or $image->Ctrls->wmf_switch     =~ /on/i
            or $image->Ctrls->png_switch     =~ /on/i
            or $image->Ctrls->png_trn_switch =~ /on/i
            or $image->Ctrls->jpg_switch     =~ /on/i
            or $animate->Ctrls->gif_switch   =~ /on/i
            or $animate->Ctrls->mp4_switch   =~ /on/i
            or $animate->Ctrls->avi_switch   =~ /on/i
        ) {
            # When the animate switch has been turned on
            # but no rasterization is to be performed,
            # turn on the skipping switch of Ghostscript that,
            # without running its executable,
            # provides a list of raster-containing
            # subdirectory names by @{$image->rasters_dirs}.
            # If the subdirectories exist, the rasters will be
            # animated by ImageMagick and/or FFmpeg.
            $image->Ctrls->set_skipping_switch('on') if (
                (
                    $animate->Ctrls->gif_switch    =~ /on/i
                    or $animate->Ctrls->mp4_switch =~ /on/i
                    or $animate->Ctrls->avi_switch =~ /on/i
                ) and (
                    $image->Ctrls->png_switch         =~ /off/i
                    and $image->Ctrls->png_trn_switch =~ /off/i
                    and $image->Ctrls->jpg_switch     =~ /off/i
                )
            );

            # T-Track "particle distributions"
            $image->convert(
                [
                    $t_track->xz->fname,
                    $t_track->xz->flag,
                ],
                $t_track->Ctrls->err_switch =~ /on/i ?
                    [
                        $t_track->xz->err_fname,
                        $t_track->xz->err_flag,
                    ] : [],
                [
                    $t_track->yz->fname,
                    $t_track->yz->flag,
                ],
                $t_track->Ctrls->err_switch =~ /on/i ?
                    [
                        $t_track->yz->err_fname,
                        $t_track->yz->err_flag,
                    ] : [],
                # Bremsstrahlung converter
                $bconv->flag !~ /none/i ?
                    (
                        [
                            $t_track->xy_bconv->fname,
                            $t_track->xy_bconv->flag,
                        ],
                        $t_track->Ctrls->err_switch =~ /on/i ?
                            [
                                $t_track->xy_bconv->err_fname,
                                $t_track->xy_bconv->err_flag,
                            ] : [],
                    ) : [],
                # Molybdenum target
                [
                    $t_track->xy_motar->fname,
                    $t_track->xy_motar->flag,
                ],
                $t_track->Ctrls->err_switch =~ /on/i ?
                    [
                        $t_track->xy_motar->err_fname,
                        $t_track->xy_motar->err_flag,
                    ] : [],
                # Hooks
                {
                    varying     => $phits->FileIO->varying_flag,  # vhgt
                    fixed       => $phits->FileIO->fixed_flag,    # frad-fgap
                    orientation => $angel->orientation,
                },
            );

            # T-Track "energy spectra"
            if ($phits->params->{icntl}{val} eq 0) {
                $image->convert(
                    # Bremsstrahlung converter: Plain
                    $bconv->flag !~ /none/i ?
                        [
                            $t_track->nrg_bconv->fname,
                            $t_track->nrg_bconv->flag,
                        ] : [],
                    # Bremsstrahlung converter: Low emax for photoneutrons
                    ($bconv->flag !~ /none/i and $t_track->is_neut_of_int) ?
                        [
                            $t_track->nrg_bconv_low_emax->fname,
                            $t_track->nrg_bconv_low_emax->flag,
                        ] : [],
                    # Molybdenum target: Plain
                    [
                        $t_track->nrg_motar->fname,
                        $t_track->nrg_motar->flag,
                    ],
                    # Molybdenum target: Low emax for photoneutrons
                    $t_track->is_neut_of_int ?
                        [
                            $t_track->nrg_motar_low_emax->fname,
                            $t_track->nrg_motar_low_emax->flag,
                        ] : [],
                    # Flux monitor: Upstream
                    $flux_mnt_up->height > 0 ?
                        [
                            $t_track->nrg_flux_mnt_up->fname,
                            $t_track->nrg_flux_mnt_up->flag,
                        ] : [],
                    # Flux monitor: Downstream
                    $flux_mnt_down->height > 0 ?
                        [
                            $t_track->nrg_flux_mnt_down->fname,
                            $t_track->nrg_flux_mnt_down->flag,
                        ] : [],
                    # Hooks
                    {
                        varying     => $phits->FileIO->varying_flag,
                        fixed       => $phits->FileIO->fixed_flag,
                        orientation => $angel->orientation,
                    },
                );
            }

            # T-Cross
            if ($phits->params->{icntl}{val} eq 0) {
                $image->convert(
                    # Intact particles: Plain
                    [
                        $t_cross->nrg_intact->fname,
                        $t_cross->nrg_intact->flag,
                    ],
                    # Intact particles: Low emax for photoneutrons
                    $t_cross->is_neut_of_int ?
                        [
                            $t_cross->nrg_intact_low_emax->fname,
                            $t_cross->nrg_intact_low_emax->flag,
                        ] : [],
                    # Bremsstrahlung converter: Plain
                    $bconv->flag !~ /none/i ?
                        (
                            [
                                $t_cross->nrg_bconv_ent->fname,
                                $t_cross->nrg_bconv_ent->flag,
                            ],
                            [
                                $t_cross->nrg_bconv_exit->fname,
                                $t_cross->nrg_bconv_exit->flag,
                            ],
                        ) : [],
                    # Bremsstrahlung converter: Low emax for photoneutrons
                    ($bconv->flag !~ /none/i and $t_cross->is_neut_of_int) ?
                        (
                            [
                                $t_cross->nrg_bconv_ent_low_emax->fname,
                                $t_cross->nrg_bconv_ent_low_emax->flag,
                            ],
                            [
                                $t_cross->nrg_bconv_exit_low_emax->fname,
                                $t_cross->nrg_bconv_exit_low_emax->flag,
                            ],
                        ) : [],
                    # Molybdenum target: Plain
                    [
                        $t_cross->nrg_motar_ent->fname,
                        $t_cross->nrg_motar_ent->flag,
                    ],
                    [
                        $t_cross->nrg_motar_exit->fname,
                        $t_cross->nrg_motar_exit->flag
                    ],
                    # Molybdenum target: Low emax for photoneutrons
                    $t_cross->is_neut_of_int ?
                        (
                            [
                                $t_cross->nrg_motar_ent_low_emax->fname,
                                $t_cross->nrg_motar_ent_low_emax->flag,
                            ],
                            [
                                $t_cross->nrg_motar_exit_low_emax->fname,
                                $t_cross->nrg_motar_exit_low_emax->flag,
                            ],
                        ) : [],
                    # Hooks
                    {
                        varying     => $phits->FileIO->varying_flag,
                        fixed       => $phits->FileIO->fixed_flag,
                        orientation => $angel->orientation,
                    },
                );
            }

            # T-Heat
            if (
                $phits->params->{icntl}{val} eq 0
                and $t_heat->Ctrls->switch =~ /on/i
            ) {
                $image->convert(
                    [
                        $t_heat->xz->fname,
                        $t_heat->xz->flag,
                    ],
                    $t_heat->Ctrls->err_switch =~ /on/i ?
                        [
                            $t_heat->xz->err_fname,
                            $t_heat->xz->err_flag,
                        ] : [],
                    [
                        $t_heat->yz->fname,
                        $t_heat->yz->flag,
                    ],
                    $t_heat->Ctrls->err_switch =~ /on/i ?
                        [
                            $t_heat->yz->err_fname,
                            $t_heat->yz->err_flag,
                        ] : [],
                    # Bremsstrahlung converter
                    $bconv->flag !~ /none/i ?
                        (
                            [
                                $t_heat->xy_bconv->fname,
                                $t_heat->xy_bconv->flag
                            ],
                            $t_heat->Ctrls->err_switch =~ /on/i ?
                                [
                                    $t_heat->xy_bconv->err_fname,
                                    $t_heat->xy_bconv->err_flag,
                                ] : [],
                            [
                                $t_heat->rz_bconv->fname,
                                $t_heat->rz_bconv->flag
                            ],
                            $t_heat->Ctrls->err_switch =~ /on/i ?
                                [
                                    $t_heat->rz_bconv->err_fname,
                                    $t_heat->rz_bconv->err_flag,
                                ] : [],
#                            [
#                                $t_heat->reg_bconv->fname,
#                                $t_heat->reg_bconv->flag,
#                            ],
                        ) : [],
                    # Molybdenum target
                    [
                        $t_heat->xy_motar->fname,
                        $t_heat->xy_motar->flag,
                    ],
                    $t_heat->Ctrls->err_switch =~ /on/i ?
                        [
                            $t_heat->xy_motar->err_fname,
                            $t_heat->xy_motar->err_flag,
                        ] : [],
                    [
                        $t_heat->rz_motar->fname,
                        $t_heat->rz_motar->flag
                    ],
                    $t_heat->Ctrls->err_switch =~ /on/i ?
                        [
                            $t_heat->rz_motar->err_fname,
                            $t_heat->rz_motar->err_flag,
                        ] : [],
#                    [
#                        $t_heat->reg_motar->fname,
#                        $t_heat->reg_motar->flag,
#                    ],
                    # Hooks
                    {
                        varying     => $phits->FileIO->varying_flag,
                        fixed       => $phits->FileIO->fixed_flag,
                        orientation => $angel->orientation,
                    },
                );
            }

            # T-Gshow
            $image->convert(
                [
                    $t_gshow->xz->fname,
                    $t_gshow->xz->flag,
                ],
                [
                    $t_gshow->yz->fname,
                    $t_gshow->yz->flag,
                ],
                # Bremsstrahlung converter
                $bconv->flag !~ /none/i ?
                    [
                        $t_gshow->xy_bconv->fname,
                        $t_gshow->xy_bconv->flag,
                    ] : [],
                # Molybdenum target
                [
                    $t_gshow->xy_motar->fname,
                    $t_gshow->xy_motar->flag,
                ],
                # Hooks
                {
                    varying     => $phits->FileIO->varying_flag,
                    fixed       => $phits->FileIO->fixed_flag,
                    orientation => $angel->orientation,
                },
            );

            # T-3Dshow
            $image->convert(
                [$t_3dshow->polar1a->fname, $t_3dshow->polar1a->flag],
                [$t_3dshow->polar1b->fname, $t_3dshow->polar1b->flag],
                [$t_3dshow->polar2a->fname, $t_3dshow->polar2a->flag],
                [$t_3dshow->polar2b->fname, $t_3dshow->polar2b->flag],
                # Hooks
                {
                    varying     => $phits->FileIO->varying_flag,
                    fixed       => $phits->FileIO->fixed_flag,
                    orientation => $angel->orientation,
                },
            );
        }

        #-----------------------------------------------------------
        # Step 6
        # Calculate the yields and specific yields of
        # Mo-99 and/or Au-196, and generate data files.
        #-----------------------------------------------------------
        if (  # Mo-99 from the Mo target in question
            $yield_mo99->Ctrls->switch =~ /on/i
            and $motar->cell_mat =~ /mo/i  # mo, moo2, moo3
        ) {
            run_and_rpt_calc_rn_yield(
                $motar,
                'mo100',      # react_nucl
                'mo99',       # prod_nucl
                '',           # prod_nucl_flag
                $yield,       # Delegate of all products
                $yield_mo99,  # Delegate of products
                $yield_mo99,  # Individual product
                $yield_mo99_for_sp_src,
                $pwm_mo99_for_sp_src,
                $t_track->nrg_motar->fname,  # Fluence data
                # >> Dependent on inner_iterator()
                $tar_of_int,
                $_varying_str,
                $run_opts_href,
                $prog_info_href,
                $source_eg0,
                # <<
            );
        }
        if (  # Au-196 from the upstream Au foil in question
            $yield_au196->Ctrls->switch =~ /on/i
            and $flux_mnt_up->height > 0
        ) {
            run_and_rpt_calc_rn_yield(
                $flux_mnt_up,
                'au197',
                'au196',
                '_1',
                $yield,
                $yield_au196,
                $yield_au196_1,
                $yield_au196_1_for_sp_src,
                $pwm_au196_1_for_sp_src,
                $t_track->nrg_flux_mnt_up->fname,
                # >> Dependent on inner_iterator()
                $tar_of_int,
                $_varying_str,
                $run_opts_href,
                $prog_info_href,
                $source_eg0,
                # <<
            );
        }
        if (  # Au-196 from the downstream Au foil in question
            $yield_au196->Ctrls->switch =~ /on/i
            and $flux_mnt_down->height > 0
        ) {
            run_and_rpt_calc_rn_yield(
                $flux_mnt_down,
                'au197',
                'au196',
                '_2',
                $yield,
                $yield_au196,
                $yield_au196_2,
                $yield_au196_2_for_sp_src,
                $pwm_au196_2_for_sp_src,
                $t_track->nrg_flux_mnt_down->fname,
                # >> Dependent on inner_iterator()
                $tar_of_int,
                $_varying_str,
                $run_opts_href,
                $prog_info_href,
                $source_eg0,
                # <<
            );
        }
    }

    #-----------------------------------------------------------
    # Step 7
    # Run magick.exe: .png/.jpg --> .gif
    # Run ffmpeg.exe: .gif      --> .mp4/.avi
    #-----------------------------------------------------------
    if (
        $animate->Ctrls->gif_switch =~ /on/i or
        $animate->Ctrls->avi_switch =~ /on/i or
        $animate->Ctrls->mp4_switch =~ /on/i
    ) {
        $animate->rasters_to_anims(
            # rasters_dirs:
            # > An array reference of the names of subdirectories
            #   containing sequences of raster images.
            # > Filled in by $image->convert at the step 5.
            $image->rasters_dirs,
            # The raster file format to be animated.
            $animate->Ctrls->raster_format,
        );
    }

    #-----------------------------------------------------------
    # Step 8
    # Generate MAPDL macro-of-macro files (.mac).
    # > Preferable to an MAPDL macro library file that requires
    #   additional keystrokes such as the *ulib MAPDL command.
    #-----------------------------------------------------------
    if (
        $mapdl_of_macs->Ctrls->switch     =~ /on/i or
        $mapdl_of_macs_all->Ctrls->switch =~ /on/i
    ) {
        #
        # Define filenames.
        #

        # Target-specific
        # e.g. wrcc-vrad-fhgt.mac
        $mapdl_of_macs->FileIO->set_inp(
            (
                $tar_of_int->flag.
                $phits->FileIO->fname_sep.
                $phits->FileIO->varying_flag.
                $phits->FileIO->fname_sep.
                $phits->FileIO->fixed_flag
            ).
            $mapdl_of_macs->FileIO->fname_ext_delim.
            $mapdl_of_macs->FileIO->fname_exts->{mac}
        );

        # Target-independent
        # e.g. 20180730\beam_fwhm_0p3\phitar.mac
        $mapdl_of_macs_all->FileIO->set_inp(
            $phits->cwd.
            $phits->FileIO->path_delim.
            $mapdl->params->{job_name}[1].
            $mapdl_of_macs->FileIO->fname_ext_delim.
            $mapdl_of_macs->FileIO->fname_exts->{mac}
        );

        #
        # Write to the macro-of-macros.
        #

        # Notify the beginning of macro-of-macro file generation.
        say "";
        say $mapdl->Cmt->borders->{'='};
        printf(
            "%s [%s] generating MAPDL macro-of-macros files...\n",
            $mapdl->Cmt->symb, (caller(0))[3]
        );
        say $mapdl->Cmt->borders->{'='};

        # Target-specific: Contents are initialized at each inner iterator.
        open my $mapdl_of_macros_fh,
            '>:encoding(UTF-8)',
            $mapdl_of_macs->FileIO->inp;
        select($mapdl_of_macros_fh);
        printf("%s\n\n", $mapdl->commands->batch->{cmd});
        foreach my $macro (@{$mapdl_of_macs->FileIO->macs}) {
            print $macro;
            if ($macro ne ${$mapdl_of_macs->FileIO->macs}[-1]) {
                printf(
                    "\n%s,%s\n\n",
                    $mapdl->commands->clear->{cmd},
                    $mapdl->commands->clear->{read}
                );
            }
        }
        select(STDOUT);
        close $mapdl_of_macros_fh;

        # Target-independent: Contents are not initialized.
        if ($mapdl_of_macs_all->Ctrls->switch =~ /on/i) {
            open my $mapdl_of_macros_all_fh,
                '>:encoding(UTF-8)',
                $mapdl_of_macs_all->FileIO->inp;
            select($mapdl_of_macros_all_fh);
            printf("%s\n\n", $mapdl->commands->batch->{cmd});
            foreach my $macro (@{$mapdl_of_macs_all->FileIO->macs}) {
                print $macro;
                if ($macro ne ${$mapdl_of_macs_all->FileIO->macs}[-1]) {
                    printf(
                        "\n%s,%s\n\n",
                        $mapdl->commands->clear->{cmd},
                        $mapdl->commands->clear->{read}
                    );
                }
            }
            select(STDOUT);
            close $mapdl_of_macros_all_fh;
        }

        # Notify the generation of the files.
        printf(
            "Target-specific: [%s] generated.\n",
            $mapdl_of_macs->FileIO->inp
        );
        if ($mapdl_of_macs_all->Ctrls->switch =~ /on/i) {
            printf(
                "All targets:     [%s] generated.\n",
                $mapdl_of_macs_all->FileIO->inp
            );
        }
        say "";
    }

    #-----------------------------------------------------------
    # Step 9
    # Retrieve maximum total fluences from the tally files.
    # > Collect the total CPU times.
    # > Collect the maximum total fluences.
    # > Generate data reduction report files.
    #-----------------------------------------------------------
    state %hash_max_flues;
    my @retrieve_tot_flues_from;

    #
    # Fill in a buffer: Intact particles
    #
    push @retrieve_tot_flues_from,               # e.g.
        $t_cross->nrg_intact->flag;              # cross-eng-intact
        # Low emax tallies (ceil(emax of [source] / 8))
        push @retrieve_tot_flues_from,
            $t_cross->nrg_intact_low_emax->flag  # cross-eng-intact_low_emax
                if $t_cross->is_neut_of_int;

    #
    # Fill in a buffer: Bremsstrahlung converter
    #
    if ($bconv->flag !~ /none/i) {
        push @retrieve_tot_flues_from,       # e.g.
            $t_track->nrg_bconv->flag,       # track-eng-w
            $t_cross->nrg_bconv_ent->flag,   # cross-eng-w_ent
            $t_cross->nrg_bconv_exit->flag;  # cross-eng-w_exit (conv design)
        # Low emax tallies (ceil(emax of [source] / 8))
        push @retrieve_tot_flues_from,
            $t_track->nrg_bconv_low_emax->flag  # track-eng-w_low_emax
                if $t_track->is_neut_of_int;
        push @retrieve_tot_flues_from, (
            # cross-eng-w_ent_low_emax
            # cross-eng-w_exit_low_emax
            $t_cross->nrg_bconv_ent_low_emax->flag,
            $t_cross->nrg_bconv_exit_low_emax->flag,
        ) if $t_cross->is_neut_of_int;
    }

    #
    # Fill in a buffer: Molybdenum target
    #
    push @retrieve_tot_flues_from,          # e.g.
        $t_track->nrg_motar->flag,          # track-eng-mo (yield calc)
        $t_cross->nrg_motar_ent->flag,      # cross-eng-mo_ent
        $t_cross->nrg_motar_exit->flag;     # cross-eng-mo_exit
        # Neutron tallies (ceil(emax of [source] / 8))
    push @retrieve_tot_flues_from,
        $t_track->nrg_motar_low_emax->flag  # track-eng-mo_low_emax
            if $t_track->is_neut_of_int;
    push @retrieve_tot_flues_from, (
        # cross-eng-mo_ent_low_emax
        # cross-eng-mo_exit_low_emax
        $t_cross->nrg_motar_ent_low_emax->flag,
        $t_cross->nrg_motar_exit_low_emax->flag,
    ) if $t_cross->is_neut_of_int;

    #
    # Fill in a buffer: Flux monitors
    #
    push @retrieve_tot_flues_from,
        $t_track->nrg_flux_mnt_up->flag  # track-eng-au_up
            if $flux_mnt_up->height > 0;
    push @retrieve_tot_flues_from,
        $t_track->nrg_flux_mnt_down->flag  # track-eng-au_down
            if $flux_mnt_down->height > 0;

    #
    # Flush the buffer, and
    # > Run retrieve_tot_fluences() to obtain the maximum total fluences.
    # > Run reduce_data() for data reduction.
    #

    # Run retrieve_tot_fluences() and reduce_data().
    if ($t_tot_fluence->Ctrls->switch =~ /on/i) {
        my ($dir, $sub, $subsub) = (split /\/|\\/, getcwd())[-3, -2, -1];
        my %_total_cpu_times_sums;
        my @return_vals;
        foreach my $tally_flag (@retrieve_tot_flues_from) {
            #
            # Note on filling the arrays belonging to %hash_max_flues
            # > The hash key is associated with a given set of
            #   a target material, a varying parameter, and a tally.
            #   This is necessary because different varying parameters
            #   such as height and radius can have the same $tally_flag,
            #   and different target materials such as Ta and W can have
            #   the same varying parameters.
            # > On the other hand, we intentionally make the hash key
            #   independent of the control variable of the outer loop,
            #   which can either be the beam energy or the beam size,
            #   so that we can see the change of the maximum total fluences
            #   with respect to beam energy or beam size.
            #   CAUTION: DO NOT mix the varying parameter of source particles,
            #   which will overwrite the report files of max total fluences.
            #
            unless (
                exists
                    $hash_max_flues
                        {$tar_of_int->flag}
                        {$phits->FileIO->varying_flag}
                        {$tally_flag}
            ) {
                $hash_max_flues
                    {$tar_of_int->flag}
                    {$phits->FileIO->varying_flag}
                    {$tally_flag} =
                        [];
            }

            #
            # Memorize the return values of retrieve_tot_fluences().
            #
            # Content of @return_vals
            #               Namespace
            #    phitar.pl             Tally.pm
            # $return_vals[0]  $total_cpu_times_sum{sec}
            # $return_vals[1]  $total_cpu_times_sum{hour}
            # $return_vals[2]  $total_cpu_times_sum{day}
            # $return_vals[3]  $self->FileIO->dat
            # $return_vals[4]  join(
            #                      $gp->Data->col_sep,
            #                      @tal_nrgs{qw(emin emax)}
            #                  )
            # $return_vals[5]  $self->storage->{part}[0][$i]
            # $return_vals[6]  $self->storage->{max}[0][$i]
            # $return_vals[7]  $self->storage->{v_key_at_max}[0][$i]
            # $return_vals[8]  $self->storage->{v_val_at_max}[0][$i]
            #
            @return_vals =
                $t_tot_fluence->retrieve_tot_fluences(   # e.g.
                    $tar_of_int->flag,                   # wrcc
                    $phits->FileIO->varying_flag,        # vhgt
                    $phits->FileIO->fixed_flag,          # frad-fgap
                    $tally_flag,                         # cross-eng-w_exit
                    $tar_of_int->cell_props->{cell_id},  # 1
                    #------------------------------------#
                    $phits->Cmt->abbrs,                  # Hash ref for abbrs
                    [$prog_info_href, \&show_front_matter],
                );

            # For $arr_ref_to_cpu_times
            $_total_cpu_times_sums{sec}  = $return_vals[0] if $return_vals[0];
            $_total_cpu_times_sums{hour} = $return_vals[1] if $return_vals[1];
            $_total_cpu_times_sums{day}  = $return_vals[2] if $return_vals[2];

            # For $hash_max_flues
            #         {$tar_of_int->flag}
            #         {$phits->FileIO->varying_flag}
            #         {$tally_flag} <= Array reference
            for (my $i=3; $i<=$#return_vals; $i+=6) {  # Only one iteration
                # Assign the energy range to the data hash
                $tot_flues
                    {$phits->FileIO->subdir}   # Subdir name
                    {$return_vals[$i]}         # [3] Tally-specific data fname
                    {'emin_emax'}              # Key of the particle hash
                        = $return_vals[$i+1];  # [4] emin and emax

                # Assign the maximum total fluence value to the particle hash
                $tot_flues
                    {$phits->FileIO->subdir}   # Subdir name
                    {$return_vals[$i]}         # [3] Tally-specific data fname
                    {$return_vals[$i+2]}       # [5] Particle name
                    {'tot_flue'}               # Key of the particle hash
                        = $return_vals[$i+3];  # [6] Maximum total fluence: Val

                # Assign the dimension value to the particle hash
                $tot_flues
                    {$phits->FileIO->subdir}   # Subdir name
                    {$return_vals[$i]}         # [3] Tally-specific fname
                    {$return_vals[$i+2]}       # [5] Particle name
                    {$return_vals[$i+4]}       # Key of the particle hash ([7])
                        = $return_vals[$i+5];  # [8] Value of varying geom
            }

            # Fill in the array of maximum total fluences.
            push @{
                $hash_max_flues
                    {$tar_of_int->flag}
                    {$phits->FileIO->varying_flag}
                    {$tally_flag}
            },
                # Current value of the varying source parameter
                $phits->v_src_param->{curr},
                # Energy range
                $tot_flues
                    {$phits->FileIO->subdir}       # Subdir name
                    {$t_tot_fluence->FileIO->dat}  # [3] Tally-specific fname
                    {'emin_emax'},                 # Key of the particle hash
                # Electron maximum total fluence and the corresponding v-geom
                $tot_flues
                    {$phits->FileIO->subdir}
                    {$t_tot_fluence->FileIO->dat}
                    {'electron'}
                    {'tot_flue'},
                $tot_flues
                    {$phits->FileIO->subdir}
                    {$t_tot_fluence->FileIO->dat}
                    {'electron'}
                    {$return_vals[7]},  # [7] Name of varying geom
                # Photon maximum total fluence and the corresponding v-geom
                $tot_flues
                    {$phits->FileIO->subdir}
                    {$t_tot_fluence->FileIO->dat}
                    {'photon'}
                    {'tot_flue'},
                $tot_flues
                    {$phits->FileIO->subdir}
                    {$t_tot_fluence->FileIO->dat}
                    {'photon'}
                    {$return_vals[7]},
                # Neutron maximum total fluence and the corresponding v-geom
                $tot_flues
                    {$phits->FileIO->subdir}
                    {$t_tot_fluence->FileIO->dat}
                    {'neutron'}
                    {'tot_flue'},
                $tot_flues
                    {$phits->FileIO->subdir}
                    {$t_tot_fluence->FileIO->dat}
                    {'neutron'}
                    {$return_vals[7]};
            #+++++debugging+++++#
#            dump(\%tot_flues);
#            pause_shell(); If on, the next iter won't work owing to its STDIN
            #+++++++++++++++++++#

            #
            # Write the maximum total fluences and
            # the corresponding varying geometry
            # to data reduction report files.
            #
            reduce_data(
                {  # Settings
                    rpt_formats => $run_opts_href->{rpt_fmts},
                    rpt_path    => $run_opts_href->{rpt_path},
                    rpt_bname   => 'max_tot_flues'.(
                        $run_opts_href->{rpt_flag} ? (
                            $phits->FileIO->fname_sep.
                            $run_opts_href->{rpt_flag}
                        ) : ''
                    ).(
                        $phits->FileIO->fname_sep.     # -
                        $tar_of_int->flag.             # wrcc || w_rcc
                        $phits->FileIO->fname_sep.     # -
                        $phits->FileIO->varying_flag.  # vhgt || v_hgt
                        $phits->FileIO->fname_sep.
                        $tally_flag
                    ),
                    begin_msg => "collecting maximum total fluences...",
                    prog_info => $prog_info_href,
                    cmt_arr   => [],
                },
                {  # Columnar
                    size     => 8,  # Used for column size validation
                    heads    => [
                        sprintf("%s", $phits->v_src_param->{name}),
                        "emin     emax",
                        "max_elec_tot_flue",
                        "$v_geom at max_elec_tot_flue",
                        "max_phot_tot_flue",
                        "$v_geom at max_phot_tot_flue",
                        "max_neut_tot_flue",
                        "$v_geom at max_neut_tot_flue",
                    ],
                    subheads => [
                        sprintf("(%s)", $phits->v_src_param->{unit}),
                        "(MeV)",
                        "(cm^-2 source^-1)",
                        "(cm)",
                        "(cm^-2 source^-1)",
                        "(cm)",
                        "(cm^-2 source^-1)",
                        "(cm)",
                    ],
                    data_arr_ref =>
                        $hash_max_flues
                            {$tar_of_int->flag}
                            {$phits->FileIO->varying_flag}
                            {$tally_flag},
                    ragged_left_idx_multiples => [1..8],
                    freeze_panes => 'C4',  # Alt: {row => 3, col => 2}
                    space_bef    => {dat => " ", tex => " "},
                    heads_sep    => {dat => "|", csv => ","},
                    space_aft    => {dat => " ", tex => " "},
                    data_sep     => {dat => " ", csv => ","},
                }
            );
        }

        #
        # Write the currently known CPU times to data reduction report files.
        #
        state $arr_ref_to_cpu_times = [];
        push @{$arr_ref_to_cpu_times},
            $dir,
            $sub,
            $subsub,
            $_total_cpu_times_sums{sec},  # Filled by the foreach loop above
            $_total_cpu_times_sums{hour},
            $_total_cpu_times_sums{day};
        reduce_data(
            {  # Settings
                rpt_formats => $run_opts_href->{rpt_fmts},
                rpt_path    => $run_opts_href->{rpt_path},
                rpt_bname   => 'cputimes'.(
                    $run_opts_href->{rpt_flag} ? (
                        $phits->FileIO->fname_sep.
                        $run_opts_href->{rpt_flag}
                    ) : ''
                ),
                begin_msg => "collecting CPU time info...",
                prog_info => $prog_info_href,
                cmt_arr   => [],
            },
            {  # Columnar
                size     => 6,  # Used for column size validation
                heads    => [
                    "Dir",
                    "Subdir",
                    "Subsubdir",
                    "CPU time",
                    "CPU time",
                    "CPU time",
                ],
                subheads => [
                    "",
                    "",
                    "",
                    "(s)",
                    "(h)",
                    "(d)",
                ],
                data_arr_ref              => $arr_ref_to_cpu_times,
                sum_idx_multiples         => [3..5],  # Can be discrete,
                ragged_left_idx_multiples => [2..5],  # but must be increasing
                freeze_panes              => 'E4',    # {row => 3, col => 4}
                space_bef                 => {dat => " ", tex => " "},
                heads_sep                 => {dat => "|", csv => ","},
                space_aft                 => {dat => " ", tex => " "},
                data_sep                  => {dat => " ", csv => ","},
            }
        );
    }

    return;
}


sub phitar {
    # """phitar main routine"""
    if (@ARGV) {
        my %prog_info = (
            titl       => basename($0, '.pl'),
            expl       => 'A PHITS wrapper for targetry design',
            vers       => $VERSION,
            date_last  => $LAST,
            date_first => $FIRST,
            auth       => {
                name => 'Jaewoong Jang',
                mail => 'jangj@korea.ac.kr',
            },
        );
        my %cmd_opts = (  # Command-line opts
            default    => qr/-?-d\b/i,
            dump_src   => qr/-?-dump(?:_src)?\s*=\s*/i,
            rpt_subdir => qr/-?-(?:rpt_)?subdir\s*=\s*/i,
            rpt_fmts   => qr/-?-(?:rpt_)?fmts\s*=\s*/i,
            rpt_flag   => qr/-?-(?:rpt_)?flag\s*=\s*/i,
            nopause    => qr/-?-nopause\b/i,
        );
        my %run_opts = (  # Program run opts
            inp        => '',
            is_default => 0,
            rpt_path   => getcwd().'/'.'reports',
            rpt_fmts   => ['dat', 'xlsx'],
            rpt_flag   => '',
            is_nopause => 0,
        );

        # ARGV validation and parsing
        validate_argv(\@ARGV, \%cmd_opts);
        parse_argv(\@ARGV, \%cmd_opts, \%run_opts);

        # Notification - beginning
        show_front_matter(\%prog_info, 'prog', 'auth');
        printf(
            "%s version: %s (%s)\n",
            $My::Toolset::PACKNAME,
            $My::Toolset::VERSION,
            $My::Toolset::LAST,
        );
        printf(
            "%s version: %s (%s)\n\n",
            $My::Nuclear::PACKNAME,
            $My::Nuclear::VERSION,
            $My::Nuclear::LAST,
        );

        #
        # Preprocessing
        #

        # > Sets up parameters that are not directly related to
        #   simulation runs but must be correctly set.
        #   Examples include:
        #   > The 'flag' and 'cell_props' attributes of
        #     MonteCarloCell.pm and the 'flag' attribute of
        #     Tally.pm, all of which are must be populated
        #     for this program to run correctly.
        #   > Registration of PHITS input file keywords
        #   > Comment symbols of different simulation platforms
        init();

        # > Sets up the default simulation parameters.
        # > Overridden in parse_inp() via the user input.
        # > MUST be called as it sets some parameters that are not specified
        #   elsewhere including the user input.
        default_run_settings();

        # > Parse the user input.
        # > Must come AFTER default_run_settings()
        #   as the user input is intended to override
        #   default parameters according to user specifications.
        parse_inp(\%run_opts) if $run_opts{inp} and not $run_opts{is_default};

        # The routines populate_gaussian_nrg_cutoffs() and
        # determ_tally_emin_emax() below will be called again and "repeatedly"
        # in outer_iterator(), if the Gaussian energy distribution
        # has been set and if the center energy is to be varied.

        # > Populate the attribute of Gaussian energy cutoffs.
        populate_gaussian_nrg_cutoffs()
            if $phits->source->nrg_dist_of_int->{type}{val} == 2;

        # > Populate the attribute of free-form energy distribution.
        populate_free_form_nrg_dist()
            if $phits->source->nrg_dist_of_int->{type}{val} == 22;

        # > Determine the emin and emax of tallies.
        determ_tally_emin_emax();

        # > Populate the attributes of Monte Carlo cell properties.
        # > The cell materials designated by the user-input file
        #   are applied in this routine.
        populate_mc_cell_props();

        #
        # Main
        #
        outer_iterator(\%prog_info, \%run_opts);

        # Notification - end
        show_elapsed_real_time("\n");
        pause_shell()
            unless $run_opts{is_nopause};
    }

    system("perldoc \"$0\"") if not @ARGV;

    return;
}


phitar();
__END__

=head1 NAME

phitar - A PHITS wrapper for targetry design

=head1 SYNOPSIS

    perl phitar.pl [run_mode] [--rpt_subdir=dname] [--rpt_fmts=ext ...]
                   [--rpt_flag=str] [--nopause]

=head1 DESCRIPTION

    phitar is a PHITS wrapper written in Perl, intended for the design of
    bremsstrahlung converters and Mo targets. phitar can:
      - examine ranges of source and geomeric parameters
        according to user specifications
      - generate ANSYS MAPDL table and macro files
      - collect information from PHITS tally outputs and generate
        report files
      - collect information from PHITS general outputs and generate
        report files
      - modify ANGEL inputs and outputs
      - calculate yields and specific yields of Mo-99 and Au-196
      - convert ANGEL-generated .eps files to various image formats
      - generate animations using the converted rasters

=head1 OPTIONS

    run_mode
        file
            Input file specifying simulation conditions.
            Refer to 'args.phi' for the syntax.
        -d
            Run simulations with the default settings.
        --dump_src=<particle>
            electron
            photon
            neutron
            Run simulations using a dump source.
            (as of v1.03, particles entering a Mo target are used
            as the dump source)

    --rpt_subdir=dname (short: --subdir, default: reports)
        Name of subdirectory to which report files will be stored.

    --rpt_fmts=ext ... (short: --fmts, default: dat,xlsx)
        Output file formats. Multiple formats are separated by the comma (,).
        all
            All of the following ext's.
        dat
            Plain text
        tex
            LaTeX tabular environment
        csv
            comma-separated value
        xlsx
            Microsoft Excel 2007
        json
            JavaScript Object Notation
        yaml
            YAML

    --rpt_flag=str (short: -flag)
        The input str followed by an underscore is appended to
        the names of the following files:
        - maximum total fluences
        - cputimes
        Use this option when different materials are simulated
        in the same batch to prevent unintended overwriting.

    --nopause
        The shell will not be paused at the end of the program.
        Use it for a batch run.

=head1 EXAMPLES

    perl phitar.pl args.phi
    perl phitar.pl -d
    perl phitar.pl --dump=electron --rpt_flag=elec_dmp args.phi
    perl phitar.pl args.phi > phitar.log -nopause
    perl phitar.pl --rpt_flag=au args.phi
    perl phitar.pl --rpt_flag=moo3 args_moo3.phi

=head1 REQUIREMENTS

    Perl 5
        Moose, namespace::autoclean
        Text::CSV, Excel::Writer::XLSX, JSON, YAML
    PHITS, Ghostscript, Inkscape, ImageMagick, FFmpeg, gnuplot
    (optional) ANSYS MAPDL

=head1 SEE ALSO

L<phitar on GitHub|https://github.com/jangcom/phitar>

=head2 Utilities

=over 5

=item * L<excel2etype22 - Convert EXCEL-stored energy distribution data to PHITS e-type = 22 data|https://github.com/jangcom/phitar/tree/master/utils/excel2etype22/excel2etype22.py>

=item * L<xsconv - Convert the units of cross section variables|https://github.com/jangcom/phitar/tree/master/utils/xsconv/xsconv.py>

=item * L<xsaug - Augment cross section data|https://github.com/jangcom/phitar/tree/master/utils/xsaug/xsaug.py>

=item * L<joinyld - Join phitar yield files|https://github.com/jangcom/phitar/tree/master/utils/joinyld/joinyld.py>

=item * L<yld2datagen - Convert phitar yield files to a datagen input file|https://github.com/jangcom/phitar/tree/master/utils/yld2datagen/yld2datagen.py>

=back

=head1 AUTHOR

Jaewoong Jang <jangj@korea.ac.kr>

=head1 COPYRIGHT

Copyright (c) 2018-2020 Jaewoong Jang

=head1 LICENSE

This software is available under the MIT license;
the license information is found in 'LICENSE'.

=cut
