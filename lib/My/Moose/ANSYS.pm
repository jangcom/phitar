#
# Moose class for ANSYS MAPDL
#
# Copyright (c) 2018-2020 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package ANSYS;

use Moose;
use namespace::autoclean;

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.00';
our $LAST     = '2020-05-03';
our $FIRST    = '2018-08-18';

has 'Cmt' => (
    is      => 'ro',
    isa     => 'ANSYS::Cmt',
    lazy    => 1,
    default => sub { ANSYS::Cmt->new() },
);

has 'Ctrls' => (
    is      => 'ro',
    isa     => 'ANSYS::Ctrls',
    lazy    => 1,
    default => sub { ANSYS::Ctrls->new() },
);

has 'Data' => (
    is      => 'ro',
    isa     => 'ANSYS::Data',
    lazy    => 1,
    default => sub { ANSYS::Data->new() },
);

has 'FileIO' => (
    is      => 'ro',
    isa     => 'ANSYS::FileIO',
    lazy    => 1,
    default => sub { ANSYS::FileIO->new() },
);

has 'exe' => (
    is      => 'ro',
    isa     => 'Str',
    default => 'mapdl.exe',  # Path: \ansys\bin\winx64
    writer  => 'set_exe',
);

#
# APDL macro writing commands
#
has 'sects' => (
    traits  => ['Hash'],
    is      => 'rw',
    isa     => 'HashRef[ArrayRef]',
    default => sub { {} },
    handles => {
        clear_sects => 'clear',
    },
);

# Parameters
# Caution:
# As of ANSYS 18.2 (released in 2017), a parameter name must
# be no more than 32 characters. Some very old releases even
# have 8-character limits. To check the character length limit
# of your ANSYS installation, refer to "Guidelines for
# Parameter Names" of the ANSYS Help executable.
has 'params' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    default => sub { {} },
    handles => {
        set_params => 'set',
    },
);

# General commands
has 'commands' => (
    is      => 'ro',
    isa     => 'ANSYS::Commands',
    default => sub { ANSYS::Commands->new() },
);

# Entity indices
has 'entities' => (
    is      => 'ro',
    isa     => 'ANSYS::Entities',
    default => sub { ANSYS::Entities->new() },
);

# Processors
has 'processors' => (
    is      => 'ro',
    isa     => 'ANSYS::Processors',
    default => sub { ANSYS::Processors->new() },
);

# Preprocessor
has 'primitives' => (
    is      => 'ro',
    isa     => 'ANSYS::Primitives',
    default => sub { ANSYS::Primitives->new() },
);

has 'materials' => (
    is      => 'ro',
    isa     => 'ANSYS::Materials',
    default => sub { ANSYS::Materials->new() },
);

has 'meshing' => (
    is      => 'ro',
    isa     => 'ANSYS::Meshing',
    default => sub { ANSYS::Meshing->new() },
);

# Solution processor
has 'loads' => (
    is      => 'ro',
    isa     => 'ANSYS::Loads',
    default => sub { ANSYS::Loads->new() },
);

has 'ps_settings' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_ps_settings',
    handles => {
        set_ps_settings => 'set',
    },
);

sub _build_ps_settings {
    return {
        high_resol => 0,
    };
}

__PACKAGE__->meta->make_immutable;
1;


package ANSYS::Cmt;

use Moose;
use namespace::autoclean;
with 'My::Moose::Cmt';

__PACKAGE__->meta->make_immutable;
1;


package ANSYS::Ctrls;

use Moose;
use namespace::autoclean;
with 'My::Moose::Ctrls';

__PACKAGE__->meta->make_immutable;
1;


package ANSYS::Data;

use Moose;
use namespace::autoclean;
with 'My::Moose::Data';

# Additional attribute: Storage for ANGEL --> MAPDL table parameter conversion
has 'heat' => (
    traits  => ['Array'],
    is      => 'rw',
    isa     => 'ArrayRef[HashRef[HashRef]]',
    default => sub { [] },
    handles => {
        clear_heat => 'clear',
    },
);

__PACKAGE__->meta->make_immutable;
1;


package ANSYS::FileIO;

use Moose;
use namespace::autoclean;
with 'My::Moose::FileIO';

# Additional attribute: A storage for an MAPDL macro-of-macros
has 'macs' => (
    traits  => ['Array'],
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
    handles => {
        add_macs   => 'push',
        clear_macs => 'clear',
    },
);

__PACKAGE__->meta->make_immutable;
1;


package ANSYS::Commands;

use Moose;
use namespace::autoclean;

has 'title' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Str]',
    lazy    => 1,
    builder => '_build_title',
    handles => {
        set_title => 'set',
    },
);

sub _build_title {
    return {
        cmd   => '/title',
        title => 'phitar',
    };
}

has 'solve' => (
    is       => 'ro',
    isa      => 'HashRef[Str]',
    lazy     => 1,
    builder  => '_build_solve',
    init_arg => undef,
);

sub _build_solve {
    return {
        cmd => 'solve',
    };
}

has 'get' => (  # *get
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_get',
    handles => {
        set_get => 'set',
    },
);

sub _build_get {
    return {
        cmd    => '*get',
        par    => 'par',      # The name of the resulting parameter
        entity => 'active',   # Entity keyword. Valid keywords are
                              # ACTIVE, CMD, COMP, GRAPH,
                              # NODE, ELEM, KP, LINE, AREA, VOLU, etc.
        entnum => 0,          # The number or label for the entity.
                              # In some cases, a zero (or blank) ENTNUM
                              # represents all entities of the set.
        item1  => 'jobname',  # The name of a particular item
                              # for the given entity. 
        it1num => '',         # The number or label for Item1, if any.
        #-----------------------------------------------------------------
        # A second set of item labels and numbers
        # to further qualify the item for which data are to be retrieved.
        # Most items do not require this level of information.
        #-----------------------------------------------------------------
        item2  => '',
        it2num => '',
    };
}

has 'asel' => (  # Area selector
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_asel',
    handles => {
        set_asel => 'set',
    },
);

sub _build_asel {
    return {
        cmd  => 'asel',
        type => 's',     # Label identifying the type of select:
                         # S: Select a new set (default)
                         # R: Reselect a set from the current set
                         # A: Additionally select a set and extend
                         #    the current set.
                         # U: Unselect a set from the current set.
                         # ALL:  Restore the full set.
                         # NONE: Unselect the full set.
                         # INVE: Invert the current set.
                         # STAT: Display the current select status.
        #-----------------------------------------------------------
        # The following fields are used only with
        # Type = S, R, A, or U.
        #-----------------------------------------------------------
        item => 'area',  # Label identifying data. Defaults to AREA.
        comp => '',      # Component of the item (if required).
        vmin => 1,       # Minimum value of item range.
                         # Ranges are area numbers, coordinate values,
                         # attribute numbers, etc.
        vmax => 1,       # Maximum value of item range. VMAX defaults to VMIN.
        vinc => 1,       # Value increment within range.
                         # Used only with integer ranges. Defaults to 1.
        kswp => 0,       # Specifies whether only areas are to be selected:
                         # 0: Select areas only.
                         # 1: Select areas, as well as keypoints, lines, nodes,
                         # and elements associated with selected areas.
                         # Valid only with Type = S.
    };
}

has 'batch' => (
    is       => 'ro',
    isa      => 'HashRef[Str]',
    lazy     => 1,
    builder  => '_build_batch',
    init_arg => undef,
);

sub _build_batch {
    return {
        cmd => '/batch',
    };
}

has 'clear' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Str]',
    lazy    => 1,
    builder => '_build_clear',
    handles => {
        set_clear => 'set',
    },
);

sub _build_clear {
    return {
        cmd  => '/clear',
        read => 'nostart',  # File read option:
                            # START:   Reread start.ans file (default).
                            # NOSTART: Do not reread start.ans file.
    };
}

has 'rename' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_rename',
    handles => {
        set_rename => 'set',
    },
);

sub _build_rename {
    return {
        cmd     => '/rename',
        fname1  => 'fname1',  # The file to be renamed.
                              # You can also include an optional dir path
                              # as part of the specified file name; if not,
                              # the default file location is the working dir.
                              # File name defaults to the current Jobname.
        ext1    => 'ext1',    # Filename extension (eight-character maximum).
        unused1 => '',        # Unused field.
        fname2  => 'fname2',  # The new name for the file.
                              # Fname2 defaults to Fname1.
        ext2    => 'ext2',    # Filename extension (eight-character maximum).
                              # Ext2 defaults to Ext1.
        unused2 => '',        # Unused field.
        distkey => 0,         # Key that specifies whether the rename operation
                              # is performed on all processes in distributed
                              # parallel mode (Distributed ANSYS):
                              # 1 (on or yes) - The program performs the rename
                              # operation locally on each process.
                              # 2 (off or no) - The program performs the rename
                              # operation only on the master process (default).
    };
}

__PACKAGE__->meta->make_immutable;
1;


package ANSYS::Entities;

use Moose;
use namespace::autoclean;

has $_ => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
    handles => {
        'set_'.$_ => 'set',
    },
) for qw(
    node
    kp
    line
    area
    vol
    mat
    elem
);

__PACKAGE__->meta->make_immutable;
1;


package ANSYS::Processors;

use Moose;
use namespace::autoclean;

has 'pre' => (
    is       => 'ro',
    isa      => 'HashRef[Str]',
    lazy     => 1,
    builder  => '_build_pre',
    init_arg => undef,
);

sub _build_pre {
    return {
        begin => "!\n".
                 "! Begin Level --> Preprocessor\n".
                 "!\n".
                 '/prep7',
        end   => "!\n".
                 "! Preprocessor --> Begin Level\n".
                 "!\n".
                 'finish',
    };
}

has 'sol' => (
    is       => 'ro',
    isa      => 'HashRef[Str]',
    lazy     => 1,
    builder  => '_build_sol',
    init_arg => undef,
);

sub _build_sol {
    return {
        begin => "!\n".
                 "! Begin Level --> Solution processor\n".
                 "!\n".
                 '/solu',
        end   => "!\n".
                 "! Solution processor --> Begin Level\n".
                 "!\n".
                 'finish',
    };
}

has 'gen_post' => (
    is       => 'ro',
    isa      => 'HashRef[Str]',
    lazy     => 1,
    builder  => '_build_gen_post',
    init_arg => undef,
);

sub _build_gen_post {
    return {
        begin => "!\n".
                 "! Begin Level --> General postprocessor\n".
                 "!\n".
                 '/post1',
        end   => "!\n".
                 "! General postprocessor --> Begin Level\n".
                 "!\n".
                 'finish',
    };
}

__PACKAGE__->meta->make_immutable;
1;


package ANSYS::Primitives;

use Moose;
use namespace::autoclean;

has 'block' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_block',
    handles => {
        set_block => 'set',
    },
);

sub _build_block {
    return {
        cmd => 'block',
        x1  => 0.000,  # Starting x coordinate
        x2  => 0.010,  # Ending   x coordinate
        y1  => 0.000,  # Starting y coordinate
        y2  => 0.010,  # Ending   y coordinate
        z1  => 0.000,  # Starting z coordinate
        z2  => 0.010   # Ending   z coordinate
    };
}

has 'cylinder' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_cylinder',
    handles => {
        set_cylinder => 'set',
    },
);

sub _build_cylinder {
    return {
        cmd    => 'cylind',
        r1     => 0.010,  #            Inner radius
        r2     => 0.000,  # "Optional" outer radius
        z1     => 0.000,  # Starting z coordinate
        z2     => 0.003,  # Ending   z coordinate
        theta1 => 0,      # Starting azimuth angle
        theta2 => 360     # Ending   azimuth angle
    };
}

has 'cone' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_cone',
    handles => {
        set_cone => 'set',
    },
);

sub _build_cone {
    return {
        cmd    => 'cone',
        r1     => 0.0015,  # Bottom radius
        r2     => 0.0060,  # Top    radius
        z1     => 0.0045,  # Starting z coordinate
        z2     => 0.0145,  # Ending   z coordinate
        theta1 => 0,       # Starting azimuth angle
        theta2 => 360      # Ending   azimuth angle
    };
}

__PACKAGE__->meta->make_immutable;
1;


package ANSYS::Materials;

use Moose;
use namespace::autoclean;

has 'gconv' => (
    is       => 'ro',
    isa      => 'HashRef[Str]',
    lazy     => 1,
    builder  => '_build_gconv',
    init_arg => undef,
);

sub _build_gconv {
    return {
        begin => sprintf(
            "!%s\n".
            "! Bremsstrahlung converter\n".
            "!%s",
            ('-' x 69),
            ('-' x 69)
        ),
    };
}

has 'motar' => (
    is       => 'ro',
    isa      => 'HashRef[Str]',
    lazy     => 1,
    builder  => '_build_motar',
    init_arg => undef,
);

sub _build_motar {
    return {
        begin => sprintf(
            "!%s\n".
            "! Molybdenum target\n".
            "!%s",
            ('-' x 69),
            ('-' x 69)
        ),
    };
}

# Material properties
has 'mptemp' => (  # Temperature table
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_mptemp',
    handles => {
        set_mptemp => 'set',
    },
);

sub _build_mptemp {
    return {
        cmd  => 'mptemp',
        sloc => 1,  # Starting location in table for entering temperatures
        t1   => 0,
        t2   => 0,
        t3   => 0,
        t4   => 0,
        t5   => 0,
        t6   => 0,
    };
}

has 'mpdata' => (  # Thermal conductivity
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_mpdata',
    handles => {
        set_mpdata => 'set',
    },
);

sub _build_mpdata {
    return {
        cmd  => 'mpdata',
        lab  => 'kxx',  # kxx: Thermal conductivities (also kyy, kzz)
        mat  => 1,      # Mat ref num to be associated with the elem;
                        # defaults to 1 with zero or no material number.
        sloc => 1,      # Starting location in table for generating data;
                        # defaults to the last location filled + 1.
        c1   => 0,      # Property data values assigned to six locations
                        # starting with SLOC
        c2   => 0,
        c3   => 0,
        c4   => 0,
        c5   => 0,
        c6   => 0
    };
}

__PACKAGE__->meta->make_immutable;
1;


package ANSYS::Meshing;

use Moose;
use namespace::autoclean;

has 'et' => (  # Element type
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_et',
    handles => {
        set_et => 'set',
    },
);

sub _build_et {
    return {
        cmd   => 'et',
        itype => 1,          # Arbitrary local element type number;
                             # defaults to 1 + current maximum.
        ename => 'solid87',  # Element name (or number)
        kop1  => 0,          # KEYOPT values (1 through 6) for this element
        kop2  => 0,
        kop3  => 0,
        kop4  => 0,
        kop5  => 0,
        kop6  => 0,
        inopr => 0
    };
}

has 'smrtsize' => (  # Smart meshing
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_smrtsize',
    handles => {
        set_smrtsize => 'set',
    },
);

sub _build_smrtsize {
    return {
        cmd    => 'smrtsize',
        sizlvl => 1,     # Overall element size level for meshing;
                         # 1 (fine) to 10 (coarse).
        fac    => 1,     # Scaling factor applied to the computed default mesh
                         # sizing; defaults to 1 for h-elements (size level 6),
                         # which is medium. Values from 0.2 to 5.0 are allowed.
        expnd  => 0,     # Mesh expansion (or contraction) factor
        trans  => 2.0,   # Mesh transition factor;
                         # defaults to 2.0 for h-elements (size level 6).
        angl   => 22.5,  # Maximum spanned angle per lower-order element
                         # for curved lines; defaults to 22.5 degrees
                         # per element (size level 6).
        angh   => 30,    # Maximum spanned angle per higher-order element
                         # for curved lines; defaults to 30 degrees
                         # per element (size level 6).
        gratio => 1.5,   # Allowable growth ratio used for proximity checking;
                         # defaults to 1.5 for h-elements (size level 6).
        smhlc  => 'on',  # Small hole coarsening key,
                         # can be ON (default for size level 6) or OFF.
        smanc  => 'on',  # Small angle coarsening key,
                         # can be ON (default for all levels) or OFF.
        mxitr  => 4,     # Maximum number of sizing iterations;
                         # defaults to 4 for all levels.
        sprx   => 0      # Surface proximity refinement key, can be off;
                         # default to 0 for all levels.
    };
}

has 'mshape' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_mshape',
    handles => {
        set_mshape => 'set',
    },
);

sub _build_mshape {
    return {
        cmd       => 'mshape',
        key       => 1,    # Key indicating the element shape to be used:
                           # quadrilateral-shaped elements when Dimension = 2D
                           # hexahedral-shaped    elements when Dimension = 3D
        dimension => '3d'  # Specifies the dimension of the model to be meshed:
                           # 2D: 2-D model (area mesh)
                           # 3D: 3-D model (volume mesh)
    };
}

has 'mshkey' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_mshkey',
    handles => {
        set_mshkey => 'set',
    },
);

sub _build_mshkey {
    return {
        cmd => 'mshkey',
        key => 0,  # Key indicating the type of meshing to be used:
                   # 0: Use free meshing (the default)
                   # 1: Use mapped meshing.
                   # 2: Use mapped meshing if possible;
                   # otherwise, use free meshing. If you specify MSHKEY,2,
                   # SmartSizing will be inactive even while
                   # free meshing non-map-meshable areas.
    };
}

has 'attr_pointers' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[ArrayRef]',
    lazy    => 1,
    builder => '_build_attr_pointers',
    handles => {
        set_attr_pointers => 'set',
    },
);

sub _build_attr_pointers {
    return {
        type   => ['type',   1],  # TYPE,   ITYPE (D: 1)
        mat    => ['mat',    1],  # MAT,    MAT   (D: 1)
        real   => ['real',   1],  # REAL,   NSET  (D: 1)
        esys   => ['esys',   0],  # ESYS,   KCN   (D: 0)
        secnum => ['secnum', 1],  # SECNUM, SECID (D: 1)
    };
}

has 'vmesh' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_vmesh',
    handles => {
        set_vmesh => 'set',
    },
);

sub _build_vmesh {
    return {
        cmd  => 'vmesh',
        nv1  => 1,  # Mesh volumes from NV1 to NV2 (defaults to NV1)
                    # in steps of NINC (defaults to 1).
        nv2  => 2,
        ninc => 1,
    };
}

__PACKAGE__->meta->make_immutable;
1;


package ANSYS::Loads;

use Moose;
use namespace::autoclean;

has 'dim' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_dim',
    handles => {
        set_dim => 'set',
    },
);

sub _build_dim {
    return {
        cmd    => '*dim',
        par    => 'param',  # Name of parameter to be dimensioned
        type   => 'table',  # Array type:
                            # ARRAY, CHAR, TABLE, STRING
        imax   => 10,       # Extent of 1st dimension (row);   default = 1.
        jmax   => 10,       # Extent of 2nd dimension (col);   default = 1.
        kmax   => 5,        # Extent of 3rd dimension (plane); default = 1.
        var1   => 'x',      # Variable name for the 1st dimension (row)
        var2   => 'y',      # Variable name for the 2nd dimension (col)
        var3   => 'z',      # Variable name for the 3rd dimension (plane)
        csysid => 0,        # An integer corresponding to the coordinate
                            # system ID number; default = 0 (global Cartesian).
    };
}

has 'tread' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_tread',
    handles => {
        set_tread => 'set',
    },
);

sub _build_tread {
    return {
        cmd    => '*tread',
        par    => 'param',  # Table array parameter name
                            # as defined by the *DIM command
        fname  => 'fname',  # File name and directory path;
                            # has "NO" default.
                            # 248 characters maximum.
                            # An unspecified directory path defaults to
                            # the working directory.
        ext    => 'ans',    # Filename extension (eight-character maximum);
                            # also has "NO" default.
        unused => '',       # Unused field
        nskip  => 0,        # Number of comment lines at the beginning of
                            # the file being read that will be skipped
                            # during the reading; default = 0.
    };
}

has 'bfv' => (  # A body force load on a volume
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_bfv',
    handles => {
        set_bfv => 'set',
    },
);

sub _build_bfv {
    return {
        cmd   => 'bfv',
        volu  => 1,       # Volume to which body load applies.
                          #If ALL, apply to all selected volumes [VSEL].
        lab   => 'hgen',  # Valid body load label. Examples include:
                          # temp for structural - temperature,
                          # hgen for thermal    - heat generation rate, etc.
        #-----------------------------------------------------------
        # Value associated with the Lab item or a table name for
        # specifying tabular boundary conditions. Use only VAL1 for
        # TEMP, FLUE, HGEN, and CHRGD.
        #-----------------------------------------------------------
        val1  => '',
        val2  => '',
        val3  => '',
        phase => '',  # Phase angle in degrees associated with the JS label.
    };
}

has 'sfa' => (  # Surface loads on the selected areas
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_sfa',
    handles => {
        set_sfa => 'set',
    },
);

sub _build_sfa {
    return {
        cmd    => 'sfa',
        area   => 1,       # Area to which surface load applies.
                           # If ALL, apply load to all selected areas [ASEL]. 
        lkey   => '',      # Load key associated with surface load
                           # (defaults to 1).
                           # LKEY is ignored if the area is the face of
                           # a volume region meshed with volume elements.
        lab    => 'conv',  # Valid surface load label. Examples include:
                           # pres for structural - pressure,
                           # conv for thermal    - convection, etc.
        #-----------------------------------------------------------
        # Surface load value or table name reference for
        # specifying tabular boundary conditions.
        # If Lab = CONV, VALUE is typically the film coefficient
        # and VALUE2 (below) is typically the bulk temperature. 
        #-----------------------------------------------------------
        value  => 1e+04,
        value2 => 25,
    };
}

__PACKAGE__->meta->make_immutable;
1;