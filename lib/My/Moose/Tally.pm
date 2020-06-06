#
# Moose class for PHITS tallies
#
# Copyright (c) 2018-2020 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package Tally;

use Moose;
use namespace::autoclean;
use feature    qw(say);
use Carp       qw(croak);
use Data::Dump qw(dump);
use constant ARRAY => ref [];      # [] as an anonymous array
use constant HASH  => ref {};      # {} as an anonymous hash
use constant CODE  => ref sub {};  # sub {} as an anonymous sub

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.00';
our $LAST     = '2020-05-03';
our $FIRST    = '2018-08-18';

has 'Ctrls' => (
    is      => 'ro',
    isa     => 'Tally::Ctrls',
    lazy    => 1,
    default => sub { Tally::Ctrls->new() },
);

has 'FileIO' => (
    is      => 'ro',
    isa     => 'Tally::FileIO',
    lazy    => 1,
    default => sub { Tally::FileIO->new() },
);

# Tally counter
has 't_counter' => (
    traits  => ['Counter'],
    is      => 'ro',
    isa     => 'Num',
    default => 0,
    handles => {
        inc_t_counter   => 'inc',
        reset_t_counter => 'reset',
    },
);

#
# Tally option controls: Shared
#

# (i) Particles to be tallied
has 'particles_of_int' => (
    traits  => ['Array'],
    is      => 'rw',
    isa     => 'ArrayRef',
    lazy    => 1,
    builder => '_build_particles_of_int',
    handles => {
        uniq_particles_of_int => 'uniq',
    },
);

sub _build_particles_of_int {
    return [
        'electron',
        'photon',
        'neutron',
    ];
}

sub set_particles_of_int {  # My setter
    # """Overwrite and remove duplicates."""
    my $self = shift;
    @{$self->particles_of_int} = @_ if @_;
    @{$self->particles_of_int} = $self->uniq_particles_of_int;
    return;
}

has 'is_'.$_.'_of_int' => (
    is      => 'ro',
    isa     => 'Num',
    lazy    => 1,
    default => 0,
    writer  => 'set_is_'.$_.'_of_int',
) for qw(
    prot
    neut
    elec
    posi
    phot
);

# Check if particles have been set to be of interest.
after 'set_particles_of_int' => sub {
    my $self           = shift;
    my $is_prot_of_int =
    my $is_neut_of_int =
    my $is_elec_of_int =
    my $is_posi_of_int =
    my $is_phot_of_int = 0;

    $is_prot_of_int = grep /\bprot/i, @{$self->particles_of_int};
    $is_neut_of_int = grep /\bneut/i, @{$self->particles_of_int};
    $is_elec_of_int = grep /\belec/i, @{$self->particles_of_int};
    $is_posi_of_int = grep /\bposi/i, @{$self->particles_of_int};
    $is_phot_of_int = grep /\bphot/i, @{$self->particles_of_int};
    $self->set_is_prot_of_int($is_prot_of_int);
    $self->set_is_neut_of_int($is_neut_of_int);
    $self->set_is_elec_of_int($is_elec_of_int);
    $self->set_is_posi_of_int($is_posi_of_int);
    $self->set_is_phot_of_int($is_phot_of_int);
};

# (ii) PHITS meshing (not to be confused with the FEM meshing)
has 'mesh_ranges' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',  # Str for comment keys
    lazy    => 1,
    builder => '_build_mesh_ranges',
    handles => {
        set_mesh_ranges => 'set',
    },
);

sub _build_mesh_ranges {
    return {
        xmin => 0,
        xmax => 0,
        ymin => 0,
        ymax => 0,
        zmin => 0,
        zmax => 0,
        rmin => 0,
        rmax => 0,
        emin => 8.29,  # Threshold energy of Mo-100(g,n)Mo-99 in MeV
        emax => 35.0,  # Electron beam energy
    };
}

has 'mesh_shape' => (
    is       => 'ro',
    isa      => 'HashRef[Str]',
    lazy     => 1,
    builder  => '_build_mesh_shape',
    init_arg => undef,
);

sub _build_mesh_shape {
    return {
        xyz => 'xyz',
        rz  => 'r-z',
        reg => 'reg',
    };
}

has 'mesh_types' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Int]',
    lazy    => 1,
    builder => '_build_mesh_types',
    handles => {
        set_mesh_types => 'set',
    },
);

sub _build_mesh_types {
    return {
        #
        # In PHITS, a mesh is defined by
        #
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
        #
        x => 2,
        y => 2,
        z => 2,
        r => 2,
        e => 2,
    };
}

has 'mesh_sizes' => (  # Or fineness
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_mesh_sizes',
    handles => {
        set_mesh_sizes => 'set',
    },
);

sub _build_mesh_sizes {
    return {
        1 => 1,
        x => 200,
        y => 200,
        z => 200,
        r => 100,
        e => 100,  # Number of energy bins
    };
}

has 'offsets' => (  # xyz offsets of figures
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Int]',
    lazy    => 1,
    builder => '_build_offsets',
    handles => {
        set_offsets => 'set',
    },
);

sub _build_offsets {
    return {
        x => 2,
        y => 2,
        z => 2,
    };
}

# (iii) Unit
# > Tally-dependent
# > The unit command is available in "almost all" tallies,
#   but its effects vary from tally to tally.
has 'unit' => (
    is      => 'ro',
    isa     => 'Int',
    lazy    => 1,
    default => 1,
    writer  => 'set_unit',
);

# (iv) Factor
# > Multiplied to a tally quantity
has 'factor' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Num|Str]',
    lazy    => 1,
    builder => '_build_factor',
    handles => {
        set_factor => 'set',
    },
);

sub _build_factor {
    return {
        val => 1.0,
        cmt => '',
    };
}

# (v) Quantity to be tallied
# > Tally-dependent
# > The output command is available in "some" tallies,
#   but its effects vary from tally to tally.
has 'output' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => 'heat',
    writer  => 'set_output',
);

# (vi) Two-dimensional data layout
# [3(d)] ANGEL 2D figure
# [4]    Columnar data for the ang_to_mapdl_tab subroutine of PHITS.pm
has 'two_dim_type' => (
    is      => 'ro',
    isa     => 'Int',
    lazy    => 1,
    default => 3,
    writer  => 'set_two_dim_type',
);

# (vii) Gshow options
# [0]    None of below
# [1(d)] Geometric boundary
# [2]    Geometric boundary + Material name
# [3]    Geometric boundary + Cell name
# [4]    Geometric boundary + Lattice name
has 'gshow' => (
    is      => 'ro',
    isa     => 'Int',
    lazy    => 1,
    default => 1,
    writer  => 'set_gshow',
);

# (viii) .eps file generation
#
# [0(d)] Off
# [1]    On
# [2]    On with error bars when: [axis != xy, yz, xz, or rz]
has 'epsout' => (
    is      => 'ro',
    isa     => 'Int',
    lazy    => 1,
    default => 0,
    writer  => 'set_epsout',
);

# (viiii) .vtk file generation for ParaView
#
# [0(d)] Off
# [1]    On when: [mesh=xyz 'and' axis = xy, yz, or xz]
has 'vtkout' => (
    is      => 'ro',
    isa     => 'Int',
    lazy    => 1,
    default => 0,
    writer  => 'set_vtkout',
);

# (x) Scoring materials
has $_ => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => 'all',  # 'all' or the number of materials to be scored,
                       # followed by the material IDs separated by a space
    writer  => 'set_'.$_,
) for qw (
    material
    material_cutaway
);

# (xi) Cell boundary resolution factor
has 'cell_bnd' => (
    traits  => ['Hash'],
    is      => 'rw',
    isa     => 'HashRef[Num]',
    lazy    => 1,
    builder => '_build_cell_bnd',
    handles => {
        set_cell_bnd => 'set',
    },
);

sub _build_cell_bnd {
    return {
        resol => 1,
        width => 0.5,
        # T-3Dshow line parameter
        # Effective only when output == 1 || 3.
        # [0(d)] Material boundary + Surface boundary
        # [1]    Material boundary + Surface boundary + Cell boundary
        line  => 0,
    };
}

#
# Tally-specific options
#

# T-Cross, T-Time, and T-Product specific
has 'dump' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Str]',
    lazy    => 1,
    builder => '_build_dump',
    handles => {
        set_dump => 'set',
    },
);

sub _build_dump {
    return {
        suffix  => '_dmp',  # Suffixed by PHITS
        num_dat => -11,     # (-) ASCII, (+) binary
        dat     => "@{[1..9]}".' 18 19',
    }
}

# T-Heat-specific
# electron
# > Energies transferred from electrons are calculated using:
#   [0(d)] The kerma factor of photons
#   [1]    Ionization loss of electrons
# > Kerma is approximately equal to absorbed dose at low energies,
#   but becomes much larger at high energies, because
#   the energy escaping the volume in the form of bremsstrahlung
#   and fast electrons is not counted as absorbed dose.
# > Use the option 1, as the involved electron energy is large.
has 'electron' => (
    is      => 'ro',
    isa     => 'Int',
    lazy    => 1,
    default => 1,
    writer  => 'set_electron',
);

# T-3Dshow-specific
has 'origin' => (  # The origin of the object to be rendered
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Num]',
    lazy    => 1,
    builder => '_build_origin',
    handles => {
        set_origin => 'set',
    },
);

sub _build_origin {
    return {
        x  => 0,
        y  => 0,
        # z corresponds to a polar angle.
        z1 => 0.5,  # Left-to-right beam view
        z2 => 0.5,  # Right-to-left beam view
    };
}

has 'frame' => (  # Referred to as a window in the PHITS manual
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Num]',
    lazy    => 1,
    builder => '_build_frame',
    handles => {
        set_frame => 'set',
    },
);

sub _build_frame {
    return {
        width          => 5,
        height         => 5,
        distance       => 5,
        # Increase the numbers of meshes to reduce image loss.
        wdt_num_meshes => 500,
        hgt_num_meshes => 500,
        angle          => 0,
    };
}

has 'eye' => (  # The point of the observer
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Num]',
    lazy    => 1,
    builder => '_build_eye',
    handles => {
        set_eye => 'set',
    },
);

sub _build_eye {
    return {
        polar_angle1  => 70,
        polar_angle2  => -70,
        azimuth_angle => 0,
        distance      => 100,  # frame->{distance} * 20 (PHITS dflt: *10)
    };
}

has 'light' => (  # The point from which light is shone
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Num]',
    lazy    => 1,
    builder => '_build_light',
    handles => {
        set_light => 'set',
    },
);

sub _build_light {
    return {
        polar_angle1  => 70,
        polar_angle2  => -70,
        azimuth_angle => 0,
        distance      => 100,
        # Shadow level
        # [0(d)] No shadow
        # Recommended: 2
        shadow        => 2,
    };
}

has 'axis_info' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Str|Int]',
    lazy    => 1,
    builder => '_build_axis_info',
    handles => {
        set_axis => 'set',
    },
);

sub _build_axis_info {
    return {
        # Upper direction on a 2D plane
        to_sky    => '-y',
        # [0]    No coordinate frame
        # [1(d)] Small coordinate frame at the bottom left
        # [2]    Large coordinate frame at the center
        crd_frame => 1,
    };
}

#
# Elements of nested filename constituents
#

# For filenaming and constructing the commands of tally section beginning
has 'flag' => (
    # Required, but 'required => 1' have intentionally been removed
    # for the structural consistency of phitar. It is now populated
    # in the initialization() routine of phitar.
    is     => 'ro',
    isa    => 'Str',
    writer => 'set_flag',
);

has 'sect_begin' => (
    is     => 'ro',
    isa    => 'Str',
    writer => 'set_sect_begin',
);

#
# Steps of a tally filename construction
#
# The filenames of the tallies are defined based on their
# > axes (e.g. -xz, -xy, -eng),
# > targets of interest (e.g. -xy-w, -xy-mo, -eng-mo)
# > emax value (e.g. -xy-w_low_emax for tallying photoneutrons)
#
# Step 1
# Define axis-specific string attributes.
# e.g. xz_flag = '-xz'
#      xy_flag = '-xy'
# > Target-material-specific flags are newly defined
#   at around the beginning part of set_fnames().
# e.g. xy_bconv_flag = '-xy-w'
#
# Step 2
# Construct axis attributes which are the instantiations of Tally::Axis.
# > The attributes of Tally::Axis are then syntactically associated
#   with the axis attributes.
#   e.g. $self->xy_bconv->fname, where
#        xy_bconv is the attribute of Tally and
#        fname is the attribute of Tally::Axis defined within Tally.
#
# Step 3
# Define set_fnames() that is called from the main program and
# populates the following attributes of Tally::Axis:
# > name:     Used as a tally axis name
# > title:    Used as a tally title (shown in the .eps files)
# > flag:     Used for constructing a tally filename
# > err_flag: Used for constructing an error-tally filename
#
# A command like the following will define the filename of a tally:
# $self->xy_bconv->fname(               # e.g.
#     $backbone.                        # wrcc-vhgt0p33-frad1p00-fgap0p15
#     $self->FileIO->fname_sep.         # -
#     $self->xy_bconv->flag.            # track-xy-w
#     $self->FileIO->fname_ext_delim.   # .
#     $self->FileIO->fname_exts->{ang}  # ang
# );
# > Taken from the main program, $backbone depends on the variable geometry:
#   e.g. wrcc-vhgt0p33-frad1p00-fgap0p15  # 1st run
#        wrcc-vhgt0p34-frad1p00-fgap0p15  # 2nd run
#        wrcc-vhgt0p35-frad1p00-fgap0p15  # 3rd run
#        ...
# > If an axis is target-material-specific, its flag attribute is
#   newly defined before the set_fname() setter is called within set_fnames(),
#   for which $bconv->cell_mat or $motar->cell_mat will be used.
#   The variables $bconv->cell_mat and $motar->cell_mat are
#   passed to set_fnames() along with $backbone.
#   e.g. wrcc-vhgt0p33-frad1p00-fgap0p15-track-xy-w
#                                        ^^^^^ ... newly defined part
#        pt_rcc-vhgt0p33-frad1p00-fgap0p15-track-xy-pt
#                                         ^^^^^^ ... newly defined part
#        pt_rcc-vhgt0p33-frad1p00-fgap0p15-track-xy-moo3
#                                         ^^^^^^^^ ... newly defined part
# > In result, the filenames will be defined at each run of the loop like:
#   e.g. wrcc-vhgt0p33-frad1p00-fgap0p15-track-xy-w.ang  # 1st run
#        wrcc-vhgt0p34-frad1p00-fgap0p15-track-xy-w.ang  # 2nd run
#        wrcc-vhgt0p35-frad1p00-fgap0p15-track-xy-w.ang  # 3rd run
#        ...
#
my %axes = (  # (key) axis attribute, (val) flag for tally axis and filename
    xz        => 'xz',
    yz        => 'yz',
    xy        => 'xy',
    rz        => 'rz',
    nrg       => 'eng',
    reg       => 'reg',
    polar1    => 'polar1',
    polar1a   => 'polar1a',
    polar1b   => 'polar1b',
    polar2    => 'polar2',
    polar2a   => 'polar2a',
    polar2b   => 'polar2b',
    twodtype4 => 'twodtype4',
    # Below: Axis-specific flags will be defined in (2) of set_fnames().
    # Intact particles (before interacting with any material)
    nrg_intact          => 'eng',
    nrg_intact_low_emax => 'eng',
    # Bremsstrahlung converter
    # Will be suffixed by the material name
    xy_bconv                => 'xy',
    xy_bconv_mapdl          => 'xy',
    rz_bconv                => 'rz',
    rz_bconv_twodtype4      => 'rz',
    rz_bconv_ent            => 'rz',
    rz_bconv_exit           => 'rz',
    nrg_bconv               => 'eng',
    nrg_bconv_low_emax      => 'eng',
    nrg_bconv_ent           => 'eng',
    nrg_bconv_ent_low_emax  => 'eng',
    nrg_bconv_exit          => 'eng',
    nrg_bconv_exit_low_emax => 'eng',
    reg_bconv               => 'reg',
    # Molybdenum target
    # Will be suffixed by the material name
    xy_motar                => 'xy',
    xy_motar_mapdl          => 'xy',
    rz_motar                => 'rz',
    rz_motar_twodtype4      => 'rz',
    rz_motar_ent            => 'rz',
    rz_motar_exit           => 'rz',
    nrg_motar               => 'eng',
    nrg_motar_low_emax      => 'eng',
    nrg_motar_ent           => 'eng',
    nrg_motar_ent_low_emax  => 'eng',
    nrg_motar_ent_dump      => 'eng',
    nrg_motar_exit          => 'eng',
    nrg_motar_exit_low_emax => 'eng',
    reg_motar               => 'reg',
    # Flux monitors
    nrg_flux_mnt_up   => 'eng',
    nrg_flux_mnt_down => 'eng',
);

foreach my $k (keys %axes) {
    #
    # Step 1
    #
    has $k.'_flag' => (
        is      => 'ro',
        isa     => 'Str',
        default => '-'.$axes{$k},
        writer  => 'set_'.$k.'_flag',
    );

    #
    # Step 2
    #
    has $k => (
        is      => 'ro',
        isa     => 'Tally::Axis',
        default => sub { Tally::Axis->new() },
    );
}

my %nonaxis_flags = (
    'err'      => 'err',  # Will become $self->err_flag
    'low_emax' => 'low_emax',  # Low emax for tallying photoneutrons
    'ent'      => 'ent',
    'exit'     => 'exit',
    'up'       => 'up',
    'down'     => 'down',
);

has $_.'_flag' => (
    is      => 'ro',
    default => '_'.$nonaxis_flags{$_},
    writer  => 'set_'.$_,
) for keys %nonaxis_flags;


sub set_fnames {
    # """Filenaming step 3"""
    my(
        $self,
        $bconv_cell_mat,
        $motar_cell_mat,
        $flux_mnt_up_cell_mat,
        $flux_mnt_down_cell_mat,
        $t_cross_dump_particles_of_int,
        $backbone,
    )= @_;
    my($_sep, $_space)= ($self->FileIO->fname_sep, $self->FileIO->fname_space);

    #
    # (1) Construct the command of tally section beginning.
    #
    (my $self_flag = $self->flag) =~ s/(?<str>[a-zA-Z]+)/\u$+{str}/;
    $self_flag = "T-".$self_flag;
    $self->set_sect_begin(sprintf("[%s]", $self_flag));

    #
    # (2) Define axis-specific flags (see the step 1 explanation).
    #

    # Flags for intact particles
    my %_intact_specifics = (
        nrg_intact_flag => [
            $self->nrg_flag,
        ],
        nrg_intact_low_emax_flag  => [
            $self->nrg_flag,
            $self->low_emax_flag
        ],
    );
    foreach my $k (keys %_intact_specifics) {
        my $_setter = 'set_'.$k;

        $self->$_setter(                            # e.g.
            $_intact_specifics{$k}[0].              # -eng
            $_sep.'intact'.                         # -intact
            (
                $_intact_specifics{$k}[1] ?
                    $_intact_specifics{$k}[1] : ''  # _low_emax
            )
        );
    }

    # Flags for a bremsstrahlung converter
    my %_bconv_cell_mat_specifics = (
        # 1st arg: Base flag constructed at the step 1.         e.g. -xy
        # 2nd arg: String appended to the target material name. e.g. _ent
        xy_bconv_flag => [
            $self->xy_flag,
        ],
        # xy_bconv_mapdl is not newly defined.
        rz_bconv_flag => [
            $self->rz_flag,
        ],
        rz_bconv_twodtype4_flag => [
            $self->rz_flag,
            $self->twodtype4_flag
        ],
        rz_bconv_ent_flag => [
            $self->rz_flag,
            $self->ent_flag
        ],
        rz_bconv_exit_flag => [
            $self->rz_flag,
            $self->exit_flag
        ],
        nrg_bconv_flag => [
            $self->nrg_flag,
        ],
        nrg_bconv_low_emax_flag => [
            $self->nrg_flag,
            $self->low_emax_flag
        ],
        nrg_bconv_ent_flag => [
            $self->nrg_flag,
            $self->ent_flag
        ],
        nrg_bconv_ent_low_emax_flag  => [
            $self->nrg_flag,
            $self->ent_flag.$self->low_emax_flag
        ],
        nrg_bconv_exit_flag => [
            $self->nrg_flag,
            $self->exit_flag
        ],
        nrg_bconv_exit_low_emax_flag => [
            $self->nrg_flag,
            $self->exit_flag.$self->low_emax_flag
        ],
        reg_bconv_flag => [
            $self->reg_flag,
        ],
    );
    foreach my $k (keys %_bconv_cell_mat_specifics) {
        my $_setter = 'set_'.$k;

        $self->$_setter(                                    # e.g.
            $_bconv_cell_mat_specifics{$k}[0].              # -eng
            $_sep.$bconv_cell_mat.                          # -ta
            (
                $_bconv_cell_mat_specifics{$k}[1] ?
                    $_bconv_cell_mat_specifics{$k}[1] : ''  # _ent_neut
            )
        );
    }

    # Flags for molybdenum targets
    my %_motar_cell_mat_specifics = (
        xy_motar_flag => [
            $self->xy_flag,
        ],
        # xy_motar_mapdl is not newly defined.
        rz_motar_flag => [
            $self->rz_flag,
        ],
        rz_motar_twodtype4_flag => [
            $self->rz_flag,
            $self->twodtype4_flag
        ],
        rz_motar_ent_flag => [
            $self->rz_flag,
            $self->ent_flag
        ],
        rz_motar_exit_flag => [
            $self->rz_flag,
            $self->exit_flag
        ],
        nrg_motar_flag => [
            $self->nrg_flag,
        ],
        nrg_motar_low_emax_flag => [
            $self->nrg_flag,
            $self->low_emax_flag
        ],
        nrg_motar_ent_flag => [
            $self->nrg_flag,
            $self->ent_flag
        ],
        nrg_motar_ent_low_emax_flag => [
            $self->nrg_flag,
            $self->ent_flag.$self->low_emax_flag
        ],
        nrg_motar_ent_dump_flag => [
            $self->nrg_flag,
            $self->ent_flag.'_'.$t_cross_dump_particles_of_int
        ],
        nrg_motar_exit_flag => [
            $self->nrg_flag,
            $self->exit_flag
        ],
        nrg_motar_exit_low_emax_flag => [
            $self->nrg_flag,
            $self->exit_flag.$self->low_emax_flag
        ],
        reg_motar_flag => [
            $self->reg_flag,
        ],
    );
    foreach my $k (keys %_motar_cell_mat_specifics) {
        my $_setter = 'set_'.$k;

        $self->$_setter(                                    # e.g.
            $_motar_cell_mat_specifics{$k}[0].              # -eng
            $_sep.$motar_cell_mat.                          # -moo3
            (
                $_motar_cell_mat_specifics{$k}[1] ?
                    $_motar_cell_mat_specifics{$k}[1] : ''  # _low_emax
            )
        );
    }

    # Flags for flux monitors
    my %_flux_mnt_cell_mat_specifics = (
        nrg_flux_mnt_up_flag   => [$self->nrg_flag, $self->up_flag  ],
        nrg_flux_mnt_down_flag => [$self->nrg_flag, $self->down_flag],
    );
    foreach my $k (keys %_flux_mnt_cell_mat_specifics) {
        my $_setter            = 'set_'.$k;
        my $_flux_mnt_cell_mat = $k =~ /up/i ? $flux_mnt_up_cell_mat :
                                               $flux_mnt_down_cell_mat;

        $self->$_setter(                                       # e.g.
            $_flux_mnt_cell_mat_specifics{$k}[0].              # -eng
            $_sep.$_flux_mnt_cell_mat.                         # -au
            (
                $_flux_mnt_cell_mat_specifics{$k}[1] ?
                    $_flux_mnt_cell_mat_specifics{$k}[1] : ''  # _up
            )
        );
    }

    foreach my $k (keys %axes) {
        #
        # (3) Populate the following attributes, which are
        #     the attributes of Tally::Axis (see the step 2):
        #     > name:     Used as a tally axis name
        #     > title:    Used as a tally title (shown in the .eps files)
        #     > flag:     Used for constructing a tally filename
        #     > err_flag: Used for constructing an error-tally filename
        #
        my $_axis_flag = $k.'_flag';
        $self->$k->set_name(      # Tally axes
            $axes{$k}             # xz, yz, xy, rz, eng, reg
        );
        $self->$k->set_title(     # Tally titles
            $self_flag.           # e.g. T-Track (see (1))
            $_sep.                # -
            $axes{$k}             # xz, yz, xy, rz, reg
        );
        $self->$k->set_flag(      # Used for filenaming; e.g.
            $self->flag.          # track
            $self->$_axis_flag    # -xy-ta
        );
        $self->$k->set_err_flag(  # Used for filenaming; e.g.
            $self->flag.          # track
            $self->$_axis_flag.   # -xy-ta
            $self->err_flag       # _err
        );

        #
        # (4) Define filenames using the axis-specific flag defined in step 1
        #     or using the target-material-specific flag
        #     defined in substep (3).
        #
        $self->$k->set_fname(                 # e.g.
            $backbone.                        # wrcc-vhgt0p10-frad1p00-fgap0p15
            $_sep.                            # -
            $self->$k->flag.                  # track-xy-ta
            $self->FileIO->fname_ext_delim.   # .
            $self->FileIO->fname_exts->{ang}  # ang
        );
        $self->$k->set_err_fname(
            $backbone.
            $_sep.
            $self->$k->err_flag.              # track-xy-ta_err
            $self->FileIO->fname_ext_delim.
            $self->FileIO->fname_exts->{ang}
        );

        #
        # Override the flags and names of ANGEL files
        # which will be used to generate MAPDL table files.
        #
        if ($k =~ /xy_(bconv|motar)_mapdl/i) {
            # Shorten the backbone filename to conform to the maximum
            # length of an MAPDL variable, or 32 characters.
            my $_omissible = join $_sep, (split $_sep, $backbone)[-2, -1];
            (my $_backbone_mapdl = $backbone) =~ s/$_sep$_omissible//;

            $self->$k->set_flag(                        # e.g.
                $_sep.(                                 # -
                    $k =~ /bconv/i ? $bconv_cell_mat :  # ta
                                     $motar_cell_mat    # moo3
                )
            );
            $self->$k->set_bname(  # Used for $mapdl->set_params and fnames
                $_backbone_mapdl.  # wrcc-vhgt0p10
                $self->$k->flag    # -w
            );
            $self->$k->set_fname(                 # e.g.
                $self->$k->bname.                 # wrcc-vhgt0p10-w
                $self->FileIO->fname_ext_delim.   # .
                $self->FileIO->fname_exts->{ang}  # ang
            );
        }
    }

    return;
}

#
# Total fluences finder
#
has 'storage' => (
    is      => 'rw',
    isa     => 'HashRef[ArrayRef[ArrayRef]]',
    default => sub { {} },
);


sub init_storage_max {
    # """Initialize arrays nested to the key 'max' of
    # the hash-ref $self->storage."""
    my $self = shift;

    # Assign values to arrays nested to the $self->storage hash ref
    # to prevent the "use of uninitialized" warnings and
    # to correctly find maximum total fluences among tallied regions.
    #
    # $j: Number of tallied regions
    # $i: Number of tallied particles
    # Although the two maxima for $j (10) and $i (10) have been
    # set arbitrarily, they are probably sufficient in most cases.
    # e.g. You may not have more than 10 tally regions for one problem,
    #      and you will probably not tally more than 10 particles.
    for (my $j=0; $j<=10; $j++) {
        for (my $i=0; $i<=10; $i++) {
            # Below allows capturing even a "zero" total fluence as the
            # maximum one, and also prevents the "use of uninitialized value"
            # warning for neutron total fluences when the number of histories
            # is insufficient.
            $self->storage->{max}[$j][$i] = -1;
        }
    }

    return;
}


sub retrieve_tot_fluences {
    # """Retrieve the maximum total fluences and perform
    # data reduction for reporting."""
    my(
        $self,
        $tar_of_int_flag,     # Arg 1: e.g. wrcc
        $varying_flag,        # Arg 2: e.g. vhgt
        $fixed_flag,          # Arg 3: e.g. frad-fgap
        $tal_of_int,          # Arg 4: e.g. cross-eng-w_exit
        $tar_of_int_cell_id,  # Arg 5: e.g. 1
        #---------------------#
        $ref_to_hash,         # Arg 6: To be %abbrs
        $ref_to_fm_writing,   # Arg 7: (Optional) To be @fm_writing
        #---------------------#
    ) = @_;

    # Data type validation and deref: Arg 6
    croak "The 6th arg to [retrieve_tot_fluences] must be a hash ref!"
        unless ref $ref_to_hash eq HASH;
    my %abbrs = %$ref_to_hash;
    # Data type validation and deref: Arg 7
    # The arg 7 is "optional" and, if used, its first two elements must be:
    # \%prog_info         (hash ref)
    # \&show_front_matter (code ref)
    # If correct values are given, they will be used in prepending
    # the program information to the data reduction reporting file.
    if ($ref_to_fm_writing) {
        croak "The 7th arg to [retrieve_tot_fluences] must be an array ref!"
            unless ref $ref_to_fm_writing eq ARRAY;
        croak "The 1st element of the 7th arg to [retrieve_tot_fluences]".
              " must be a hash ref!"
            unless ref $ref_to_fm_writing->[0] eq HASH;
        croak "The 2nd element of the 7th arg to [retrieve_tot_fluences]".
              " must be a code ref!"
            unless ref $ref_to_fm_writing->[1] eq CODE;
    }

    # Instantiate other Moose classes for gnuplot data file writing.
    use gnuplot;
    use Phys;
    my $gp   = gnuplot->new();
    my $phys = Phys->new();
    $gp->Cmt->set_symb('#');
    $gp->Cmt->set_borders(
        leading_symb => $gp->Cmt->symb,
        border_symbs => ['=', '-'],
    );
    $gp->Data->set_col_sep(' ');
    $gp->Data->set_eof('#eof');

    # Notify the beginning.
    if ($self->Ctrls->is_first_run) {
        my $_sub_name = join('::', (caller(0))[0, 3]);
        my $_indent   = " " x length($_sub_name);
        say "";
        say $gp->Cmt->borders->{'='};
        printf(
            "%s [%s] retrieving total fluences and\n".
            "%s %s   writing to gnuplot data files...\n",
            $gp->Cmt->symb, $_sub_name,
            $gp->Cmt->symb, $_indent
        );
        say $gp->Cmt->borders->{'='};

        # Make the bool of first run false.
        # (initialized to '1' at the beginning of each inner iteration.)
        $self->Ctrls->set_is_first_run(0);
    }

    # For regexes
    my $varying_str   = $abbrs{varying}[1];
    my $fname_sep     = $self->FileIO->fname_sep;
    my $fname_space   = $self->FileIO->fname_space;

    # For information retrieval from a general output file
    my($v_key, $v_val);
    my $gen_out;
    my $len     = 0;
    my $len_arr = 0;
    my $conv    = '';
    my $maxcas  = 0;
    my $maxbch  = 0;
    my @total_cpu_times     = ();
    my %total_cpu_times_sum = (
        sec  => 0,
        hour => 0,
        day  => 0,
    );
    my $vol_sec_began = 0;
    my $vol_sec_ended = 0;
    my @volumes;
    my $tar_of_int_vol;

    # For information retrieval from a tally file
    my $reg;                # Tallied region index
    my %tal_nrgs;           # Tallied energy range
    my @tallied_particles;  # Tallied particles
    my $is_first_iter = 1;  # For headings writing

    # Define the name of the data reduction reporting file.
    $self->FileIO->set_dat(
        (                              # e.g.
            $tar_of_int_flag.          # wrcc
            $self->FileIO->fname_sep.  # -
            $varying_flag.             # vhgt
            $self->FileIO->fname_sep.  # -
            $self->flag.               # fluence
            $self->FileIO->fname_sep.  # -
            $tal_of_int                # cross-eng-w_exit
        ).
        $self->FileIO->fname_ext_delim.
        $self->FileIO->fname_exts->{dat}
    );

    # Glob and filter tally (ANGEL) and out files.
    my @ang_files = grep {  # Refer to 'my $backbone' of the main program.
        $_ =~ /
            $tar_of_int_flag
            $fname_sep
            $varying_flag
            .*  # - (bef 2018-12-21), _ (2018-12-21), '' (2018-12-23) all OK
            $tal_of_int
        /x
    } glob '*'.$self->FileIO->fname_exts->{ang};
    return if not @ang_files;

    my @out_files = grep {
        /
            $tar_of_int_flag
            $fname_sep
            $varying_flag
            .*
        /x
    } glob '*'.$self->FileIO->fname_exts->{out};

    #+++++debugging+++++#
#    say "ang files: [$_]" for @ang_files;
#    say "out files: [$_]" for @out_files;
    #+++++++++++++++++++#

    #
    # Examine the designated ANGEL input files.
    #
    open my $gp_dat_fh, '>:encoding(UTF-8)', $self->FileIO->dat;

    # (Optional) Prepend the program information.
    # $ref_to_fm_writing must be in the form of:
    # $ref_to_fm_writing           (array ref)
    #   ->[0]: \%prog_info         (hash ref)
    #   ->[1]: \&show_front_matter (code ref)
    if ($ref_to_fm_writing) {
        select($gp_dat_fh);
        $ref_to_fm_writing->[1]->(
            $ref_to_fm_writing->[0],  # Required argument (must be a hash ref)
            'prog',
            'auth',
            'timestamp',     # Print a timestamp as well.
            $gp->Cmt->symb,  # If given, a symbol is prepended to the lines.
        );
        select(STDOUT);
    }

    # *** Must be performed ***
    # Initialize arrays nested to the hash key 'max'.
    # (Caution: This is not emptying initialization!)
    $self->init_storage_max();

    my $last_v_val = '';
    foreach my $ang (@ang_files) {
        next if -d $ang;              # Skip directories.
        next if $ang =~ $self->flag;  # Skip the reporting file
                                      # generated by this subroutine.

        #
        # Extract the names (below referred to as keys) and values
        # of varying and fixed parameters from the ANGEL filenames.
        #

        # Varying
        ($v_key = $ang) =~ s/
            .*
            $varying_str $fname_space? (?<v_key>[a-zA-Z_]+)
            ($fname_sep|$fname_space)? (?<v_val>[0-9]+p?[0-9]*)
            .*
        /$+{v_key}/x;
        ($v_val = $ang) =~ s/
            .*
            $varying_str $fname_space? (?<v_key>[a-zA-Z_]+)
            ($fname_sep|$fname_space)? (?<v_val>[0-9]+p?[0-9]*)
            .*
        /$+{v_val}/x;

        #
        # Separate tallies having the same varying geometry and
        # different energy ranges. Without this, we would have:
        #--------------------------------------
        # Gap  | Volume   | E_{min}  E_{max}  | ...
        # (cm) | (cm^3)   | (MeV)             | ...
        #--------------------------------------
        # 0.00     1.036726   0.000000 37.00000 ...
        # 0.00     1.036726   0.000000 6.000000 ...
        # 0.50     1.036726   0.000000 37.00000 ...
        # 0.50     1.036726   0.000000 6.000000 ...
        #
        # But we need:
        #--------------------------------------
        # Gap  | Volume   | E_{min}  E_{max}  | ...
        # (cm) | (cm^3)   | (MeV)             | ...
        #--------------------------------------
        # 0.00     1.036726   0.000000 37.00000 ...
        # 0.50     1.036726   0.000000 37.00000 ...
        #
        # You can confirm this by commenting out the line 'next if ...' below.
        #
        next if $last_v_val and $last_v_val eq $v_val;
        $last_v_val = $v_val;

        #
        # Retrieve information from the general output file.
        #
        # The pieces of information to be retrieved is the ones
        # input by the inner_iterator subroutine, and therefore
        # they could have simply been passed to this sub.
        #
        # Nevertheless, the author opted for this seemingly
        # redundant way in order to make this sub independent from
        # the inner_iterator subroutine, so that when PHITS
        # outputs (i.e. ANGEL inputs) are already available,
        # this subroutine can work without rerunning PHITS.
        #
        foreach (@out_files) {
            $gen_out = $_ if /
                $tar_of_int_flag
                $fname_sep $varying_flag
                ($fname_sep|$fname_space)? $v_val\b
            /x;
        }

        #+++++debugging+++++#
#        say "\$ang is [$ang]";
#        say "\$v_key is [$v_key]";
#        say "\$v_val is [$v_val]";
#        say "\$gen_out is [$gen_out]";
        #+++++++++++++++++++#

        # Convert 'p' of the ANGEL filename to the decimal point
        # to write the $v_val to data reduction reporting files.
        $v_val =~ s/([0-9]+)p([0-9]+)/$1.$2/;

        open my $gen_out_fh, '<', $gen_out;
        foreach (<$gen_out_fh>) {
            # Volume of the target of interest
            # (a) Recognize the volume section.
            # (b) Capture the volumes.
            # (c) Take the volume of the target "in question".

            # (a)
            if (/\s*reg\s+vol/) {
                $vol_sec_began = 1;  # 0 --> 1
                next;                # Examine the next line.
            }
            # (b)
            if ($vol_sec_began == 1) {  # Works right after (a)
                # End of the volume section
                if (/\[/) {
                    $vol_sec_began = 0;
                    $vol_sec_ended = 1;
                    next;
                }
                push @volumes, $_;
                next;
            }
            # (c)
            if ($vol_sec_ended == 1) {
                foreach (@volumes) {
                    if (/^\s*\b$tar_of_int_cell_id\b/) {
                        ($tar_of_int_vol = $_) =~ s/
                            \s*$tar_of_int_cell_id\s+
                            (?<vol>[0-9]+[.]?[0-9]+)
                            \s*  # \s includes \r\n
                        /$+{vol}/ix;
                    }
                }
                $vol_sec_ended = 0;
            }

            # Number of histories
            if (/^\s* maxcas \s*=\s* [0-9eE\-+.]+ \s* [#]*/ix) {
                ($maxcas = $_) =~ s/
                    \s* maxcas \s*=\s*
                    (?<num>[0-9eE\-+.]+)
                    \s* [#]* .*
                    \s*
                /$+{num}/x;
            }
            if (/^\s* maxbch \s*=\s* [0-9eE\-+.]+ \s* [#]*/ix) {
                ($maxbch = $_) =~ s/
                    \s* maxbch \s*=\s*
                    (?<num>[0-9eE\-+.]+)
                    \s* [#]* .*
                    \s*
                /$+{num}/x;
            }

            # Total CPU time
            if (/^\s* total \s* cpu \s* time/ix) {
                push @total_cpu_times, $_;
                $total_cpu_times[-1] =~ s/
                    [a-zA-Z\s=]+(?<sec>[0-9]+[.]?[0-9]+)
                    \s*
                /$+{sec}/x;
            }
        }
        close $gen_out_fh;

        #
        # Retrieve tally information from each of the ANGEL files.
        #
        $reg = 0;  # Initialize the tallied region index.
        open my $ang_fh, '<', $ang;
        foreach (<$ang_fh>) {
            chomp();
            # Tallied energy range
            ($tal_nrgs{emin} = $_) =~ s/[^0-9.]//g if /^\s*emin\s*=/i;
            ($tal_nrgs{emax} = $_) =~ s/[^0-9.]//g if /^\s*emax\s*=/i;

            # Tallied particles
            @tallied_particles = split /\s+/ if /\s*part\s*=/;
            @tallied_particles =
                grep /\b(elec|posi|phot|neut|prot)/i, @tallied_particles;

            # Number of lines saying "sum over" == Number of tallied regions
            if (/sum over/) {
                # Particle names
                @{$self->storage->{part}[$reg]} = @tallied_particles;

                # regex: Process the line before its splitting.
                s/([#]|sum\s*over)//g;  # Remove nonnumerals
                s/^\s*//;               # Suppress leading spaces

                #
                # Nested list structure
                #
                # HashRef[Key         => Val[ArrayRef]  => ArrayRef]
                #         ANGEL fname => Tallied region => Tallied particle
                #                        Index             Index
                #                        [0] 1st reg    => [0] Electron
                #                                       => [1] Photon
                #                                       => [2] Neutron
                #                        [1] 2nd reg    => [0] Electron
                #                                       => [1] Photon
                #                                       => [2] Neutron
                #                        [2] 3rd reg    => [0] Electron
                #                                       => [1] Photon
                #                                       => [2] Neutron
                #
                # Split the columnar data and store into
                # the "tallied region arrays". For example:
                #
                # $t_tot_fluence->storage->{$ang}[0][0] = 2.9482E-01
                # $t_tot_fluence->storage->{$ang}[0][1] = 9.0655E-02
                # $t_tot_fluence->storage->{$ang}[0][2] = 0.0000E+00
                #
                # $t_tot_fluence->storage->{$ang}[1][0] = 2.9482E-01
                # $t_tot_fluence->storage->{$ang}[1][1] = 9.0655E-02
                # $t_tot_fluence->storage->{$ang}[1][2] = 9.0655E-02
                #
                # $t_tot_fluence->storage->{$ang}[2][0] = 0.0000
                # $t_tot_fluence->storage->{$ang}[2][1] = 0.0000
                # $t_tot_fluence->storage->{$ang}[2][2] = 0.0000
                #
                @{$self->storage->{$ang}[$reg]} = split /\s+/;

                # Memorize the max total fluences.
                for (
                    my $i=0;
                    # Iterate as many times as the number of tallied particles.
                    $i<=$#{$self->storage->{$ang}[$reg]};
                    $i++
                ) {
                    if (
                          $self->storage->{$ang}[$reg][$i]
                        > $self->storage->{max}[$reg][$i]
                    ) {
                        # The max total fluence
                        $self->storage->{max}[$reg][$i] =
                            $self->storage->{$ang}[$reg][$i];

                        # The file having the max total fluence
                        $self->storage->{max_owner}[$reg][$i] =
                            $ang;

                        # The varying parameter at the max total fluence
                        $self->storage->{v_key_at_max}[$reg][$i] =
                            $v_key;
                        $self->storage->{v_val_at_max}[$reg][$i] =
                            $v_val;
                    }
                }

                # Move the array index to the next tally region.
                $reg++;
            }
        }

        #+++++debugging+++++#
#        dump($self->storage);
#        print "Press enter to continue... ";
#        while(<STDIN>) { last; }
        #+++++++++++++++++++#

        #
        # Write to the data reduction reporting file.
        #
        select($gp_dat_fh);

        # Columnar headings: Written only once at the first iteration.
        if ($is_first_iter) {  # Initialized to 1 at its declaration.
            # Columnar headings
            $gp->Data->clear_col_heads();
            my $_nonabbr_v_key;
            foreach my $pair (values %abbrs) {
                $_nonabbr_v_key = $pair->[0] if $v_key =~ /$pair->[1]/i;
            }
            my @_capped_tallied_particles = map "\u$_", @tallied_particles;
            foreach (@_capped_tallied_particles) {
                if ($_ ne $_capped_tallied_particles[-1]) {
                    $_ = sprintf("%-10s", $_);
                }
            }
            $gp->Data->col_heads->[0] = sprintf(
                "%s %s",
                $gp->Cmt->symb,
                ("\u$_nonabbr_v_key" || "\u$v_key")
            );
            $gp->Data->col_heads->[1] = "Volume";
            $gp->Data->col_heads->[2] = "E_{min}  E_{max}";
            $gp->Data->col_heads->[3] = "@_capped_tallied_particles";
            $gp->Data->col_heads->[4] = sprintf(
                "%s * %s",
                ("\u$tallied_particles[1]" || "\u$v_key"),
                $gp->Data->col_heads->[1]
            );
            $gp->Data->col_heads->[5] = "NPS";
            $gp->Data->col_heads->[6] = "Total CPU time";

            # Columnar "sub"headings
            $gp->Data->clear_col_subheads();
            my $_lt = $phys->unit_delim->{lt};
            my $_rt = $phys->unit_delim->{rt};
            $gp->Data->col_subheads->[0] = sprintf(
                "%s %s", $gp->Cmt->symb, $_lt."cm".$_rt
            );
            $gp->Data->col_subheads->[1] = $_lt."cm^3".$_rt;
            $gp->Data->col_subheads->[2] = $_lt."MeV".$_rt;
            $gp->Data->col_subheads->[3] = $_lt."cm^-2 source^-1".$_rt;
            $gp->Data->col_subheads->[4] = $_lt."cm source^-1".$_rt;
            $gp->Data->col_subheads->[5] = $_lt."unitless".$_rt;
            $gp->Data->col_subheads->[6] = $_lt."sec".$_rt;

            #
            # Define widths for columnar alignment.
            # (1) Take the lengthier one between a heading and its subheading.
            # (2) Take the lengthier one between (1) and the columnar data.
            #

            # (1)
            for (my $i=0; $i<=$#{$gp->Data->col_heads}; $i++) {
                $gp->Data->col_widths->[$i] = length(
                    (
                          length($gp->Data->col_heads->[$i]   )
                        > length($gp->Data->col_subheads->[$i])
                    ) ? $gp->Data->col_heads->[$i] :
                        $gp->Data->col_subheads->[$i]
                );
            }

            # (2)
            # Fill a dummy data row.
            $gp->Data->clear_col_data();
            $gp->Data->col_data->[0] = $v_val;
            # *1 corrects the length.
            $gp->Data->col_data->[1] = $tar_of_int_vol * 1;
            $gp->Data->col_data->[2] =
                join($gp->Data->col_sep, @tal_nrgs{qw(emin emax)});
            $gp->Data->col_data->[3] = "@{$self->storage->{$ang}[0]}";
            $gp->Data->col_data->[4] =
                $self->storage->{$ang}[0][1] * $tar_of_int_vol;
            $gp->Data->col_data->[5] = sprintf("%.2e", $maxcas * $maxbch);
            $gp->Data->col_data->[6] = $total_cpu_times[-1];

            # Comparison
            # Caution: The use of length is a bit different
            #          from (1) above as the elements of
            #          @{$gp->Data->col_widths} are already numbers.
            for (my $i=0; $i<=$#{$gp->Data->col_widths}; $i++) {
                $gp->Data->col_widths->[$i] = (
                    $gp->Data->col_widths->[$i]
                    > length($gp->Data->col_data->[$i] // $gp->Data->nan)
                ) ? $gp->Data->col_widths->[$i] :
                    length($gp->Data->col_data->[$i] // $gp->Data->nan);
            }

            # Border construction
            foreach my $width (@{$gp->Data->col_widths}) {
                # Used for comment borders.
                $len += ($width + length(" ".$gp->Data->col_heads_sep." "));

                # Used for the sum of total CPU times
                # that will be appended at the end of the data writing.
                $len_arr += ($width + length(" ".$gp->Data->col_heads_sep." "))
                    unless $width == $gp->Data->col_widths->[-1];
            }
            $len     -= length($gp->Cmt->symb." ");
            $len_arr -= length($gp->Cmt->symb." ");

            $gp->Cmt->set_borders_len($len);

            say $gp->Cmt->borders->{'-'};  # Top rule

            # Headings writing
            for (my $i=0; $i<=$#{$gp->Data->col_heads}; $i++) {
                # Conversion construction
                $conv = '%-'.$gp->Data->col_widths->[$i].'s';

                # Column
                # Except the last item: Formatted
                # The last item:        "Not" formatted
                if ($i != $#{$gp->Data->col_heads}) {
                    printf("$conv", $gp->Data->col_heads->[$i]);
                }
                elsif ($i == $#{$gp->Data->col_heads}) {
                    print $gp->Data->col_heads->[$i];
                }

                # Columnar separator "or" linebreak
                print $i != $#{$gp->Data->col_heads} ?
                    " ".$gp->Data->col_heads_sep." " : "\n";
            }

            # Subheadings writing
            for (my $i=0; $i<=$#{$gp->Data->col_subheads}; $i++) {
                # Conversion construction
                $conv = '%-'.$gp->Data->col_widths->[$i].'s';

                # Column
                if ($i != $#{$gp->Data->col_subheads}) {
                    printf("$conv", $gp->Data->col_subheads->[$i]);
                }
                elsif ($i == $#{$gp->Data->col_subheads}) {
                    print $gp->Data->col_subheads->[$i];
                }

                # Columnar separator "or" linebreak
                print $i != $#{$gp->Data->col_subheads} ?
                    " ".$gp->Data->col_heads_sep." " : "\n";
            }

            say $gp->Cmt->borders->{'-'};  # Middle rule

            # Restore the border length.
            $gp->Cmt->set_borders_len(70);

            # Make this conditional not evaluated at the next iteration.
            $is_first_iter = 0;
        }

        #
        # Columnar data
        #

        # Filling
        $gp->Data->clear_col_data();
        $gp->Data->col_data->[0] = $v_val;
        # *1 corrects the length.
        $gp->Data->col_data->[1] = $tar_of_int_vol * 1;
        $gp->Data->col_data->[2] =
            join($gp->Data->col_sep, @tal_nrgs{qw(emin emax)});
        $gp->Data->col_data->[3] =
            join($gp->Data->col_sep, @{$self->storage->{$ang}[0]});
        $gp->Data->col_data->[4] =
            $self->storage->{$ang}[0][1] * $tar_of_int_vol;
        $gp->Data->col_data->[5] = sprintf("%.2e", $maxcas * $maxbch);
        $gp->Data->col_data->[6] = $total_cpu_times[-1];

        # Writing
        for (my $i=0; $i<=$#{$gp->Data->col_data}; $i++) {
            # Conversion construction
            $conv = '%-'.(
                  $gp->Data->col_widths->[$i]
                + length(" ".$gp->Data->col_heads_sep." ")
            ).'s';

            # Column
            #
            # Except the last item:
            # (i)  Formatted when the whitespace is the columnar separator.
            # (ii) "Not" formatted when the tap (\t) is the columnar separator.
            if ($i != $#{$gp->Data->col_data}) {
                if ($gp->Data->col_sep eq " ") {
                    printf(
                        "$conv",
                        $gp->Data->col_data->[$i] // $gp->Data->nan
                    );
                }
                elsif ($gp->Data->col_sep eq "\t") {
                    printf(
                        "%s%s",
                        ($gp->Data->col_data->[$i] // $gp->Data->nan),
                        $gp->Data->col_sep
                    );
                }
            }
            # The last item:
            # "Not" formatted and "no" separator is used.
            elsif ($i == $#{$gp->Data->col_data}) {
                print $gp->Data->col_data->[$i] // $gp->Data->nan;
            }
        }
        # Linebreak
        print "\n" if $ang ne $ang_files[-1];

        #
        # Append the sum of the total CPU times.
        # You may want to review the definition of the CPU time.
        #
        if ($ang eq $ang_files[-1]) {
            # (1) Obtain the sum of the total CPU times.
            $total_cpu_times_sum{sec} += $_ for @total_cpu_times;
            $total_cpu_times_sum{hour} = $total_cpu_times_sum{sec} / 3600;
            $total_cpu_times_sum{day}  = $total_cpu_times_sum{hour} / 24;
            $_ = sprintf("%.2f", $_) for values %total_cpu_times_sum;

            # (2) Construct a comment arrow and string in an aligned manner.
            my $sum_lab = "Sum: ";
            my $sum_str = sprintf(
                "%s%.2f",
                $sum_lab,
                $total_cpu_times_sum{sec}
            );
            my $sum_arrowhead = ">";
            my $sum_arrow     = sprintf(
                "%s%s%s",
                $gp->Cmt->symb,
                (
                    '-' x (
                        length(' ')
                        + $len_arr
                        - length($sum_arrowhead)
                        - length($sum_str)
                        + length($total_cpu_times[-1])
                    )
                ),
                $sum_arrowhead
            );
            my $sum_blank = sprintf(
                "%s%s",
                $gp->Cmt->symb,
                (' ' x (length($sum_arrow) - length($gp->Cmt->symb)))
            );

            # In second
            print "\n$sum_arrow$sum_str seconds";

            # In hour
            printf(
                "\n%s%s%.2f hours",
                $sum_blank,
                ' ' x (
                      length($sum_lab)
                    + length($total_cpu_times_sum{sec})
                    - length($total_cpu_times_sum{hour})
                ),
                $total_cpu_times_sum{hour}
            );

            # In day
            printf(
                "\n%s%s%.2f days",
                $sum_blank,
                ' ' x (
                      length($sum_lab)
                    + length($total_cpu_times_sum{sec})
                    - length($total_cpu_times_sum{day})
                ),
                $total_cpu_times_sum{day}
            );
        }

        select(STDOUT);
        close $ang_fh;
    }
    close $gp_dat_fh;

    #
    # Append the max total fluences and the owners to the reporting file.
    #
    open $gp_dat_fh, '>>:encoding(UTF-8)', $self->FileIO->dat;
    select($gp_dat_fh);

    # Header
    print "\n\n";
    say $gp->Cmt->borders->{'='};
    printf(
        "%s For [%s] and [%s],\n",
        $gp->Cmt->symb,
        $tar_of_int_flag,
        $varying_flag
    );
    printf(
        "%s the maximum total fluences at [%s] are:\n",
        $gp->Cmt->symb,
        $tal_of_int
    );
    say $gp->Cmt->borders->{'='};

    # Construct conversions.
    my %convs = (
        part          => [],
        max       => [],
        max_owner => [],
    );
    for (my $j=0; $j<=($reg-1); $j++) {
        # Initialization
        $convs{$_}[$j] = '' for keys %convs;

        # Take the lengthiest strings.
        foreach (keys %convs) {
            for (my $i=0; $i<=(@tallied_particles - 1); $i++) {
                if (
                      length($self->storage->{$_}[$j][$i])
                    > length($convs{$_}[$j])
                ) {
                    $convs{$_}[$j] = $self->storage->{$_}[$j][$i];
                }
            }
        }

        # Lengthiest strings --> left-aligning conversions
        $convs{$_}[$j] = '%-'.length($convs{$_}[$j]).'s' for keys %convs;
    }

    # Iterate as many times as the number of tallied "regions".
    for (my $j=0; $j<=($reg-1); $j++) {
        say $gp->Cmt->borders->{'-'};
        printf("%s Tallied region [%d]\n", $gp->Cmt->symb, $j);
        say $gp->Cmt->borders->{'-'};

        # Iterate as many times as the number of tallied "particles".
        for (my $i=0; $i<=(@tallied_particles - 1); $i++) {
            printf(
                "%s".
                " \[$convs{part}[$j]\]:".
                " $convs{max}[$j]".
                " <= \[$convs{max_owner}[$j]\]\n",
                $gp->Cmt->symb,
                $self->storage->{part}[$j][$i],
                $self->storage->{max}[$j][$i],
                $self->storage->{max_owner}[$j][$i]
            );
        }
    }

    select(STDOUT);
    close $gp_dat_fh;

    #
    # Append the mark of eof.
    #
    open $gp_dat_fh, '>>:encoding(UTF-8)', $self->FileIO->dat;
    print $gp_dat_fh $gp->Data->eof;
    close $gp_dat_fh;

    # Notify the file generation.
    printf("[%s] generated.\n", $self->FileIO->dat);

    #
    # Return values
    #
    my @_return_vals = ();  # Used by phitar::main
    push @_return_vals, map { sprintf("%.2f", $_) } ( 
        $total_cpu_times_sum{sec},   # $_return_vals[0]
        $total_cpu_times_sum{hour},  # $_return_vals[1]
        $total_cpu_times_sum{day}    # $_return_vals[2]
    );
    for (my $i=0; $i<=(@tallied_particles - 1); $i++) {
        push @_return_vals,
            $self->FileIO->dat,                    # $_return_vals[3]
            join(                                  # $_return_vals[4]
                $gp->Data->col_sep,
                @tal_nrgs{qw(emin emax)}
            ),
            $self->storage->{part}[0][$i],          # $_return_vals[5]
            $self->storage->{max}[0][$i],           # $_return_vals[6]
            $self->storage->{v_key_at_max}[0][$i],  # $_return_vals[7]
            $self->storage->{v_val_at_max}[0][$i];  # $_return_vals[8]
    }
    return @_return_vals;
}

__PACKAGE__->meta->make_immutable;
1;


package Tally::Ctrls;

use Moose;
use namespace::autoclean;
with 'My::Moose::Ctrls';

# Additional switches
my %_additional_switches = (
    shortname  => 'off',
    err_switch => 'off',
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


package Tally::FileIO;

use Moose;
use namespace::autoclean;
with 'My::Moose::FileIO';

__PACKAGE__->meta->make_immutable;
1;


package Tally::Axis;

use Moose;
use namespace::autoclean;

has $_ => (
    is     => 'ro',
    isa    => 'Str',
    writer => 'set_'.$_,
) for qw(
    title
    angel
    angel_mo
    sangel
    sangel_mo
    x_txt
    y_txt
    z_txt

    name
    flag
    err_flag
    bname
    fname
    err_fname
);

__PACKAGE__->meta->make_immutable;
1;