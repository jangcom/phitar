#
# Moose class for PHITS
#
# Copyright (c) 2018-2020 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package PHITS;

use Moose;
use Moose::Util::TypeConstraints;
use My::Moose::gnuplot;
use namespace::autoclean;
use autodie;
use feature qw(say);
use File::Copy qw(copy);

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.00';
our $LAST     = '2020-06-13';
our $FIRST    = '2018-08-19';

has 'Cmt' => (
    is      => 'ro',
    isa     => 'PHITS::Cmt',
    lazy    => 1,
    default => sub { PHITS::Cmt->new() },
);

has 'Ctrls' => (
    is      => 'ro',
    isa     => 'PHITS::Ctrls',
    lazy    => 1,
    default => sub { PHITS::Ctrls->new() },
);

has 'Data' => (
    is      => 'ro',
    isa     => 'PHITS::Data',
    lazy    => 1,
    default => sub { PHITS::Data->new() },
);

has 'FileIO' => (
    is      => 'ro',
    isa     => 'PHITS::FileIO',
    lazy    => 1,
    default => sub { PHITS::FileIO->new() },
);

has 'source' => (  # Source particle
    is      => 'ro',
    isa     => 'PHITS::Source',
    lazy    => 1,
    default => sub { PHITS::Source->new() },
);

has 'exe' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => 'phits.bat',  # MSWin
    writer  => 'set_exe',
);

# Cwd::cwd delegate attribute
has 'cwd' => (
    is       => 'ro',
    isa      => 'Str',
    default  => Cwd::getcwd(),
    init_arg => undef,
);

# Hash ref attributes
my %_hash_refs = (  # (key) attribute => (val) default
    v_src_param        => sub { {} },
    v_geom_param       => sub { {} },
    curr_src_nrg_dist  => sub { {} },
    curr_src_spat_dist => sub { {} },
    constraint_args    => sub { {} },
    ang_strs           => sub {  # New ANGEL strings for part fluence and flux
        {
            xlab => {
                key => 'x',
                old => '',
                new => '',
            },
            ylab => {
                key => 'y',
                old => '',
                new => '',
            },
            cluster_plot => {
                min => {key => 'cmin', const => 'c3'},
                max => {key => 'cmax', const => 'c4'},
            },
            mc_fluence =>
                'Monte Carlo fluence (cm^{$-$2} source^{$-$1})',
            mc_fluence_per_mev =>
                'Monte Carlo fluence (cm^{$-$2} MeV^{$-$1} source^{$-$1})',
            mc_heat_gy => 'Monte Carlo heat (Gy source^{$-$1})',
            mc_heat_mev_per_cm3 =>
                'Monte Carlo heat (MeV cm^{$-$3} source^{$-$1})',
            mc_heat_j_per_cm3 =>
                'Monte Carlo heat (J cm^{$-$3} source^{$-$1})',
            mc_heat_mev =>
                'Monte Carlo heat (MeV source^{$-$1})',
            mc_heat_j =>
                'Monte Carlo heat (J source^{$-$1})',
            rel_err          => 'Relative error',  # <--Relative Error
            flux             => 'Flux (cm^{$-$2} s^{$-$1})',
            flux_per_mev     => 'Flux (cm^{$-$2} s^{$-$1} MeV^{$-$1})',
            heat_gy          => 'Heat (Gy s^{$-$1})',
            heat_mev_per_cm3 => 'Heat (MeV cm^{$-$3} s^{$-$1})',
            heat_mev         => 'Heat (MeV s^{$-$1})',
        };
    },
    consts    => sub { {} },  # User-defined constants (unused as of v1.01)
    params    => sub { {} },  # The parameters section
    sects     => sub { {} },  # Input file sections
    retrieved => sub { {} },  # Info retrieved from a summary file (.out)
);

has $_ => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    default => $_hash_refs{$_},
    handles => {
        'set_'.$_   => 'set',
        'clear_'.$_ => 'clear',
    },
) for keys %_hash_refs;

# Array ref attributes
my @_arr_refs = qw(
    ang_fnames
);

has $_ => (
    traits  => ['Array'],
    is      => 'rw',
    isa     => 'ArrayRef',
    default => sub { [] },
    handles => {
        'add_'.$_   => 'push',
        'clear_'.$_ => 'clear',
    },
) for @_arr_refs;

# ANGEL orientation
my %_orientations = map { $_ => 1 } qw(
    land
    port
    slnd
);

subtype 'My::Moose::PHITS::Orientations'
    => as 'Str'
    => where { exists $_orientations{$_} }
    => message {
        printf(
            "\n\n%s\n[%s] is not an allowed value.".
            "\nPlease input one of these: [%s]\n%s\n\n",
            ('-' x 70), $_,
            join(', ', sort keys %_orientations), ('-' x 70),
        )
    };

has 'orientation' => (
    is      => 'ro',
    isa     => 'My::Moose::PHITS::Orientations',
    lazy    => 1,
    default => 'slnd',
    writer  => 'set_orientation',
);

# ANGEL dimension units
my %_dim_units = map { $_ => 1 } qw(
    um
    mm
    cm
);

subtype 'My::Moose::PHITS::DimUnits'
    => as 'Str'
    => where { exists $_dim_units{$_} }
    => message {
        printf(
            "\n\n%s\n[%s] is not an allowed value.".
            "\nPlease input one of these: [%s]\n%s\n\n",
            ('-' x 70), $_,
            join(', ', sort keys %_dim_units), ('-' x 70),
        )
    };

has 'dim_unit' => (
    is      => 'ro',
    isa     => 'My::Moose::PHITS::DimUnits',
    lazy    => 1,
    default => 'cm',
    writer  => 'set_dim_unit',
);

# ANGEL cluster plot boundaries for T-Track and T-Heat
my %_cmin_cmax = (  # (key) attribute => (val) default
    cmin_track => 1e-3,  # [t_track.unit==1] 1e-3, [t_track.unit==2] 5e-5
    cmax_track => 1e+0,  # [t_track.unit==1] 1e+1, [t_track.unit==2] 5e-3
    cmin_heat  => 1e-1,
    cmax_heat  => 1e+2,
);

has $_ => (
    is      => 'ro',
    isa     => 'Num',
    lazy    => 1,
    default => $_cmin_cmax{$_},
    writer  => 'set_'.$_,
) for keys %_cmin_cmax;


sub ang_to_mapdl_tab {
    # """Convert a tally file calculated by PHITS in ANGEL format
    # to an ANSYS MAPDL table parameter file."""
    my(
        $self,
        @ang_fnames,
    ) = @_;

    my($newpage_idx, $is_first_newpage);
    my($plane_line, @plane_line_elem);
    my($row_idx, $col_idx, $heat);  # Temporary variables
    my $ang_ext = $self->FileIO->fname_exts->{ang};  # For a regex

    # Instantiate the ANSYS class.
    use ANSYS;
    my $mapdl_tab = ANSYS->new();
    $mapdl_tab->Cmt->set_symb('!');
#    $mapdl_tab->Data->set_col_sep(' ');
#    $mapdl_tab->Data->set_plane_sep("\n");
    $mapdl_tab->Cmt->set_borders(
        leading_symb => $mapdl_tab->Cmt->symb,
        border_symbs => ['=', '-'],
    );

    # Notify the beginning of the routine.
    say "";
    say $mapdl_tab->Cmt->borders->{'='};
    printf(
        "%s [%s] converting PHITS .ang to MAPDL .tab...\n",
        $mapdl_tab->Cmt->symb,
        join('::', (caller(0))[0, 3])
    );
    say $mapdl_tab->Cmt->borders->{'='};

    # Iterate over the ANGEL files designated.
    foreach my $ang (@ang_fnames) {
        next if not -e $ang;

        # Initializations
        $newpage_idx      = 0;
        $is_first_newpage = 0;
        @{$mapdl_tab->Data->row_idx->[$newpage_idx]} = ();
        @{$mapdl_tab->Data->col_idx->[$newpage_idx]} = ();
        $mapdl_tab->Data->heat->[$newpage_idx]       = ();

        # Read in a tally (ANGEL) file.
        open my $ang_fh, '<', $ang;
        foreach (<$ang_fh>) {
            # Increase the newpage index (from the 2nd newpage onward).
            if (/^\s*newpage/i) {
                $newpage_idx++        if     $is_first_newpage;
                $is_first_newpage = 1 if not $is_first_newpage;  # 0: Init val
            }

            # Capture the z range.
            if (/\s*[#]*\s* z \s*=\s*[(]/ix) {
                ($plane_line = $_) =~
                    s/
                        \s*[#]*\s* z \s*=\s*[(]\s*
                        (?<num1>[0-9]+[.]?[0-9]+E?[+-]?[0-9]+)\s*-\s*
                        (?<num2>[0-9]+[.]?[0-9]+E?[+-]?[0-9]+)\s*[)]
                    /$+{num1} $+{num2}/ix;
                @plane_line_elem = split /\s+/, $plane_line;

                # Newpage index --> Plane index
                $mapdl_tab->Data->plane_idx->[$newpage_idx] =
                    $plane_line_elem[0]
                    + (($plane_line_elem[1] - $plane_line_elem[0]) / 2);
                # cm^2 --> m^2
                $mapdl_tab->Data->plane_idx->[$newpage_idx] *= 1e-02;

                # Convert to scientific notation.
                # %.3E: ANGEL
                # E+001 (Perl) --> E+01 (ANGEL)
                $mapdl_tab->Data->plane_idx->[$newpage_idx] = sprintf(
                    "%.3E",
                    $mapdl_tab->Data->plane_idx->[$newpage_idx]
                );
                $mapdl_tab->Data->plane_idx->[$newpage_idx] =~
                    s/e[+-]\K0([\d]{2})/$1/i;
            }

            # Assign row and column indices and
            # store heat with the indices being hash keys.
            if (
                /
                    ^\s+
                    -?[0-9]+[.][0-9]+E[+-]?[0-9]+\s+  # <= Spliced [0] below
                    -?[0-9]+[.][0-9]+E[+-]?[0-9]+\s+  # <= Spliced [1] below
                      [0-9]+[.][0-9]+E[+-]?[0-9]+\s+  # <= Spliced [2] below
                      [0-9]+[.][0-9]+
                /x
            ) {
                # Suppress leading spaces.
                s/^\s+//;

                #
                # Take the index, convert to m^2,
                # and convert to scientific notation.
                #

                # Row
                $row_idx = (split /\s+/, $_)[0] * 1e-02;  # cm^2 --> m^2
                $row_idx = sprintf("%.3E", $row_idx);     # %.3E: ANGEL
                $row_idx =~ s/e[+-]\K0([\d]{2})/$1/i;

                # Column
                $col_idx = (split /\s+/, $_)[1] * 1e-02;
                $col_idx = sprintf("%.3E", $col_idx);
                $col_idx =~ s/e[+-]\K0([\d]{2})/$1/i;

                # Heat (take it as is)
                $heat    = (split /\s+/, $_)[2];

                #
                # Store the indices and heat.
                #
                push @{$mapdl_tab->Data->row_idx->[$newpage_idx]}, $row_idx;
                push @{$mapdl_tab->Data->col_idx->[$newpage_idx]}, $col_idx;
                $mapdl_tab->Data->heat->[$newpage_idx]->{$row_idx}{$col_idx} =
                    $heat;
            }
        }
        close $ang_fh;

        #
        # Write to an MAPDL macro file.
        #

        # Define a filename.
        (my $_bname = $ang) =~ s/(?<bname>[\w-]+)[.]$ang_ext$/$+{bname}/i;
        $mapdl_tab->FileIO->set_dat(
            $_bname.
            $mapdl_tab->FileIO->fname_ext_delim.
            $mapdl_tab->FileIO->fname_exts->{tab}
        );

        # x:    Written as-is.
        # y:    Transposed to the first row.
        # Heat: Transposed to the subsequent rows.
        open my $tab_param_fh, '>:encoding(UTF-8)', $mapdl_tab->FileIO->dat;
        select($tab_param_fh);

        # Iterate over the plane indices.
        foreach my $newpage (0..$newpage_idx) {
            # Remove duplicated elements.
            my(%_seen, @_uniq);

            # Column
            @_uniq = grep !$_seen{$_}++,
                @{$mapdl_tab->Data->col_idx->[$newpage]};
            @{$mapdl_tab->Data->col_idx->[$newpage]} = @_uniq;

            # Row
            %_seen = ();
            @_uniq = ();
            @_uniq = grep !$_seen{$_}++,
                @{$mapdl_tab->Data->row_idx->[$newpage]};
            @{$mapdl_tab->Data->row_idx->[$newpage]} = @_uniq;

            # z
            printf(
                "%s%s",
                $mapdl_tab->Data->plane_idx->[$newpage],
                $mapdl_tab->Data->col_sep
            );

            # y: Transpose col to row.
            foreach my $col (@{$mapdl_tab->Data->col_idx->[$newpage]}) {
                print $col;
                unless ($col eq ${$mapdl_tab->Data->col_idx->[$newpage]}[-1]) {
                    print $mapdl_tab->Data->col_sep;
                }
            }
            print "\n";

            # x: Do NOT transpose.
            for (
                my $i=0;
                $i<=$#{$mapdl_tab->Data->row_idx->[$newpage]};
                $i++
            ) {
                printf(
                    "%s%s",
                    $mapdl_tab->Data->row_idx->[$newpage][$i],
                    $mapdl_tab->Data->col_sep
                );

                # Heat: Transpose col to row.
                for (
                    my $j=0;
                    $j<=$#{$mapdl_tab->Data->col_idx->[$newpage]};
                    $j++
                ) {
                    printf(
                        "%s",
                        (
                            $mapdl_tab->Data->heat->[$newpage]
                            ->{$mapdl_tab->Data->row_idx->[$newpage][$i]}
                              {$mapdl_tab->Data->col_idx->[$newpage][$j]}
                        )
                    );
                    unless ($j eq $#{$mapdl_tab->Data->col_idx->[$newpage]}) {
                        print $mapdl_tab->Data->col_sep;
                    }
                }
                say "" unless $i == $#{$mapdl_tab->Data->row_idx->[$newpage]};
            }

            # Feed a plane delimiter.
            unless ($newpage == $newpage_idx) {
                print "\n".$mapdl_tab->Data->plane_sep;
            }
        }
        select(STDOUT);
        close $tab_param_fh;

        # Notify the completion of ANGEL --> MAPDL tab conversion.
        printf(
            "[%s] --> [%s] converted.\n",
            $ang,
            $mapdl_tab->FileIO->dat
        );
    }

    return;
}


sub ang_to_gp_dat {
    # """Convert a tally file calculated by PHITS in ANGEL format
    # to a gnuplot data file."""
    my $self = shift;

    # Instantiate the 'gnuplot' class
    use gnuplot;
    my $gp = gnuplot->new();
#    $gp->Cmt->set_symb('#');
#    $gp->Data->set_col_sep(' ');
#    $gp->Data->set_plane_sep("\n");
    $gp->Cmt->set_borders(
        leading_symb => $gp->Cmt->symb,
        border_symbs => ['*', '=', '-'],
    );

    # Feature to be added..

    return;
}


sub modify_and_or_memorize_ang_files {
    # """Modify and/or memorize ANGEL files."""
    my(
        $self,
        $_src,
        $angel_ctrls_annot_type,
        @ang_fnames,
    ) = @_;

    # For strings modification
    my %ang_strs = %{$self->ang_strs};
    $ang_strs{$_} =~ s/source/$_src/i for keys %ang_strs;
    my $factor_val;
    my %modified;
    my $line_num;

    # To be commented out
    my %to_be_cmt_out = (
#        msg   => qr/^\s*ms[ud][lcr]:\s*/i,  # Replaced by 'noms' of ANGEL
        title => qr/^s*'no[.]\s*=\s*[0-9]/i,
    );

    # Notify the beginning of the routine.
    #
    # The conditional block is run only once "per call of inner_iterator()"
    # by using "a scalar reference (an object attribute called 'is_first_run')"
    # that is reinitialized at every run of the inner_iterator() of phitar.
    $self->Cmt->set_symb('$');
    $self->Cmt->set_borders(
        leading_symb => $self->Cmt->symb,
        border_symbs => ['=', '-']
    );
    if ($self->Ctrls->is_first_run and $self->Ctrls->modify_switch =~ /on/i) {
        say "";
        say $self->Cmt->borders->{'='};
        printf(
            "%s [%s] modifying tally file strings...\n",
            $self->Cmt->symb,
            join('::', (caller(0))[0, 3])
        );
        say $self->Cmt->borders->{'='};

        # Make this block not performed until the next run of inner_iterator().
        # (reinitialized at the beginning of each inner_iterator().)
        $self->Ctrls->set_is_first_run(0);
    }

    # Iterate over the tally (ANGEL) files passed.
    $self->FileIO->set_tmp('temp.txt');
    foreach my $ang (@ang_fnames) {
        next if -d;
        # An empty string can be passed from the main program
        # as a conditional return, but do not warn it.
        next if not $ang;
        if (not -e $ang) {
            say "[$ang] NOT FOUND; SKIPPING.";
            next;
        }

        #
        # Initializations
        #
        $ang_strs{multiline_cmts}           = [];
        $ang_strs{cluster_plot}{min}{const} = '';
        $ang_strs{cluster_plot}{max}{const} = '';
        $ang_strs{new}{fluence}             = '';
        $ang_strs{new}{heat_gy}             = '';
        $ang_strs{new}{heat_mev_per_cm3}    = '';
        $ang_strs{new}{heat_mev}            = '';
        %modified = (
            any                 => 0,  # Notify if any mod has been made.
            multiline_cmt       => {bef => [], aft => [], line_num => []},
            cluster_plot        => {bef => [], aft => [], line_num => []},
            cluster_plot_ft_sz  => {bef => [], aft => [], line_num => []},
            geom_plot_ft_sz     => {bef => [], aft => [], line_num => []},
            mc_fluence          => {bef => [], aft => [], line_num => []},
            mc_fluence_per_mev  => {bef => [], aft => [], line_num => []},
            mc_heat_gy          => {bef => [], aft => [], line_num => []},
            mc_heat_mev_per_cm3 => {bef => [], aft => [], line_num => []},
            mc_heat_j_per_cm3   => {bef => [], aft => [], line_num => []},
            mc_heat_mev         => {bef => [], aft => [], line_num => []},
            mc_heat_j           => {bef => [], aft => [], line_num => []},
            rel_err             => {bef => [], aft => [], line_num => []},
            axis                => {bef => [], aft => [], line_num => []},
            paren               => {bef => [], aft => [], line_num => []},
            cmt_out             => {bef => [], aft => [], line_num => []},
        );
        $factor_val = 0;
        $line_num   = 0;

        #
        # Buffer the ANGEL filenames for later ANGEL running.
        #
        $self->add_ang_fnames($ang);

        #
        # Skip the strings modification if the switch had been turned off.
        #
        next if $self->Ctrls->modify_switch =~ /off/i;

        #
        # Preprocessing for strings modification
        # (1) Take multiline comments.
        # (2) Take the labels of user-defined consts for cluster plot params.
        # (3) Check if the factor parameter has been used and, if so,
        #     take its value to set new cmax.
        #     (Note: only PHITS factors of >1.0 appear in the input echoes.)
        #
        open my $ang_fh, '<', $ang;
        my $is_multiline_cmt = 0;
        foreach my $line (<$ang_fh>) {
            # (1)
            if ($line =~ /^\s*e:\s*$/i) {
                push @{$ang_strs{multiline_cmts}}, $line;
                $is_multiline_cmt = 0;
            }
            if ($is_multiline_cmt) {
                push @{$ang_strs{multiline_cmts}}, $line;
            }
            if ($line =~ /^\s*wt:/i) {
                push @{$ang_strs{multiline_cmts}}, $line;
                $is_multiline_cmt = 1;
            }

            # (2)
            if ($line =~ /^\s*p:\s*$ang_strs{cluster_plot}{min}{key}/i) {
                ($ang_strs{cluster_plot}{min}{const} = $line) =~ s/
                    ^\s*p:\s*
                    $ang_strs{cluster_plot}{min}{key}
                    \[\s* (?<cmin_const>c[0-9]+) \s*\]
                    \s+
                    $ang_strs{cluster_plot}{max}{key}
                    \[\s* (?<cmax_const>c[0-9]+) \s*\]
                    \s*
                /$+{cmin_const}/ix;
                ($ang_strs{cluster_plot}{max}{const} = $line) =~ s/
                    ^\s*p:\s*
                    $ang_strs{cluster_plot}{min}{key}
                    \[\s* (?<cmin_const>c[0-9]+) \s*\]
                    \s+
                    $ang_strs{cluster_plot}{max}{key}
                    \[\s* (?<cmax_const>c[0-9]+) \s*\]
                    \s*
                /$+{cmax_const}/ix;
            }

            # (3)
            if ($line =~ /^\s*factor\s*=\s*\d+/i) {
                ($factor_val = $line) =~ s/
                    ^\s*factor\s*=\s*
                    (?<fact>[0-9.E\-+]+)
                    \s*[#].*
                /$+{fact}/ix;
                chomp($factor_val);
            }
        }
        close $ang_fh;

        # Assign new ANGEL unit strings; depending on
        # whether the factor parameter has been used.
        if (not $factor_val) {
            $ang_strs{new}{cmin_track}       = $self->cmin_track;
            $ang_strs{new}{cmax_track}       = $self->cmax_track;
            $ang_strs{new}{cmin_heat}        = $self->cmin_heat;
            $ang_strs{new}{cmax_heat}        = $self->cmax_heat;
            $ang_strs{new}{fluence}          = $ang_strs{mc_fluence};
            $ang_strs{new}{fluence_per_mev}  = $ang_strs{mc_fluence_per_mev};
            $ang_strs{new}{heat_gy}          = $ang_strs{mc_heat_gy};
            $ang_strs{new}{heat_mev_per_cm3} = $ang_strs{mc_heat_mev_per_cm3};
            $ang_strs{new}{heat_mev}         = $ang_strs{mc_heat_mev};
            $ang_strs{new}{rel_err}          = $ang_strs{rel_err};
        }
        # MeV --> J
        elsif ($factor_val == 1.602e-13) {
            $self->set_cmin_heat(1e-19);
            $self->set_cmax_heat(1e-15);
            $ang_strs{new}{cmin_heat}        = $self->cmin_heat;
            $ang_strs{new}{cmax_heat}        = $self->cmax_heat;
            $ang_strs{new}{heat_mev_per_cm3} = $ang_strs{mc_heat_j_per_cm3};
            $ang_strs{new}{heat_mev}         = $ang_strs{mc_heat_j};
            $ang_strs{new}{rel_err}          = $ang_strs{rel_err};
        }
        else {
            $ang_strs{new}{cmin_track}       = $factor_val * $self->cmin_track;
            $ang_strs{new}{cmax_track}       = $factor_val * $self->cmax_track;
            $ang_strs{new}{cmin_heat}        = $factor_val * $self->cmin_heat;
            $ang_strs{new}{cmax_heat}        = $factor_val * $self->cmax_heat;
            $ang_strs{new}{fluence}          = $ang_strs{flux};
            $ang_strs{new}{fluence_per_mev}  = $ang_strs{flux_per_mev};
            $ang_strs{new}{heat_gy}          = $ang_strs{heat_gy};
            $ang_strs{new}{heat_mev_per_cm3} = $ang_strs{heat_mev_per_cm3};
            $ang_strs{new}{heat_mev}         = $ang_strs{heat_mev};
            $ang_strs{new}{rel_err}          = $ang_strs{rel_err};
        }

        #
        # Modification
        #
        open $ang_fh, '<', $ang;
        open my $ang_tmp_fh, '>:encoding(UTF-8)', $self->FileIO->tmp;
        foreach my $line (<$ang_fh>) {
            $line_num++;

            # Multiline comment
            if (
                @{$ang_strs{multiline_cmts}}
                and grep { $line eq $_ } @{$ang_strs{multiline_cmts}}
            ) {
                # Memorize the original line.
                push @{$modified{multiline_cmt}{bef}}, $line;

                # Delete the line.
                $line = "\n";

                # Record if a modification has been made.
                if ($line ne $modified{multiline_cmt}{bef}[-1]) {
                    push @{$modified{multiline_cmt}{aft}},      $line;
                    push @{$modified{multiline_cmt}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Cluster plot min and max
            if (
                $ang_strs{cluster_plot}{min}{const}
                and $line =~ /^\s*set:\s*$ang_strs{cluster_plot}{min}{const}/i
            ) {
                # Memorize the original line.
                push @{$modified{cluster_plot}{bef}}, $line;

                # Determine which cluster values to use.
                $ang_strs{new}{cmin} = $ang =~ /heat/ ?
                    $ang_strs{new}{cmin_heat} : $ang_strs{new}{cmin_track};
                $ang_strs{new}{cmax} = $ang =~ /heat/ ?
                    $ang_strs{new}{cmax_heat} : $ang_strs{new}{cmax_track};

                # Perform a regex substitution.
                $line =~ s/
                    (?<set>^\s*set:\s*)
                    (?<minlt>
                        $ang_strs{cluster_plot}{min}{const}
                        \[\s*
                    )
                    [.\-+E0-9]+
                    (?<minrt>\s*\])
                    \s+
                    (?<maxlt>
                        $ang_strs{cluster_plot}{max}{const}
                        \[\s*
                    )
                    [.\-+E0-9]+
                    (?<maxrt>\s*\])
                /$+{set}$+{minlt}$ang_strs{new}{cmin}$+{minrt} $+{maxlt}$ang_strs{new}{cmax}$+{maxrt}/ix;

                # Record if a modification has been made.
                if ($line ne $modified{cluster_plot}{bef}[-1]) {
                    push @{$modified{cluster_plot}{aft}},      $line;
                    push @{$modified{cluster_plot}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Font size normalization (1/2)
            # > T-Track and T-Heat: Tick size and title font size
            # > As of PHITS v3.02 and ANGEL v4.36, the command afac[c5*<..>],
            #   e.g. c5*0.625, is applied before y: <..> which is used as
            #   the color box.
            # > Replace c5*<..> with c5.
            if ($ang =~ /track|heat/i and $line =~ /afac\[c5\*[0-9.]+\]/) {
                push @{$modified{cluster_plot_ft_sz}{bef}}, $line;

                $line =~ s/(afac\[c5)\*[0-9.]+(\])/$1$2/;

                if ($line ne $modified{cluster_plot_ft_sz}{bef}[-1]) {
                    push @{$modified{cluster_plot_ft_sz}{aft}}, $line;
                    push @{$modified{cluster_plot_ft_sz}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Font size normalization (2/2)
            # > T-Gshow and T-3Dshow: Legend font size
            # > As of PHITS v3.02 and ANGEL v4.36, the command legs
            #   is set to be <1 in both Gshow and 3Dshow.
            # > Renew the factor for legs.
            if ($ang =~ /(?:g|3d)show/i and $line =~ /legs\[.*\]/) {
                push @{$modified{geom_plot_ft_sz}{bef}}, $line;
                # Bigger fac for 3D
                my $_new_fac = $ang =~ /gshow/i ? 1 : 1.4;
                $line =~ s/
                    (?<bef>legs\[)
                    .*
                    (?<aft>\])
                /$+{bef}$_new_fac$+{aft}/x;

                if ($line ne $modified{geom_plot_ft_sz}{bef}[-1]) {
                    push @{$modified{geom_plot_ft_sz}{aft}}, $line;
                    push @{$modified{geom_plot_ft_sz}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Flux [1/cm^2/source] "or" Current [1/cm^2/source]
            # --> Monte Carlo fluence (cm^{-2} source^{-1})
            if ($line =~ /^\s*\w+:\s*\w+\s*\[1\/cm\^2\/source\]/i) {
                push @{$modified{mc_fluence}{bef}}, $line;

                $line =~ s!
                    (?<key>^\s*\w+:\s*)       # e.g. y:
                    \w+\s*\[1/cm\^2/source\]  # e.g. Flux or current
                    .*                        # .* preserves \n.
                !$+{key}$ang_strs{new}{fluence}!ix;

                if ($line ne $modified{mc_fluence}{bef}[-1]) {
                    push @{$modified{mc_fluence}{aft}},      $line;
                    push @{$modified{mc_fluence}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Flux [1/cm^2/MeV/source] "or" Current [1/cm^2/MeV/source]
            # --> Monte Carlo fluence (cm^{-2} MeV^{-1} source^{-1})
            if ($line =~ /^\s*\w+:\s*\w+\s*\[1\/cm\^2\/MeV\/source\]/i) {
                push @{$modified{mc_fluence_per_mev}{bef}}, $line;

                $line =~ s!
                    (?<key>^\s*\w+:\s*)            # e.g. y:
                    \w+\s*\[1/cm\^2/MeV\/source\]  # e.g. Flux or current
                    .*                             # .* preserves \n.
                !$+{key}$ang_strs{new}{fluence_per_mev}!ix;

                if ($line ne $modified{mc_fluence_per_mev}{bef}[-1]) {
                    push @{$modified{mc_fluence_per_mev}{aft}},      $line;
                    push @{$modified{mc_fluence_per_mev}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            #********Special block for dirs 20180620 and 20180622********
            # Fluence (cm^{-2} source^{-1})
            # --> Monte Carlo fluence (cm^{-2} source^{-1}) "or"
            #     Flux (cm^{-2} s^{-1})
            # y: Fluence (cm^{-2} source^{-1})
            #************************************************************
            if (
                $line =~
                    /^\s*\w+:\s*Fluence\s*\(cm\^\{-2\}\s*source\^\{-1\}\)/i
            ) {
                push @{$modified{mc_fluence}{bef}}, $line;

                $line =~ s!
                    (?<key>^\s*\w+:\s*)      # e.g. y:
                    Fluence\s*\(cm\^\{-2\}\s*source\^\{-1\}\)
                    .*                       # .* preserves \n.
                !$+{key}$ang_strs{new}{fluence}!ix;

                if ($line ne $modified{mc_fluence}{bef}[-1]) {
                    push @{$modified{mc_fluence}{aft}},      $line;
                    push @{$modified{mc_fluence}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Heat [Gy/source] --> Monte Carlo heat (Gy source^{-1}) "or"
            #                      Heat (Gy s^{-1})
            if ($line =~ /^\s*\w+:\s*Heat\s*\[Gy\/source\]/i) {
                push @{$modified{mc_heat_gy}{bef}}, $line;

                $line =~ s!
                    (?<key>^\s*\w+:\s*)
                    Heat\s*\[Gy/source\]
                    .*
                !$+{key}$ang_strs{new}{heat_gy}!ix;

                if ($line ne $modified{mc_heat_gy}{bef}[-1]) {
                    push @{$modified{mc_heat_gy}{aft}},      $line;
                    push @{$modified{mc_heat_gy}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            #********Special block for dirs 20180620 and 20180622********
            # y: Heat  (Gy source^{-1})
            # --> Monte Carlo heat (Gy source^{-1}) "or" Heat (Gy s^{-1})
            #************************************************************
            if ($line =~ /^\s*\w+:\s*Heat\s*\(Gy\s*source\^\{-1\}\)/i) {
                push @{$modified{mc_heat_gy}{bef}}, $line;

                $line =~ s!
                    (?<key>^\s*\w+:\s*)
                    Heat\s*\(Gy\s*source\^\{-1\}\)
                    .*
                !$+{key}$ang_strs{new}{heat_gy}!ix;

                if ($line ne $modified{mc_heat_gy}{bef}[-1]) {
                    push @{$modified{mc_heat_gy}{aft}},      $line;
                    push @{$modified{mc_heat_gy}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # [MeV/cm^3/source] --> (MeV cm^{3} source^{-1})
            if ($line =~ /^\s*\w+:\s*Heat\s*\[MeV\/cm\^3\/source\]/i) {
                push @{$modified{mc_heat_mev_per_cm3}{bef}}, $line;

                $line =~ s!
                    (?<key>^\s*\w+:\s*)
                    Heat\s*\[MeV/cm\^3/source\]
                    .*
                !$+{key}$ang_strs{new}{heat_mev_per_cm3}!ix;

                if ($line ne $modified{mc_heat_mev_per_cm3}{bef}[-1]) {
                    push @{$modified{mc_heat_mev_per_cm3}{aft}},
                        $line;
                    push @{$modified{mc_heat_mev_per_cm3}{line_num}},
                        $line_num;
                    $modified{any}++;
                }
            }

            # [MeV/source] --> (MeV source^{-1})
            if ($line =~ /^\s*\w+:\s*Heat\s*\[MeV\/source\]/i) {
                push @{$modified{mc_heat_mev}{bef}}, $line;

                $line =~ s!
                    (?<key>^\s*\w+:\s*)
                    Heat\s*\[MeV/source\]
                    .*
                !$+{key}$ang_strs{new}{heat_mev}!ix;

                if ($line ne $modified{mc_heat_mev}{bef}[-1]) {
                    push @{$modified{mc_heat_mev}{aft}},      $line;
                    push @{$modified{mc_heat_mev}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            #********Special block for dirs 20180620 and 20180622********
            # y: Heat  (MeV cm^{-3} source^{-1})
            # --> Monte Carlo heat (Gy source^{-1}) "or" Heat (Gy s^{-1})
            #************************************************************
            if (
                $line =~
                /^\s*\w+:\s*Heat\s*\(MeV\s*cm\^\{-3\}\s*source\^\{-1\}\)/i
            ) {
                push @{$modified{mc_heat_mev_per_cm3}{bef}}, $line;

                $line =~ s!
                    (?<key>^\s*\w+:\s*)
                    Heat\s*\(MeV\s*cm\^\{-3\}\s*source\^\{-1\}\)
                    .*
                !$+{key}$ang_strs{new}{heat_mev_per_cm3}!ix;

                if ($line ne $modified{mc_heat_mev_per_cm3}{bef}[-1]) {
                    push @{$modified{mc_heat_mev_per_cm3}{aft}},
                        $line;
                    push @{$modified{mc_heat_mev_per_cm3}{line_num}},
                        $line_num;
                    $modified{any}++;
                }
            }

            # Relative Error --> Relative error
            if ($line =~ /^\s*\w+:\s*Relative\s*Error/i) {
                push @{$modified{rel_err}{bef}}, $line;

                $line =~ s!
                    (?<key>^\s*\w+:\s*)      # e.g. y:
                    Relative\s*Error
                    .*                       # .* preserves \n.
                !$+{key}$ang_strs{new}{rel_err}!x;

                if ($line ne $modified{rel_err}{bef}[-1]) {
                    push @{$modified{rel_err}{aft}},      $line;
                    push @{$modified{rel_err}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            #
            # Italicize xyzr.
            #
            if ($line =~ /^\s*[xXyY]:\s*[xyzr]\b/x) {
                push @{$modified{axis}{bef}}, $line;

                $line =~ s/^(\s*[xy]:\s*)([xyzr])/$1\$$2\$/i;

                if ($line ne $modified{axis}{bef}[-1]) {
                    push @{$modified{axis}{aft}},      $line;
                    push @{$modified{axis}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            #
            # [MeV] --> (MeV)
            #
            if ($line =~ /\[ MeV \^? -? [0-9]* \]/ix) {
                push @{$modified{paren}{bef}}, $line;

                $line =~ s/\[(?<symb>MeV\^?-?[0-9]*)\]/($+{symb})/i;
                $line =~ s/\^\K(?<num>-?[0-9]+)/\{$+{num}\}/i if /\^/;

                if ($line ne $modified{paren}{bef}[-1]) {
                    push @{$modified{paren}{aft}},      $line;
                    push @{$modified{paren}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            #
            # [cm], [cm^2] --> (cm), (cm^2)
            # ***************************************************
            # *** Works only when $self->dim_unit eq 'cm'     ***
            # *** because, as of PHITS v3.02 and ANGEl v4.36, ***
            # *** the ANGEL dimension commands like cmmm      ***
            # *** identify only square bracketed cm, or [cm]. ***
            # *** (i.e. cm is not converted to mm if () are   ***
            # *** used instead of the default [].)            ***
            # ***************************************************
            #
            if (
                $self->dim_unit =~ /cm/i
                and $line =~ /\[ cm \^? -? [0-9]* \]/ix
            ) {
                push @{$modified{paren}{bef}}, $line;

                $line =~ s/\[(?<symb>cm\^?-?[0-9]*)\]/($+{symb})/i;
                $line =~ s/\^\K(?<num>-?[0-9]+)/\{$+{num}\}/i if /\^/;

                if ($line ne $modified{paren}{bef}[-1]) {
                    push @{$modified{paren}{aft}},      $line;
                    push @{$modified{paren}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            #
            # To be commented out
            #

            # Messages: Replaced by 'noms' of ANGEL (2019-05-13)
#            if ($line =~ /$to_be_cmt_out{msg}/) {
#                push @{$modified{cmt_out}{bef}}, $line;
#                
#                $line =~ s/^/#/;
#                
#                if ($line ne $modified{cmt_out}{bef}[-1]) {
#                    push @{$modified{cmt_out}{aft}},      $line;
#                    push @{$modified{cmt_out}{line_num}}, $line_num;
#                    $modified{any}++;
#                }
#            }

            # ANGEL title
            if ($line =~ /$to_be_cmt_out{title}/) {
                push @{$modified{cmt_out}{bef}}, $line;

                $line =~ s/^/#/;

                if ($line ne $modified{cmt_out}{bef}[-1]) {
                    push @{$modified{cmt_out}{aft}},      $line;
                    push @{$modified{cmt_out}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            #
            # Write to the temporary file.
            #
            print $ang_tmp_fh $line;
        }
        close $ang_tmp_fh;
        close $ang_fh;

        # Swap the modified temp and original tally (ANGEL) files.
        if ($modified{any}) {
            unlink $ang;
            copy($self->FileIO->tmp, $ang) or die "Copy failed: $!";
        }
        unlink $self->FileIO->tmp;

        # Notify the end of modifications.
        if ($modified{any}) {
            (my $mdf = $ang) =~ s/[.](?:ang|out|[a-zA-Z]+)/.mdf/i;
            open my $mdf_fh, '>:encoding(UTF-8)', $mdf;
            my %tee_fhs = (
                mdf => $mdf_fh,
                scr => *STDOUT,
            );

            foreach my $fh (sort values %tee_fhs) {
                printf $fh ("%s\n", $self->Cmt->borders->{'-'})
                    if $self->Ctrls->mute eq 'off';
                printf $fh (
                    "%s[$ang] strings modified%s\n",
                    ($self->Ctrls->mute eq 'off' ? $self->Cmt->symb.' ' : ''),
                    ($self->Ctrls->mute eq 'off' ? ':' : '.'),
                );
                printf $fh ("%s\n", $self->Cmt->borders->{'-'})
                    if $self->Ctrls->mute eq 'off';
            }

            # Print the list of modifications.
            delete $tee_fhs{scr} if $self->Ctrls->mute eq 'on';
            foreach my $fh (sort values %tee_fhs) {
                my($_conv, $_line);
                foreach my $k (
                    qw/
                        multiline_cmt
                        cluster_plot
                        cluster_plot_ft_sz
                        geom_plot_ft_sz
                        mc_fluence
                        mc_fluence_per_mev
                        mc_heat_gy
                        mc_heat_mev_per_cm3
                        mc_heat_j_per_cm3
                        mc_heat_mev
                        mc_heat_j
                        rel_err
                        axis
                        paren
                        cmt_out
                    /
                ) {
                    foreach (my $i=0; $i<=$#{$modified{$k}{bef}}; $i++) {
                        if ($modified{$k}{bef}[$i] ne $modified{$k}{aft}[$i]) {
                            $_line =
                                "        [Line $modified{$k}{line_num}[$i]]";
                            $_conv =
                                '%'.length($_line).'s';
                            print $fh "$_line $modified{$k}{bef}[$i]";
                            printf $fh (
                                "$_conv %s",
                                '-->',
                                $modified{$k}{aft}[$i] =~ /^\s*\n$/ ?
                                    "(blank line)\n" :
                                    $modified{$k}{aft}[$i],
                            );
                        }
                    }
                }
                printf $fh ("%s\n\n", $self->Cmt->borders->{'-'})
                    if $self->Ctrls->mute eq 'off';
            }
            close $mdf_fh;
        }
        elsif (not $modified{any}) {
            say "\"NO\" modification made on [$ang].";
        }
    }

    return;
}


sub modify_eps_files {
    # """Modify ANGEL-generated EPS files. This main task of this routine is
    # to change [] to () enclosing unit symbols; in order to use the unit
    # conversion commands of ANGEL such as cmmm and cmum, where [cm] is used
    # as the hook, the string [cm] within ANGEL files must be preserved.
    # We therefore modify [mm] or [um] within the generated EPS files."""
    my(
        $self,
        $eps_fnames_aref,
        $dim_unit,
    ) = @_;

    # Correct the file extensions.
    s/[.]ang$/.eps/i for @{$eps_fnames_aref};

    # Iterate over the EPS files passed.
    $self->FileIO->set_tmp('temp.eps');
    foreach my $eps (@{$eps_fnames_aref}) {
        next if -d;
        next if not $eps;
        if (not -e $eps) {
            say "[$eps] NOT FOUND; SKIPPING.";
            next;
        }

        # Initialization
        my %modified = (
            any                 => 0,  # Notify if any mod has been made.
            axis                => {bef => [], aft => [], line_num => []},
            axis_partial        => {bef => [], aft => [], line_num => []},
            axis_partial2       => {bef => [], aft => [], line_num => []},
            num                 => {bef => [], aft => [], line_num => []},
            num_partial         => {bef => [], aft => [], line_num => []},
            num_partial_supersc => {bef => [], aft => [], line_num => []},
            file                => {bef => [], aft => [], line_num => []},
            date                => {bef => [], aft => [], line_num => []},
        );
        my $line_num;

        #
        # Modification
        #
        open my $eps_fh, '<', $eps;
        open my $eps_tmp_fh, '>:encoding(UTF-8)', $self->FileIO->tmp;
        foreach my $line (<$eps_fh>) {
            $line_num++;

            #
            # Change the unit symbol braces to parenthesis.
            #

            # Axis, full PS commands
            if ($line =~ /^\s*\/str[0-9]+\s*\(\s*[xyzr]\s*\[(?:[cm]m)\]/i) {
                # Memorize the original line.
                push @{$modified{axis}{bef}}, $line;

                # Perform regex substitutions.
                $line =~ s/
                    (?<axis>[xyzr])
                    \s*
                    \[
                    (?<unit_symb>[cm]m)
                    \]
                /$+{axis} ($+{unit_symb})/ix;

                # Examine if a modification has been made.
                if ($line ne $modified{axis}{bef}[-1]) {
                    push @{$modified{axis}{aft}},      $line;
                    push @{$modified{axis}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Axis, fragmented PS commands (i)
            if ($line =~ /^\s*\/str[0-9]+\s*\(\s*\[(?:[cm]m)\]/i) {
                push @{$modified{axis_partial}{bef}}, $line;

                $line =~ s/\[/\\(/;
                $line =~ s/\]/\\)/;

                if ($line ne $modified{axis_partial}{bef}[-1]) {
                    push @{$modified{axis_partial}{aft}},      $line;
                    push @{$modified{axis_partial}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Axis, fragmented PS commands (ii)
            if ($line =~ /^\s*\/str[0-9]+\s*\((?:\s*[xyzr]\s*\[ | m\])/ix) {
                push @{$modified{axis_partial2}{bef}}, $line;

                $line =~ s/\[/\\(/;
                $line =~ s/\]/\\)/;

                if ($line ne $modified{axis_partial2}{bef}[-1]) {
                    push @{$modified{axis_partial2}{aft}},      $line;
                    push @{$modified{axis_partial2}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Number, full PS commands
            # Remove braces following numbers, which are unnecessary;
            # e.g. 2.0000E+01 (MeV) -->  2.0000E+01 MeV
            if (
                $line =~
                    /^\s*\/str[0-9]+\s*\(\s*[+\-]?[0-9.]+E[+\-][0-9.]+/i
            ) {
                push @{$modified{num}{bef}}, $line;

                $line =~ s/
                    \\\(
                    | \\\)
                    | \[
                    | \]
                //gx;

                if ($line ne $modified{num}{bef}[-1]) {
                    push @{$modified{num}{aft}},      $line;
                    push @{$modified{num}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Number, fragmented PS commands (i)
            if ($line =~ /^\s*\/str[0-9]+\s*\((?:\[ | \])\)/ix) {
                push @{$modified{num_partial}{bef}}, $line;

                $line =~ s/\[//;
                $line =~ s/\]//;

                if ($line ne $modified{num_partial}{bef}[-1]) {
                    push @{$modified{num_partial}{aft}},      $line;
                    push @{$modified{num_partial}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Number, fragmented PS commands (ii)
            # > Correct the position of superscripts.
            my $wrong_pos = qr/
                132[.]63    # track-eng-mo_<..>
                | 135[.]61  # track-eng-w_<..>
                | 137[.]92  # cross-eng-mo_<..>
                | 140[.]91  # cross-eng-w_<..>
            /x;
            if ($line =~ /str004\s*xps\s*($wrong_pos)/i) {
                push @{$modified{num_partial_supersc}{bef}}, $line;

                # e.g. cm 2 --> cm2 in the T-Cross files
                (my $_pos = $line) =~ s/.*($wrong_pos).*/$1/;
                $_pos -= 3;
                $line =~ s/($wrong_pos)/$_pos/;

                if ($line ne $modified{num_partial_supersc}{bef}[-1]) {
                    push @{$modified{num_partial_supersc}{aft}},
                        $line;
                    push @{$modified{num_partial_supersc}{line_num}},
                        $line_num;
                    $modified{any}++;
                }
            }

            # File info
            if ($line =~ /\(File\s*=\s*.*\)/i) {
                push @{$modified{file}{bef}}, $line;

                $line =~ s/\(File\s*=\s*.*\)/()/;

                if ($line ne $modified{file}{bef}[-1]) {
                    push @{$modified{file}{aft}},      $line;
                    push @{$modified{file}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Date info
            if ($line =~ /\(Date\s*=\s*.*\)/i) {
                push @{$modified{date}{bef}}, $line;

                $line =~ s/\(Date\s*=\s*.*\)/()/;

                if ($line ne $modified{date}{bef}[-1]) {
                    push @{$modified{date}{aft}},      $line;
                    push @{$modified{date}{line_num}}, $line_num;
                    $modified{any}++;
                }
            }

            # Write to the temporary file.
            print $eps_tmp_fh $line;
        }
        close $eps_tmp_fh;
        close $eps_fh;

        # Swap the modified temp and original tally (ANGEL) files.
        if ($modified{any}) {
            unlink $eps;
            copy($self->FileIO->tmp, $eps) or die "Copy failed: $!";
        }
        unlink $self->FileIO->tmp;

        # Notify the end of modifications.
        if ($modified{any}) {
            say $self->Cmt->borders->{'-'} if $self->Ctrls->mute eq 'off';
            printf(
                "%s[$eps] strings modified%s\n",
                ($self->Ctrls->mute eq 'off' ? $self->Cmt->symb.' ' : ''),
                ($self->Ctrls->mute eq 'off' ? ':' : '.')
            );
            say $self->Cmt->borders->{'-'} if $self->Ctrls->mute eq 'off';

            # Show what modifications have been made.
            # Turned off if the mute switch has been turned on.
            if ($self->Ctrls->mute eq 'off') {
                my($_conv, $_line);
                foreach my $k (
                    qw/
                        axis
                        axis_partial
                        axis_partial2
                        num
                        num_partial
                        num_partial_supersc
                        file
                        date
                    /
                ) {
                    foreach (my $i=0; $i<=$#{$modified{$k}{bef}}; $i++) {
                        if ($modified{$k}{bef}[$i] ne $modified{$k}{aft}[$i]) {
                            $_line =
                                "        [Line $modified{$k}{line_num}[$i]]";
                            $_conv =
                                '%'.length($_line).'s';
                            print "$_line $modified{$k}{bef}[$i]";
                            printf("$_conv $modified{$k}{aft}[$i]", '-->');
                        }
                    }
                }
                say $self->Cmt->borders->{'-'};
                say "";
            }
        }
        elsif (not $modified{any}) {
            say "\"NO\" modification made on [$eps].";
        }
    }

    return;
}

__PACKAGE__->meta->make_immutable;
1;


package PHITS::Cmt;

use Moose;
use Moose::Util::TypeConstraints;
use namespace::autoclean;
with 'My::Moose::Cmt';

# ANGEL annotation for an iteration variable
my %annot_types = map { $_ => 1 } (
    'none',
    'beam',
    'geom',
);

subtype 'My::Moose::PHITS::Cmt::Annot'
    => as 'Str'
    => where { exists $annot_types{$_} }
    => message {
        printf(
            "\n\n%s\n[%s] is not an allowed value.".
            "\nPlease input one of these: [%s]\n%s\n\n",
            ('-' x 70), $_,
            join(', ', sort keys %annot_types), ('-' x 70),
        )
    };

has 'annot_type' => (
    is      => 'ro',
    isa     => 'My::Moose::PHITS::Cmt::Annot',
    lazy    => 1,
    default => 'none',
    writer  => 'set_annot_type',
);

has 'annot' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => '',
    writer  => 'set_annot',
);

__PACKAGE__->meta->make_immutable;
1;


package PHITS::Ctrls;

use Moose;
use Moose::Util::TypeConstraints;
use namespace::autoclean;
with 'My::Moose::Ctrls';

# Additional switches
my %_additional_switches = (
    modify_switch    => 'on',
    noframe_switch   => 'on',
    nomessage_switch => 'on',
    nolegend_switch  => 'off',
);

has $_ => (
    is      => 'ro',
    isa     => 'My::Moose::Ctrls::OnOff',
    lazy    => 1,
    default => $_additional_switches{$_},
    writer  => 'set_'.$_,
) for keys %_additional_switches;

my %num_procs = (
    default => 0,
    min     => 0,
    max     => $^O =~ /MSWin/i ?
        `echo %NUMBER_OF_PROCESSORS%` :
        `grep '^core id' /proc/cpuinfo |sort -u|wc -l`,
);

subtype 'My::Moose::PHITS::Ctrls::OpenMP'
    => as 'Int'
    => where { $_ >= $num_procs{min} and $_ <= $num_procs{max} }
    => message {
        printf(
            "\n\n%s\nYou have input [%s] as the number of".
            " physical cores for shared-memory\n".
            "parallel computing. However, it must lie in [%d,%d].\n".
            "For info, inputting [0] will use all the physical cores.\n%s\n\n",
            ('-' x 70), $_, $num_procs{min}, $num_procs{max}, ('-' x 70),
        )
    };

has 'openmp' => (
    is      => 'ro',
    isa     => 'My::Moose::PHITS::Ctrls::OpenMP',
    lazy    => 1,
    default => $num_procs{default},
    writer  => 'set_openmp',
);

__PACKAGE__->meta->make_immutable;
1;


package PHITS::Data;

use Moose;
use namespace::autoclean;
with 'My::Moose::Data';

__PACKAGE__->meta->make_immutable;
1;


package PHITS::FileIO;

use Moose;
use namespace::autoclean;
with 'My::Moose::FileIO';

# Additional attributes
my %_additional_attrs = (
    varying_str  => 'varying',
    varying_flag => 'v',
    fixed_str    => 'fixed',
    fixed_flag   => 'f',
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


package PHITS::Source;

use Moose;
use Moose::Util::TypeConstraints;
use namespace::autoclean;

# Source mode
my %_modes = map { $_ => 1 } (
    'plain',  # s-type 1, 2, 3
    'dump',   # s-type 17 (dump)
);

subtype 'My::Moose::PHITS::Source::Mode'
    => as 'Str'
    => where { exists $_modes{$_} }
    => message {
        printf(
            "\n\n%s\n[%s] is not an allowed value.".
            "\nPlease input one of these: [%s]\n%s\n\n",
            ('-' x 70), $_,
            join(', ', sort keys %_modes), ('-' x 70),
        )
    };

has 'mode' => (
    is      => 'ro',
    isa     => 'My::Moose::PHITS::Source::Mode',
    lazy    => 1,
    default => 'plain',
    writer  => 'set_mode',
);

# Energy distribution
has $_ => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Str|HashRef]',
    default => sub { {} },
    handles => {
        'set_'.$_ => 'set',
    },
) for qw(
    gaussian_nrg
    free_form_nrg
);

# Spatial distribution
has $_ => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Str|HashRef]',
    default => sub { {} },
    handles => {
        'set_'.$_ => 'set',
    },
) for qw(
    gaussian_xy
    gaussian_xyz
    cylindrical
    dump
);

# Variables into which values of interest will be copy-pasted
my %_vals_of_int = (
    nrg_dist_of_int  => '',
    spat_dist_of_int => '',
    iter_param       => 'eg0',
);

has $_ => ( 
    is      => 'ro',
    lazy    => 1,
    default => $_vals_of_int{$_},
    writer  => 'set_'.$_,
) for keys %_vals_of_int;

# Setters for Gaussian energy distribution
sub set_eg0_val_fixed {
    my $self = shift;
    $self->gaussian_nrg->{eg0}{val_fixed} = $_[0]
        if defined $_[0];
    return;
}
sub set_eg0_vals_of_int {
    my $self = shift;
    @{$self->gaussian_nrg->{eg0}{vals_of_int}} = @{$_[0]}
        if defined $_[0];
    return;
}

# Setters for spatial distribution, releasing coordinates
sub set_x_center {
    my $self = shift;
    $self->spat_dist_of_int->{x_center}{val} = $_[0]
        if defined $_[0];
    return;
}
sub set_y_center {
    my $self = shift;
    $self->spat_dist_of_int->{y_center}{val} = $_[0]
        if defined $_[0];
    return;
}
sub set_z_center {
    my $self = shift;
    $self->spat_dist_of_int->{z_center}{val} = $_[0]
        if defined $_[0];
    return;
}
sub set_z_beg {
    my $self = shift;
    $self->spat_dist_of_int->{z_beg}{val} = $_[0]
        if defined $_[0];
    return;
}
sub set_z_end {
    my $self = shift;
    $self->spat_dist_of_int->{z_end}{val} = $_[0]
        if defined $_[0];
    return;
}

# Setters for gaussian_xy spatial distribution
# x-FWHM and y-FWHM
sub set_xy_fwhms_val_fixed {
    my $self = shift;
    $self->spat_dist_of_int->{xy_fwhms}{val_fixed} = $_[0]
        if defined $_[0];
    return;
}
sub set_xy_fwhms_vals_of_int {
    my $self = shift;
    @{$self->spat_dist_of_int->{xy_fwhms}{vals_of_int}} = @{$_[0]}
        if defined $_[0];
    return;
}

# Setters for gaussian_xyz spatial distribution
# x-FWHM
sub set_x_fwhm_val_fixed {
    my $self = shift;
    $self->spat_dist_of_int->{x_fwhm}{val_fixed} = $_[0]
        if defined $_[0];
    return;
}
sub set_x_fwhm_vals_of_int {
    my $self = shift;
    @{$self->spat_dist_of_int->{x_fwhm}{vals_of_int}} = @{$_[0]}
        if defined $_[0];
    return;
}
# y-FWHM
sub set_y_fwhm_val_fixed {
    my $self = shift;
    $self->spat_dist_of_int->{y_fwhm}{val_fixed} = $_[0]
        if defined $_[0];
    return;
}
sub set_y_fwhm_vals_of_int {
    my $self = shift;
    @{$self->spat_dist_of_int->{y_fwhm}{vals_of_int}} = @{$_[0]}
        if defined $_[0];
    return;
}
# z-FWHM
sub set_z_fwhm_val_fixed {
    my $self = shift;
    $self->spat_dist_of_int->{z_fwhm}{val_fixed} = $_[0]
        if defined $_[0];
    return;
}
sub set_z_fwhm_vals_of_int {
    my $self = shift;
    @{$self->spat_dist_of_int->{z_fwhm}{vals_of_int}} = @{$_[0]}
        if defined $_[0];
    return;
}

# Setters for cylindrical spatial distribution
sub set_rad_val_fixed {
    my $self = shift;
    $self->spat_dist_of_int->{rad}{val_fixed} = $_[0]
        if defined $_[0];
    return;
}
sub set_rad_vals_of_int {
    my $self = shift;
    @{$self->spat_dist_of_int->{rad}{vals_of_int}} = @{$_[0]}
        if defined $_[0];
    return;
}

__PACKAGE__->meta->make_immutable;
1;