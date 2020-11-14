package My::Nuclear;

use strict;
use warnings;
use autodie qw(open close chdir mkdir unlink);
use utf8;
use feature qw(say state);
use Carp qw(croak);
use Cwd qw(getcwd);
use Data::Dump qw(dump);
use File::Copy qw(copy);
use List::Util qw(first shuffle);
use DateTime;
use constant SCALAR => ref \$0;
use constant ARRAY  => ref [];
use constant HASH   => ref {};
use Exporter qw(import);
use My::Toolset qw(
    pause_shell
);
our @EXPORT = qw(
    enri_preproc
    enri
    enri_postproc

    calc_rn_yield
);
our @EXPORT_OK = qw(
    calc_consti_elem_wgt_avg_molar_masses
    convert_fracs
    enrich_or_deplete
    calc_mat_molar_mass_and_subcomp_mass_fracs_and_dccs
    calc_mass_dens_and_num_dens
    adjust_num_of_decimal_places
    assoc_prod_nucls_with_reactions_and_dccs
    gen_chem_hrefs

    read_in_mc_flues
    interp_and_read_in_micro_xs
    pointwise_multiplication
    tot_react_rate_to_yield_and_sp_yield
);
our %EXPORT_TAGS = (
    all  => [@EXPORT, @EXPORT_OK],
    enri => [qw(
        enri_preproc
        enri
        enri_postproc
    )],
    enri_minors => [qw(
        calc_consti_elem_wgt_avg_molar_masses
        convert_fracs
        enrich_or_deplete
        calc_mat_molar_mass_and_subcomp_mass_fracs_and_dccs
        calc_mass_dens_and_num_dens
        adjust_num_of_decimal_places
        assoc_prod_nucls_with_reactions_and_dccs
        gen_chem_hrefs
    )],
    yield => [qw(
        calc_rn_yield
    )],
    yield_minors => [qw(
        gen_chem_hrefs
        enri_preproc
        read_in_mc_flues
        interp_and_read_in_micro_xs
        pointwise_multiplication
        tot_react_rate_to_yield_and_sp_yield
    )],
);


our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.01';
our $LAST     = '2020-08-07';
our $FIRST    = '2018-09-24';


sub calc_consti_elem_wgt_avg_molar_masses {
    # """Calculate the weighted-average molar masses of
    # the constituent elements of a material."""
    my (                  # e.g.
        $mat_href,        # \%moo3
        $weighting_frac,  # 'amt_frac'
        $is_verbose       # 1 (boolean)
    ) = @_;

    # e.g. ('mo', 'o')
    foreach my $elem_str (@{$mat_href->{consti_elems}}) {
        # Redirect the hash of the constituent element for clearer coding.
        my $elem_href = $mat_href->{$elem_str}{href};  # e.g. \%mo, \%o

        if ($is_verbose) {
            say "\n".("=" x 70);
            printf(
                "[%s]\n".
                "calculating the weighted-average molar mass of [%s]\n".
                "using [%s] as the weighting factor...\n",
                join('::', (caller(0))[3]),
                $elem_href->{label},
                $weighting_frac,
            );
            say "=" x 70;
        }

        #
        # Calculate the weighted-average molar mass of a constituent element
        # by adding up the "weighted" molar masses of its isotopes.
        #

        # Initializations
        #        $mo{wgt_avg_molar_mass}
        #         $o{wgt_avg_molar_mass}
        $elem_href->{wgt_avg_molar_mass} = 0;  # Used for (i) and (ii) below
        #        $mo{mass_frac_sum}
        #         $o{mass_frac_sum}
        $elem_href->{mass_frac_sum} = 0;  # Used for (ii) below

        # (i) Weight by amount fraction: Weighted "arithmetic" mean
        if ($weighting_frac eq 'amt_frac') {
            # e.g. ('92', '94', ... '100') for $elem_href == \%mo
            foreach my $mass_num (@{$elem_href->{mass_nums}}) {
                # (1) Weight the molar mass of an isotope by $weighting_frac.
                #     => Weight by "multiplication"
                #              $mo{100}{wgt_molar_mass}
                $elem_href->{$mass_num}{wgt_molar_mass} =
                    #              $mo{100}{amt_frac}
                    $elem_href->{$mass_num}{$weighting_frac}
                    #                $mo{100}{molar_mass}
                    * $elem_href->{$mass_num}{molar_mass};

                # (2) Cumulative sum of the weighted molar masses of
                #     the isotopes, which will in turn become the
                #     weighted-average molar mass of the constituent element.
                #        $mo{wgt_avg_molar_mass}
                $elem_href->{wgt_avg_molar_mass} +=
                    #              $mo{100}{wgt_molar_mass}
                    $elem_href->{$mass_num}{wgt_molar_mass};

                # No further step :)
            }
        }

        # (ii) Weight by mass fraction: Weighted "harmonic" mean
        elsif ($weighting_frac eq 'mass_frac') {
            foreach my $mass_num (@{$elem_href->{mass_nums}}) {
                # (1) Weight the molar mass of an isotope by $weighting_frac.
                #     => Weight by "division"
                $elem_href->{$mass_num}{wgt_molar_mass} =
                    $elem_href->{$mass_num}{$weighting_frac}
                    / $elem_href->{$mass_num}{molar_mass};

                # (2) Cumulative sum of the weighted molar masses of
                #     the isotopes
                #     => Will be the denominator in (4).
                $elem_href->{wgt_avg_molar_mass} +=
                    $elem_href->{$mass_num}{wgt_molar_mass};

                # (3) Cumulative sum of the mass fractions of the isotopes
                #     => Will be the numerator in (4).
                #     => The final value of the cumulative sum
                #        should be 1 in principle.
                $elem_href->{mass_frac_sum} +=
                    $elem_href->{$mass_num}{$weighting_frac};
            }
            # (4) Evaluate the fraction.
            $elem_href->{wgt_avg_molar_mass} =
                $elem_href->{mass_frac_sum}  # Should be 1 in principle.
                / $elem_href->{wgt_avg_molar_mass};
        }

        else {
            croak "\n\n[$weighting_frac] ".
                  "is not an available weighting factor; terminating.\n";
        }

        if ($is_verbose) {
            dump($elem_href);
            pause_shell("Press enter to continue...");
        }
    }

    return;
}


sub convert_fracs {
    # """Convert the amount fractions of nuclides to mass fractions,
    # or vice versa."""
    my (              # e.g.
        $mat_href,    # \%moo3
        $conv_mode,   # 'amt_to_mass'
        $is_verbose,  # 1 (boolean)
    ) = @_;

    # e.g. ['mo', 'o']
    foreach my $elem_str (@{$mat_href->{consti_elems}}) {
        # Redirect the hash of the constituent element for clearer coding.
        my $elem_href = $mat_href->{$elem_str}{href};  # e.g. \%mo, \%o

        if ($is_verbose) {
            say "\n".("=" x 70);
            printf(
                "[%s]\n".
                "converting the fractional quantities of [%s] as [%s]...\n",
                join('::', (caller(0))[3]),
                $elem_href->{label},
                $conv_mode,
            );
            say "=" x 70;
        }

        # (i) Amount to mass fractions
        if ($conv_mode eq 'amt_to_mass') {
            foreach my $mass_num (@{$elem_href->{mass_nums}}) {
                $elem_href->{$mass_num}{mass_frac} =
                    $elem_href->{$mass_num}{amt_frac}
                    * $elem_href->{$mass_num}{molar_mass}
                    / $elem_href->{wgt_avg_molar_mass};
            }
        }

        # (ii) Mass to amount fractions
        elsif ($conv_mode eq 'mass_to_amt') {
            foreach my $mass_num (@{$elem_href->{mass_nums}}) {
                $elem_href->{$mass_num}{amt_frac} =
                    $elem_href->{$mass_num}{mass_frac}
                    * $elem_href->{wgt_avg_molar_mass}
                    / $elem_href->{$mass_num}{molar_mass};
            }
        }

        if ($is_verbose) {
            dump($elem_href);
            pause_shell("Press enter to continue...");
        }
    }

    return;
}


sub enrich_or_deplete {
    # """Redistribute the enrichment levels of nuclides with respect to
    # the enrichment level of the nuclide to be enriched/depleted."""
    my (                       # e.g.
        $enri_nucl_elem_href,  # \%mo
        $enri_nucl_mass_num,   # '100'
        $enri_lev,             # 0.9739 (the goal enrichment level)
        $enri_lev_type,        # 'amt_frac'
        $depl_order,           # 'ascend'
        $is_verbose,           # 1 (boolean)
    ) = @_;
    my (
        $to_be_absorbed,       # Enri level for arithmetic operations
        $to_be_absorbed_goal,  # Enri level to be given to the nuclide of int
        $donatable,            # Donatable enri level
        $remainder,            # New enri level of $to_be_absorbed
    );
    $to_be_absorbed      =
    $to_be_absorbed_goal =  # Will be further modified after the loop run
        $enri_lev
        - $enri_nucl_elem_href->{$enri_nucl_mass_num}{$enri_lev_type};
    my $old_enri_lev;  # Printing purposes only

    #
    # - If the goal enrichment level of the nuclide of interest is
    #   lower than its minimum depletion level, exit and return '1'
    #   that will in turn be used as a signal "not" to accumulate data.
    # - This separate hook is necessary because the nuclide of interest
    #   is handled separately after the loop run.
    #
    if (
        $enri_lev
        < $enri_nucl_elem_href->{$enri_nucl_mass_num}{min_depl_lev}
    ) {
        printf(
            "[%s %s: %s] is lower than".
            " its minimum depletion level [%s]. Skipping.\n",
            $enri_nucl_elem_href->{$enri_nucl_mass_num}{label},
            $enri_lev_type,
            $enri_lev,
            $enri_nucl_elem_href->{$enri_nucl_mass_num}{min_depl_lev},
        );
        return 1;  # Which will in turn become an exit hook for enri()
    }

    #
    # Show the nuclide of interest and its planned enrichment level change.
    #
    if ($is_verbose) {
        say "\n".("=" x 70);
        printf(
            "[%s]\n".
            "redistributing the enrichment levels of [%s isotopes]...\n\n",
            join('::', (caller(0))[3]),
            $enri_nucl_elem_href->{label},
        );
        printf(
            "%-19s: [%s]\n".
            "%-19s: [%s]\n".
            "%-19s: [%f] --> [%f]\n",
            'Nuclide of interest',
            $enri_nucl_elem_href->{$enri_nucl_mass_num}{label},
            '$enri_lev_type',
            $enri_lev_type,
            "Goal $enri_lev_type",
            $enri_nucl_elem_href->{$enri_nucl_mass_num}{$enri_lev_type},
            $enri_lev,
        );
        printf(
            "%-19s: [%f]\n",
            '$to_be_absorbed',
            $to_be_absorbed,
        );
        say "=" x 70;
    }

    #
    # Collect enrichment levels from the nuclides other than the nuclide
    # of interest. The collected (donated) enrichment levels will then be
    # added to the nuclide of interest after the loop run.
    #
    # Memorandum:
    #   DO NOT exit this loop (but you can skip an iteration for a nuclide,
    #   for example when a nuclide has no more donatable enrichment level),
    #   otherwise all of the remaining nuclides will be skipped and thereby
    #   incorrect arithmetics will result. For example, the nuclide of interest
    #   may not be given the to-be-donated enrichment levels,
    #   even if that to-be-donated enrichment levels have already been
    #   subtracted from the previously iterated nuclides.
    #

    # Take out the nuclide of interest (to be enriched or depleted) from
    # the nuclides list. The nuclide of interest will be handled separately
    # after the loop run.
    my @mass_nums_wo_enri_nucl =
        grep !/$enri_nucl_mass_num/, @{$enri_nucl_elem_href->{mass_nums}};

    # Determine the order of nuclide depletion.
    if ($depl_order =~ /asc(?:end)?/i) {
        @mass_nums_wo_enri_nucl = sort { $a <=> $b } @mass_nums_wo_enri_nucl;
    }
    elsif ($depl_order =~ /desc(?:end)?/i) {
        @mass_nums_wo_enri_nucl = sort { $b <=> $a } @mass_nums_wo_enri_nucl;
    }
    elsif ($depl_order =~ /rand(?:om)?|shuffle/i) {
        @mass_nums_wo_enri_nucl = shuffle @mass_nums_wo_enri_nucl;
    }

    foreach my $mass_num (@mass_nums_wo_enri_nucl) {
        # (b-d) of the arithmetics below
        $donatable =
            $enri_nucl_elem_href->{$mass_num}{$enri_lev_type}
            - $enri_nucl_elem_href->{$mass_num}{min_depl_lev};

        # Show the current nuclide.
        if ($is_verbose) {
            say "-" x 70;
            printf(
                "%-22s: [%s]\n",
                'Nuclide',
                $enri_nucl_elem_href->{$mass_num}{label},
            );
            printf(
                "%-22s: [%s]\n",
                $enri_lev_type,
                $enri_nucl_elem_href->{$mass_num}{$enri_lev_type},
            );
            printf(
                "%-22s: [%s]\n",
                'Min depletion level',
                $enri_nucl_elem_href->{$mass_num}{min_depl_lev},
            );
            printf(
                "%-22s: [%s]\n",
                'Donatable',
                $donatable,
            );
            say "-" x 70;
        }

        #
        # Arithmetics for the nuclides other than the nuclide of interest
        # (whose enrichment levels are to be extracted)
        #
        # (i)  b -= a ... (a < 0), where (b > d) is boolean true
        # (ii) skip   ... (b = d)
        #   Note: b < d is not specifically examined. This is because b < d
        #   holds only when the predefined enrichment level of the nuclide
        #   is smaller than the later-set minimum depletion level.
        #   As both the (iii) and (iv) conditionals require b > d,
        #   the state of b < d works only for the (i) conditional above.
        #   (an nuclide of b < d cannot be depleted, but can be enriched)
        # (iii) c = a-(b-d) ... (b > d "and" a >= b-d)
        # (iv)  c = (b-d)-a ... (b > d "and" b-d > a "and" a != 0)
        # where
        # c
        #   - $remainder
        #   - The one that will be the value of $to_be_absorbed or 'a'
        #     at the next nuclide
        #   - Greater than or equal to 0
        # a
        #   - $to_be_absorbed
        #   - The amount of enrichment level to be transferred
        #     from the current nuclide to the nuclide of interest
        # b
        #   - $enri_nucl_elem_href->{$mass_num}{$enri_lev_type}
        #   - The current enrichment level of a nuclide
        # d
        #   - $enri_nucl_elem_href->{$mass_num}{min_depl_lev}
        #   - The minimum depletion level
        #

        # Remember the enrichment level of a nuclide
        # before its redistribution, for printing purposes.
        $old_enri_lev = $enri_nucl_elem_href->{$mass_num}{$enri_lev_type};

        # (i) b -= a ... (a < 0) where (b > d) is boolean true
        if ($to_be_absorbed < 0) {
            # Reporting (1/2)
            if ($is_verbose) {
                printf(
                    "%-14s: [%f]\n",
                    'To be absorbed',
                    $to_be_absorbed,
                );
            }

            # b -= a
            $enri_nucl_elem_href->{$mass_num}{$enri_lev_type} -=
                $to_be_absorbed;

            # a = 0
            $to_be_absorbed = 0;

            # Reporting (2/2)
            if ($is_verbose) {
                printf(
                    "%-14s: [%f]\n",
                    "Donatable",
                    $donatable,
                );
                printf(
                    "%-14s: [%f] --> [%f]\n",
                    "$enri_lev_type",
                    $old_enri_lev,
                    $enri_nucl_elem_href->{$mass_num}{$enri_lev_type},
                );
                printf(
                    "%-14s: [%f]\n",
                    'Remainder',
                    $to_be_absorbed,
                );
                print "\n";
            }

            # next must be used not to enter into the conditionals below.
            next;
        }

        # (ii) skip ... (b = d)
        # b = d means that no more enrichment level is available.
        if (not $donatable) {
            print "No more donatable [$enri_lev_type].\n\n" if $is_verbose;
            next;
        }

        # (iii) c = a-(b-d) ... (b > d "and" a >= b-d)
        if (
            $to_be_absorbed >= $donatable
            and (
                $enri_nucl_elem_href->{$mass_num}{$enri_lev_type}
                > $enri_nucl_elem_href->{$mass_num}{min_depl_lev}
            )
        ) {
            # Reporting (1/2)
            if ($is_verbose) {
                printf(
                    "%-14s: [%f]\n",
                    'To be absorbed',
                    $to_be_absorbed,
                );
            }

            # c = a-(b-d)
            $remainder = $to_be_absorbed - $donatable;

            # b = d
            $enri_nucl_elem_href->{$mass_num}{$enri_lev_type} =
                $enri_nucl_elem_href->{$mass_num}{min_depl_lev};

            # a = c
            $to_be_absorbed = $remainder;

            # Reporting (2/2)
            if ($is_verbose) {
                printf(
                    "%-14s: [%f]\n",
                    "Donatable",
                    $donatable,
                );
                printf(
                    "%-14s: [%f] --> [%f]\n",
                    "$enri_lev_type",
                    $old_enri_lev,
                    $enri_nucl_elem_href->{$mass_num}{$enri_lev_type},
                );
                printf(
                    "%-14s: [%f]\n",
                    'Remainder',
                    $to_be_absorbed,
                );
                print "\n";
            }
        }

        # (iv) c = (b-d)-a ... (b > d "and" b-d > a "and" a != 0)
        elsif (
            $donatable > $to_be_absorbed
            and (
                $enri_nucl_elem_href->{$mass_num}{$enri_lev_type}
                > $enri_nucl_elem_href->{$mass_num}{min_depl_lev}
            )
            # To prevent unnecessary zero addition and subtraction
            and $to_be_absorbed
        ) {
            if ($is_verbose) {
                printf(
                    "The nuclide has a larger enrichment level, [%f],\n".
                    "than the enrichment level to be absorbed,  [%f].\n".
                    "Hence, we now absorb [%f] from [%f].\n",
                    $enri_nucl_elem_href->{$mass_num}{$enri_lev_type},
                    $to_be_absorbed,
                    $to_be_absorbed,
                    $enri_nucl_elem_href->{$mass_num}{$enri_lev_type},
                );
            }
            # c = b-a
            $remainder =
                $enri_nucl_elem_href->{$mass_num}{$enri_lev_type}
                - $to_be_absorbed;

            # b = c
            $enri_nucl_elem_href->{$mass_num}{$enri_lev_type} = $remainder;

            # a = 0, meaning that no enrichment level
            # is left to be transferred.
            $to_be_absorbed = 0;

            # Reporting
            if ($is_verbose) {
                printf(
                    "%-14s: [%f] --> [%f]\n",
                    "$enri_lev_type",
                    $old_enri_lev,
                    $enri_nucl_elem_href->{$mass_num}{$enri_lev_type},
                );
                printf(
                    "%-14s: [%f]\n",
                    'To be absorbed',
                    $to_be_absorbed,
                );
                print "\n";
            }
        }
    }

    #
    # Provide the nuclide of interest with the actual total donated 
    # enrichment level, which is ($to_be_absorbed_goal - $to_be_absorbed
    # remaining after the loop run). For example:
    # > $to_be_absorbed_goal = 0.9021
    # > $to_be_absorbed remaining after the loop = 0.0025
    #   which resulted from the minimum depletion levels of
    #   the nuclides other than the nuclide of interest.
    # > Therefore, 0.9021 - 0.0025 = 0.8996 will be the actual total donated
    #   enrichment level.
    #
    $old_enri_lev =
        $enri_nucl_elem_href->{$enri_nucl_mass_num}{$enri_lev_type};
    if ($is_verbose) {
        say "-" x 70;
        printf(
            "%-22s: [%s]\n",
            'Nuclide',
            $enri_nucl_elem_href->{$enri_nucl_mass_num}{label},
        );
        printf(
            "%-22s: [%s]\n",
            $enri_lev_type,
            $enri_nucl_elem_href->{$enri_nucl_mass_num}{$enri_lev_type},
        );
        printf(
            "%-22s: [%s]\n",
            'Min depletion level',
            $enri_nucl_elem_href->{$enri_nucl_mass_num}{min_depl_lev},
        );
        say "-" x 70;

        # Goal change of the enrichment level of the nuclide of interest
        printf(
            "%s: [%f] --> [%f]\n",
            "Goal $enri_lev_type",
            $old_enri_lev,
            $enri_lev,
        );
    }

    # The actual total donated enrichment level
    $to_be_absorbed_goal -= $to_be_absorbed;

    # Assign the actual total donated enrichment level
    # to the nuclide of interest.
    $enri_nucl_elem_href->{$enri_nucl_mass_num}{$enri_lev_type} +=
        $to_be_absorbed_goal;

    if ($is_verbose) {
        # Actual change of the enrichment level of the nuclide of interest
        printf(
            "%s: [%f] --> [%f]\n",
            "Actual $enri_lev_type",
            $old_enri_lev,
            $enri_nucl_elem_href->{$enri_nucl_mass_num}{$enri_lev_type},
        );

        # Notice if $to_be_absorbed is nonzero.
        if ($to_be_absorbed) {
            printf(
                "%s [%f] could not be collected".
                " because of the minimum depletion levels:\n",
                $enri_lev_type,
                $to_be_absorbed,
            );
            foreach my $mass_num (@{$enri_nucl_elem_href->{mass_nums}}) {
                next if $mass_num == $enri_nucl_mass_num;
                printf(
                    "[%s min_depl_lev] => [%f]\n",
                    $enri_nucl_elem_href->{$mass_num}{label},
                    $enri_nucl_elem_href->{$mass_num}{min_depl_lev},
                );
            }
            print "\n";
        }
    }

    pause_shell("Press enter to continue...") if $is_verbose;
    return;
}


sub calc_mat_molar_mass_and_subcomp_mass_fracs_and_dccs {
    # """Calculate the molar mass of a material,
    # mass fractions and masses of its constituent elements,
    # masses of the isotopes, and density change coefficients."""
    my (                 # e.g.
        $mat_href,       # %\moo3
        $enri_lev_type,  # 'amt_frac'
        $is_verbose,     # 1 (boolean)
        $run_mode,       # 'dcc_preproc'
    ) = @_;
    state $memorized = {};  # Memorize 'mass_frac_bef' for DCC calculation

    if ($is_verbose) {
        say "\n".("=" x 70);
        printf(
            "[%s]\n".
            "calculating the molar mass of [%s],\n".
            "mass fractions and masses of [%s], and\n".
            "masses and DCCs of the isotopes of [%s]...\n",
            join('::', (caller(0))[3]),
            $mat_href->{label},
            join(', ', @{$mat_href->{consti_elems}}),
            join(', ', @{$mat_href->{consti_elems}}),
        );
        say "=" x 70;
    }

    #
    # (1) Calculate the molar mass of the material,
    #     which depends on
    #   - the amounts of substance of the consistent elements:
    #     0 oxygen atom  for metallic Mo => Mo material mass == Mo mass
    #     2 oxygen atoms for MoO2        => Mo material mass >  Mo mass
    #     3 oxygen atoms for MoO3        => Mo material mass >> Mo mass
    #   - the weighted-average molar masses of the constituent elements,
    #     which are functions of their isotopic compositions, and
    #

    # Initialization
    $mat_href->{molar_mass} = 0;

    # $moo3{consti_elems} == ['mo', 'o']
    foreach my $elem_str (@{$mat_href->{consti_elems}}) {
        #     $moo3{molar_mass}
        $mat_href->{molar_mass} +=
            #            $moo3{mo}{amt_subs}
            #             $moo3{o}{amt_subs}
            $mat_href->{$elem_str}{amt_subs}
            #                          $mo{wgt_avg_molar_mass}
            #                           $o{wgt_avg_molar_mass}
            * $mat_href->{$elem_str}{href}{wgt_avg_molar_mass};
    }

    #
    # (2) Using the molar mass of the material obtained in (1), calculate
    #     the mass fraction and the mass of the constituent elements.
    #

    # $moo3{consti_elems} = ['mo', 'o']
    foreach my $elem_str (@{$mat_href->{consti_elems}}) {
        # (i) Mass fraction
        #            $moo3{mo}{mass_frac}
        #             $moo3{o}{mass_frac}
        $mat_href->{$elem_str}{mass_frac} =
            #            $moo3{mo}{amt_subs}
            #             $moo3{o}{amt_subs}
            $mat_href->{$elem_str}{amt_subs}
            #                          $mo{wgt_avg_molar_mass}
            #                           $o{wgt_avg_molar_mass}
            * $mat_href->{$elem_str}{href}{wgt_avg_molar_mass}
            #       $moo3{molar_mass}
            / $mat_href->{molar_mass};
        # (ii) Mass
        #            $moo3{mo}{mass}
        #             $moo3{o}{mass}
        $mat_href->{$elem_str}{mass} =
            #            $moo3{mo}{mass_frac}
            #             $moo3{o}{mass_frac}
            $mat_href->{$elem_str}{mass_frac}
            #       $moo3{mass}
            * $mat_href->{mass};
    }

    # $moo3{consti_elems} = ['mo', 'o']
    foreach my $elem_str (@{$mat_href->{consti_elems}}) {
        # $mo{mass_nums} = ['92', '94', '95', '96', '97', '98', '100']
        foreach my $mass_num (@{$mat_href->{$elem_str}{href}{mass_nums}}) {
            #
            # (3) Associate the fraction quantities of the isotopes
            #     to the materials hash.
            #

            #                    $moo3{mo92}{amt_frac}
            $mat_href->{$elem_str.$mass_num}{amt_frac} =  # Autovivified
                #                               $mo{92}{amt_frac}
                $mat_href->{$elem_str}{href}{$mass_num}{amt_frac};
            #                    $moo3{mo92}{mass_frac}
            $mat_href->{$elem_str.$mass_num}{mass_frac} =  # Autovivified
                #                               $mo{92}{mass_frac}
                $mat_href->{$elem_str}{href}{$mass_num}{mass_frac};

            #
            # (4) Calculate and associate the masses of the isotopes.
            #
            $mat_href->{$elem_str.$mass_num}{mass} =  # Autovivified
                #                    $moo3{mo92}{mass_frac}
                $mat_href->{$elem_str.$mass_num}{mass_frac}
                #              $moo3{mo}{mass}
                * $mat_href->{$elem_str}{mass};

            #***************************************************************
            #
            # (5) Calculate DCCs of the isotopes.
            #
            #***************************************************************

            # (a) If this routine was called as DCC preprocessing,
            #     create and memorize the 1st variable of an DCC.
            if ($run_mode and $run_mode =~ /dcc_preproc/i) {
                # (a-1) DCC in terms of amount fractions
                # $memorized{moo3}{mo92}{amt_frac_bef}
                $memorized->{$mat_href->{label}}
                            {$elem_str.$mass_num}
                            {amt_frac_bef} =
                    #                    $moo3{mo92}{amt_frac}
                    $mat_href->{$elem_str.$mass_num}{amt_frac};
                #               $memorized{moo3}{molar_mass_bef}
                $memorized->{$mat_href->{label}}{molar_mass_bef} =
                    #     $moo3{molar_mass}
                    $mat_href->{molar_mass};

                # (a-2) DCC in terms of mass fractions
                # $memorized{moo3}{mo92}{mass_frac_bef}
                $memorized->{$mat_href->{label}}
                            {$elem_str.$mass_num}
                            {mass_frac_bef} =
                    #                    $moo3{mo92}{mass_frac}
                    $mat_href->{$elem_str.$mass_num}{mass_frac};
                #                      $memorized{moo3}{mo}{mass_frac_bef}
                $memorized->{$mat_href->{label}}{$elem_str}{mass_frac_bef} =
                    #            $moo3{mo}{mass_frac}
                    $mat_href->{$elem_str}{mass_frac};
            }

            # (b) Assign the memorized 1st variable of the DCC.
            # (b-1) DCC in terms of amount fractions
            $mat_href->{$elem_str.$mass_num}{amt_frac_bef} =
                $memorized->{$mat_href->{label}}
                            {$elem_str.$mass_num}
                            {amt_frac_bef};
            $mat_href->{molar_mass_bef} =
                $memorized->{$mat_href->{label}}
                            {molar_mass_bef};

            # (b-2) DCC in terms of mass fractions
            $mat_href->{$elem_str.$mass_num}{mass_frac_bef} =
                $memorized->{$mat_href->{label}}
                            {$elem_str.$mass_num}
                            {mass_frac_bef};
            $mat_href->{$elem_str}{mass_frac_bef} =
                $memorized->{$mat_href->{label}}
                            {$elem_str}{mass_frac_bef};

            # (c) Assign the 2nd variable of the DCC.
            # (c-1) DCC in terms of amount fractions
            #                    $moo3{mo92}{amt_frac_aft}
            $mat_href->{$elem_str.$mass_num}{amt_frac_aft} =
                #                    $moo3{mo92}{amt_frac}
                $mat_href->{$elem_str.$mass_num}{amt_frac};
            #     $moo3{molar_mass_aft}
            $mat_href->{molar_mass_aft} =
                #     $moo3{molar_mass}
                $mat_href->{molar_mass};

            # (c-2) DCC in terms of mass fractions
            #                    $moo3{mo92}{mass_frac_aft}
            $mat_href->{$elem_str.$mass_num}{mass_frac_aft} =
                #                    $moo3{mo92}{mass_frac}
                $mat_href->{$elem_str.$mass_num}{mass_frac};
            #            $moo3{mo}{mass_frac_aft}
            $mat_href->{$elem_str}{mass_frac_aft} =
                #            $moo3{mo}{mass_frac}
                $mat_href->{$elem_str}{mass_frac};

            # (d) Calculate the DCC using (b) and (c) above.
            # (d-i) DCC in terms of amount fractions
            $mat_href->{$elem_str.$mass_num}{dcc} = (
                $mat_href->{$elem_str.$mass_num}{amt_frac_aft}
                / $mat_href->{$elem_str.$mass_num}{amt_frac_bef}
            ) * (
                $mat_href->{molar_mass_bef}
                / $mat_href->{molar_mass_aft}
            ) if $enri_lev_type eq 'amt_frac';

            # (d-ii) DCC in terms of mass fractions
            $mat_href->{$elem_str.$mass_num}{dcc} = (
                $mat_href->{$elem_str.$mass_num}{mass_frac_aft}
                / $mat_href->{$elem_str.$mass_num}{mass_frac_bef}
            ) * (
                $mat_href->{$elem_str}{mass_frac_aft}
                / $mat_href->{$elem_str}{mass_frac_bef}
            ) if $enri_lev_type eq 'mass_frac';
        }
    }

    if ($is_verbose) {
        dump($mat_href);
        pause_shell("Press enter to continue...");
    }

    return;
}


sub calc_mass_dens_and_num_dens {
    # """Calculate the number density of the material,
    # the mass and number densities of the constituent elements and
    # their isotopes."""
    my (                 # e.g.
        $mat_href,       # %\moo3
        $enri_lev_type,  # 'amt_frac'
        $is_verbose,     # 1 (boolean)
    ) = @_;
    my $avogadro = 6.02214076e+23;  # Number of substances per mole

    if ($is_verbose) {
        say "\n".("=" x 70);
        printf(
            "[%s]\n".
            "calculating the number density of [%s],\n".
            "the mass and number densities of [%s], and\n".
            "the mass and number densities of [%s] isotopes...\n",
            join('::', (caller(0))[3]),
            $mat_href->{label},
            join(', ', @{$mat_href->{consti_elems}}),
            join(', ', @{$mat_href->{consti_elems}}),
        );
        say "=" x 70;
    }

    #
    # (i) Material
    #

    # Number density
    $mat_href->{num_dens} =
        $mat_href->{mass_dens}  # Tabulated value
        * $avogadro
        # Below had been calculated in:
        # calc_mat_molar_mass_and_subcomp_mass_fracs_and_dccs()
        / $mat_href->{molar_mass};

    foreach my $elem_str (@{$mat_href->{consti_elems}}) {
        #
        # (ii) Constituent elements
        #

        # Mass density
        #            $moo3{mo}{mass_dens}
        #             $moo3{o}{mass_dens}
        $mat_href->{$elem_str}{mass_dens} =
            #            $moo3{mo}{mass_frac}
            #             $moo3{o}{mass_frac}
            $mat_href->{$elem_str}{mass_frac}
            #       $moo3{mass_dens}
            * $mat_href->{mass_dens};

        # Number density
        # (i) Using the amount fraction
        #            $moo3{mo}{num_dens}
        #             $moo3{o}{num_dens}
        $mat_href->{$elem_str}{num_dens} = (
            #            $moo3{mo}{amt_subs}
            #             $moo3{o}{amt_subs}
            $mat_href->{$elem_str}{amt_subs}  # Caution: Not 'amt_frac'
            #       $moo3{num_dens}
            * $mat_href->{num_dens}
        ) if $enri_lev_type eq 'amt_frac';

        # (ii) Using the mass fraction
        #            $moo3{mo}{num_dens}
        #             $moo3{o}{num_dens}
        $mat_href->{$elem_str}{num_dens} = (
            #            $moo3{mo}{mass_dens}
            #             $moo3{o}{mass_dens}
            $mat_href->{$elem_str}{mass_dens}
            * $avogadro
            #                          $mo{wgt_avg_molar_mass}
            #                           $o{wgt_avg_molar_mass}
            / $mat_href->{$elem_str}{href}{wgt_avg_molar_mass}
        ) if $enri_lev_type eq 'mass_frac';

        #
        # (iii) Isotopes of the consistent elements
        #

        # $mo{mass_nums} = ['92', '94', '95', '96', '97', '98', '100']
        foreach my $mass_num (@{$mat_href->{$elem_str}{href}{mass_nums}}) {
            # Mass density
            #                    $moo3{mo92}{mass_dens}
            $mat_href->{$elem_str.$mass_num}{mass_dens} =
                #                    $moo3{mo92}{mass_frac}
                $mat_href->{$elem_str.$mass_num}{mass_frac}
                #              $moo3{mo}{mass_dens}
                * $mat_href->{$elem_str}{mass_dens};

            # Number density
            # (i) Using the amount fraction
            #                    $moo3{mo92}{num_dens}
            $mat_href->{$elem_str.$mass_num}{num_dens} = (
                #                    $moo3{mo92}{amt_frac}
                $mat_href->{$elem_str.$mass_num}{amt_frac}
                #              $moo3{mo}{num_dens}
                * $mat_href->{$elem_str}{num_dens}
            ) if $enri_lev_type eq 'amt_frac';

            # (ii) Using the mass fraction
            #                    $moo3{mo92}{num_dens}
            $mat_href->{$elem_str.$mass_num}{num_dens} = (
                #                    $moo3{mo92}{mass_dens}
                $mat_href->{$elem_str.$mass_num}{mass_dens}
                * $avogadro
                #                                 $mo{92}{molar_mass}
                / $mat_href->{$elem_str}{href}{$mass_num}{molar_mass}
            ) if $enri_lev_type eq 'mass_frac';
        }
    }

    if ($is_verbose) {
        dump($mat_href);
        pause_shell("Press enter to continue...");
    }

    return;
}


sub adjust_num_of_decimal_places {
    # """Adjust the number of decimal places of calculation results."""
    my (
        $href_of_hashes,
        $precision_href,
        $enri_lev_range_first,
        # To work on non-mat chem entities. Make it bool-true if consecutive
        # calls of this routine are independent of each other.
        # (DO NOT make it bool-true for calls from enrimo!)
        $is_adjust_all,
    ) = @_;
    my $num_decimal_pts = length(substr($enri_lev_range_first, 2));

    my %fmt_specifiers = (
        #-------------------------------------------------
        # For reactant nuclide number density calculation
        #-------------------------------------------------
        molar_mass         => '%.5f',  # Molar mass of a nuclide or a material
        wgt_molar_mass     => '%.5f',  # Weighted molar mass of a nuclide
        wgt_avg_molar_mass => '%.5f',  # Weighted-avg molar mass of an element
        amt_frac           => '%.'.$num_decimal_pts.'f',
        mass_frac          => '%.'.$num_decimal_pts.'f',
        dens_ratio         => '%.5f',
        mass_dens          => '%.5f',
        num_dens           => '%.5e',
        vol                => '%.5f',
        mass               => '%.5f',
        dcc                => '%.4f',  # Density change coefficient
        #-----------------------
        # For yield calculation
        #-----------------------
        # Irradiation conditions
        avg_beam_curr => '%.2f',
        end_of_irr    => '%.3f',
        # Pointwise multiplication
        nrg_ev        => '%.6e',
        nrg_mega_ev   => '%.6f',
        # >> For array refs
        ev            => '%.6e',
        mega_ev       => '%.6f',
        proj          => '%.6e',
        barn          => '%.6f',
        'cm^2'        => '%.6e',
        'cm^-1'       => '%.6e',
        # <<
        de            => '%.6f',
        xs_micro      => '%.6e',
        xs_macro      => '%.6e',
        mc_flue       => '%.6e',
        # PWM
        pwm_micro     => '%.6e',
        pwm_micro_tot => '%.6e',
        pwm_macro     => '%.6e',
        pwm_macro_tot => '%.6e',
        # Rates
        source_rate   => '%.6e',
        reaction_rate => '%.6e',  # For backward compatibility
        react_rate_per_vol     => '%.6e',
        react_rate_per_vol_tot => '%.6e',
        react_rate             => '%.6e',
        react_rate_tot         => '%.6e',
        # Yields
        yield                      => '%.2f',
        yield_per_microamp         => '%.2f',
        sp_yield                   => '%.2f',
        sp_yield_per_microamp      => '%.2f',
        sp_yield_per_microamp_hour => '%.2f',
    );
    # Override the format specifiers if any have been
    # designated via the input file.
    $fmt_specifiers{$_} = $precision_href->{$_} for keys %$precision_href;

    # Memorandum
    # - "DO NOT" change the number of decimal places of the element hashes.
    #   If adjusted, the modified precision remains changed in the consecutive
    #   calls of this routine, affecting all the other subsequent calculations
    #   that use the attributes of the element hashes.
    # - Instead, work ONLY on the materials hashes which will be recalculated
    #   each time before this routine is called.
    foreach my $attr (keys %fmt_specifiers) {
        # $k1 == o, mo, momet, moo2, moo3...
        foreach my $k1 (keys %$href_of_hashes) {
            #******************************************************************
            # Work ONLY on materials.
            # > Exception: If $is_adjust_all is bool-true, the conditional
            #   block is skipped for non-mat chem entities.
            #   > This is a hook for phitar.
            #   > DO NOT make $is_adjust_all bool-true for calls from enrimo!
            #******************************************************************
            if (not defined $is_adjust_all or $is_adjust_all != 1) {
                next unless $href_of_hashes->{$k1}{data_type} =~ /mat/i;
            }

            if (exists $href_of_hashes->{$k1}{$attr}) {
                # Scalar variable (enrimo)
                if (ref \$href_of_hashes->{$k1}{$attr} eq SCALAR) {
                    #            $moo3{mass_dens}
                    $href_of_hashes->{$k1}{$attr} = sprintf(
                        "$fmt_specifiers{$attr}",
                        $href_of_hashes->{$k1}{$attr},
                    );
                }
                # Scalar reference (phitar)
                elsif (ref $href_of_hashes->{$k1}{$attr} eq SCALAR) {
                    # {href_of_unbound_to_href}{avg_beam_curr}
                    ${$href_of_hashes->{$k1}{$attr}} = sprintf(
                        "$fmt_specifiers{$attr}",
                        ${$href_of_hashes->{$k1}{$attr}},
                    );
                }
                # Array reference (phitar)
                elsif (ref $href_of_hashes->{$k1}{$attr} eq ARRAY) {
                    for (
                        my $i=0;
                        #             $mc_flue{nrg}{mega_ev}
                        $i<=$#{$href_of_hashes->{$k1}{$attr}};
                        $i++
                    ) {
                        $href_of_hashes->{$k1}{$attr}[$i] = sprintf(
                            "$fmt_specifiers{$attr}",
                            $href_of_hashes->{$k1}{$attr}[$i],
                        );
                    }
                }
            }

            # $k2 == mass_dens, HASH (<= mo, o, mo92, ...)
            foreach my $k2 (%{$href_of_hashes->{$k1}}) {
                # If $k2 == HASH (<= mo, o, mo92, ...)
                if (
                    ref $k2 eq HASH
                    and exists $k2->{$attr}
                    and ref \$k2->{$attr} eq SCALAR
                ) {
                    # Increase the number of decimal points of the Mo mass
                    # fraction "if" it is smaller than 5. This is to
                    # smoothen the curve of the Mo mass fraction of Mo oxides.
                    # e.g. Mo mass frac 0.6666 --> 0.66656
                    #      at Mo-100 mass frac 0.10146
                    if (
                        $num_decimal_pts < 5
                        and $attr eq 'mass_frac'
                        and exists $k2->{href}  # $moo3{mo} and $moo3{o} only
                        and $k2->{href}{label} eq 'mo'  # $moo3{mo} only
                    ) {
                        # $moo3{mo}{mass_frac}
                        $k2->{$attr} = sprintf(
                            "%.5f",
                            $k2->{$attr},
                        );
                    }

                    else {
                        # $moo3{mo}{amt_subs}
                        $k2->{$attr} = sprintf(
                            "$fmt_specifiers{$attr}",
                            $k2->{$attr},
                        );
                    }
                }
            }
        }
    }

    return;
}


sub assoc_prod_nucls_with_reactions_and_dccs {
    # """Associate product nuclides with nuclear reactions and DCCs."""
    my (
        $chem_hrefs,            # e.g.
        $mat,                   # 'moo3'
        $enri_nucl,             # 'mo100'
        $enri_lev,              # 0.0974
        $enri_lev_range_first,  # 0.0000
        $enri_lev_range_last,   # 0.9739
        $enri_lev_type,         # 'amt_frac'
        $depl_order,            # 'ascend'
        $out_path,              # './mo100'
        $projs,                 # ['g', 'n', 'p']
        $is_verbose,            # 1 (boolean)
    ) = @_;
    my $mat_href = $chem_hrefs->{$mat},  # \%moo3

    my %elems = (
        # (key) Atomic number
        # (val) Element name and symbol
        30 => {symb => 'Zn', name => 'zinc'     },
        31 => {symb => 'Ga', name => 'gallium'  },
        32 => {symb => 'Ge', name => 'germanium'},
        33 => {symb => 'As', name => 'arsenic'  },
        34 => {symb => 'Se', name => 'selenium' },
        35 => {symb => 'Br', name => 'bromine'  },
        36 => {symb => 'Kr', name => 'krypton'  },
        37 => {symb => 'Rb', name => 'rubidium' },
        38 => {
            symb => 'Sr',
            name => 'strontium',
            75 => {
                half_life => 1.97222e-05,
            },
            76 => {
                half_life => 0.002472222,
            },
            77 => {
                half_life => 0.0025,
            },
            78 => {
                half_life => 0.041666667,
            },
            79 => {
                half_life => 0.0375,
            },
            80 => {
                half_life => 1.771666667,
            },
            81 => {
                half_life => 0.371666667,
            },
            82 => {
                half_life => 613.2,
            },
            83 => {
                half_life => 32.41,
            },
            '83m' => {
                half_life => 0.001375,
            },
            84 => {
                half_life => 'stable',
            },
            85 => {
                half_life => 1556.16,
            },
            '85m' => {
                half_life => 1.127166667,
            },
            86 => {
                half_life => 'stable',
            },
            87 => {
                half_life => 'stable',
            },
            '87m' => {
                half_life => 2.803,
            },
            88 => {
                half_life => 'stable',
            },
            89 => {
                half_life => 1212.72,
            },
            90 => {
                half_life => 252200.4,
            },
            91 => {
                half_life => 9.63,
            },
            92 => {
                half_life => 2.71,
            },
            93 => {
                half_life => 0.123716667,
            },
            94 => {
                half_life => 0.020916667,
            },
            95 => {
                half_life => 0.006638889,
            },
            96 => {
                half_life => 0.000297222,
            },
            97 => {
                half_life => 0.000118333,
            },
            98 => {
                half_life => 0.000181389,
            },
            99 => {
                half_life => 7.47222e-05,
            },
            100 => {
                half_life => 5.61111e-05,
            },
            101 => {
                half_life => 3.27778e-05,
            },
            102 => {
                half_life => 1.91667e-05,
            },
        },
        39 => {
            symb => 'Y',
            name => 'yttrium',
            79 => {
                half_life => 0.004111111,
            },
            80 => {
                half_life => 0.009722222,
            },
            81 => {
                half_life => 0.019555556,
            },
            82 => {
                half_life => 0.002638889,
            },
            83 => {
                half_life => 0.118,
            },
            '83m' => {
                half_life => 0.0475,
            },
            84 => {
                half_life => 0.001277778,
            },
            '84m' => {
                half_life => 0.658333333,
            },
            85 => {
                half_life => 2.68,
            },
            '85m' => {
                half_life => 4.86,
            },
            86 => {
                half_life => 14.74,
            },
            '86m' => {
                half_life => 0.8,
            },
            87 => {
                half_life => 79.8,
            },
            '87m' => {
                half_life => 13.37,
            },
            88 => {
                half_life => 2559.6,
            },
            '88m' => {
                half_life => 3.86111e-06,
            },
            89 => {
                half_life => 'stable',
            },
            '89m' => {
                half_life => 0.004461111,
            },
            90 => {
                half_life => 64,
            },
            '90m' => {
                half_life => 3.19,
            },
            91 => {
                half_life => 1404.24,
            },
            '91m' => {
                half_life => 0.8285,
            },
            92 => {
                half_life => 3.54,
            },
            93 => {
                half_life => 10.18,
            },
            '93m' => {
                half_life => 0.000227778,
            },
            94 => {
                half_life => 0.311666667,
            },
            95 => {
                half_life => 0.171666667,
            },
            96 => {
                half_life => 0.001483333,
            },
            '96m' => {
                half_life => 0.002666667,
            },
            97 => {
                half_life => 0.001041667,
            },
            '97m' => {
                half_life => 0.000325,
            },
            98 => {
                half_life => 0.000152222,
            },
            '98m' => {
                half_life => 0.000555556,
            },
            99 => {
                half_life => 0.000408333,
            },
            100 => {
                half_life => 0.000204722,
            },
            '100m' => {
                half_life => 0.000261111,
            },
            101 => {
                half_life => 0.000125,
            },
            102 => {
                half_life => 0.0001,
            },
            '102m' => {
                half_life => 8.33333e-05,
            },
            103 => {
                half_life => 6.38889e-05,
            },
        },
        40 => {
            symb => 'Zr',
            name => 'zirconium',
            81 => {
                half_life => 0.004166667,
            },
            82 => {
                half_life => 0.008888889,
            },
            83 => {
                half_life => 0.012222222,
            },
            84 => {
                half_life => 0.431666667,
            },
            85 => {
                half_life => 0.131,
            },
            '85m' => {
                half_life => 0.003027778,
            },
            86 => {
                half_life => 16.5,
            },
            87 => {
                half_life => 1.68,
            },
            '87m' => {
                half_life => 0.003888889,
            },
            88 => {
                half_life => 2001.6,
            },
            89 => {
                half_life => 78.41,
            },
            '89m' => {
                half_life => 0.069666667,
            },
            90 => {
                half_life => 'stable',
            },
            '90m' => {
                half_life => 0.000224778,
            },
            91 => {
                half_life => 'stable',
            },
            92 => {
                half_life => 'stable',
            },
            93 => {
                half_life => 13402.8,
            },
            94 => {
                half_life => 'stable',
            },
            95 => {
                half_life => 1536.48,
            },
            96 => {
                half_life => 3.3288e23,
            },
            97 => {
                half_life => 16.91,
            },
            98 => {
                half_life => 0.008527778,
            },
            99 => {
                half_life => 0.000583333,
            },
            100 => {
                half_life => 0.001972222,
            },
            101 => {
                half_life => 0.000638889,
            },
            102 => {
                half_life => 0.000805556,
            },
            103 => {
                half_life => 0.000361111,
            },
            104 => {
                half_life => 0.000333333,
            },
            105 => {
                half_life => 0.000166667,
            },
        },
        41 => {
            symb => 'Nb',
            name => 'niobium',
            83 => {
                half_life => 0.001138889,
            },
            84 => {
                half_life => 0.003333333,
            },
            85 => {
                half_life => 0.005805556,
            },
            86 => {
                half_life => 0.024444444,
            },
            '86m' => {
                half_life => 0.015555556,
            },
            87 => {
                half_life => 0.043333333,
            },
            '87m' => {
                half_life => 0.061666667,
            },
            88 => {
                half_life => 0.241666667,
            },
            '88m' => {
                half_life => 0.13,
            },
            89 => {
                half_life => 1.9,
            },
            '89m' => {
                half_life => 1.18,
            },
            90 => {
                half_life => 14.6,
            },
            '90m' => {
                half_life => 0.005225,
            },
            91 => {
                half_life => 5956800,
            },
            '91m' => {
                half_life => 1460.64,
            },
            92 => {
                half_life => 3.03972e11,
            },
            '92m' => {
                half_life => 243.6,
            },
            93 => {
                half_life => 'stable',
            },
            '93m' => {
                half_life => 141298.8,
            },
            94 => {
                half_life => 177828000,
            },
            '94m' => {
                half_life => 0.104383333,
            },
            95 => {
                half_life => 839.4,
            },
            '95m' => {
                half_life => 86.6,
            },
            96 => {
                half_life => 23.35,
            },
            97 => {
                half_life => 1.201666667,
            },
            '97m' => {
                half_life => 0.014638889,
            },
            98 => {
                half_life => 0.000794444,
            },
            '98m' => {
                half_life => 0.855,
            },
            99 => {
                half_life => 0.004166667,
            },
            '99m' => {
                half_life => 0.043333333,
            },
            100 => {
                half_life => 0.000416667,
            },
            '100m' => {
                half_life => 0.000830556,
            },
            101 => {
                half_life => 0.001972222,
            },
            102 => {
                half_life => 0.000361111,
            },
            '102m' => {
                half_life => 0.001194444,
            },
            103 => {
                half_life => 0.000416667,
            },
            104 => {
                half_life => 0.001333333,
            },
            '104m' => {
                half_life => 0.000255556,
            },
            105 => {
                half_life => 0.000819444,
            },
            106 => {
                half_life => 0.000283333,
            },
            107 => {
                half_life => 9.16667e-05,
            },
            108 => {
                half_life => 5.36111e-05,
            },
            109 => {
                half_life => 5.27778e-05,
            },
            110 => {
                half_life => 4.72222e-05,
            },
        },
        42 => {
            symb => 'Mo',
            name => 'molybdenum',
            86 => {
                half_life => 0.005444444,
            },
            87 => {
                half_life => 0.003722222,
            },
            88 => {
                half_life => 0.133333333,
            },
            89 => {
                half_life => 0.034,
            },
            '89m' => {
                half_life => 5.27778e-05,
            },
            90 => {
                half_life => 5.56,
            },
            91 => {
                half_life => 0.258166667,
            },
            '91m' => {
                half_life => 0.018055556,
            },
            92 => {
                half_life => 'stable',
            },
            93 => {
                half_life => 35040000,
            },
            '93m' => {
                half_life => 6.85,
            },
            94 => {
                half_life => 'stable',
            },
            95 => {
                half_life => 'stable',
            },
            96 => {
                half_life => 'stable',
            },
            97 => {
                half_life => 'stable',
            },
            98 => {
                half_life => 'stable',
            },
            99 => {
                half_life => 65.94,
            },
            100 => {
                half_life => 8.76e22,
            },
            101 => {
                half_life => 0.2435,
            },
            102 => {
                half_life => 0.188333333,
            },
            103 => {
                half_life => 0.01875,
            },
            104 => {
                half_life => 0.016666667,
            },
            105 => {
                half_life => 0.009888889,
            },
            106 => {
                half_life => 0.002333333,
            },
            107 => {
                half_life => 0.000972222,
            },
            108 => {
                half_life => 0.000302778,
            },
            109 => {
                half_life => 0.000147222,
            },
            110 => {
                half_life => 8.33333e-05,
            },
        },
        43 => {
            symb => 'Tc',
            name => 'technetium',
            88 => {
                half_life => 0.001777778,
            },
            '88m' => {
                half_life => 0.001611111,
            },
            89 => {
                half_life => 0.003555556,
            },
            '89m' => {
                half_life => 0.003583333,
            },
            90 => {
                half_life => 0.013666667,
            },
            '90m' => {
                half_life => 0.002416667,
            },
            91 => {
                half_life => 0.052333333,
            },
            '91m' => {
                half_life => 0.055,
            },
            92 => {
                half_life => 0.0705,
            },
            93 => {
                half_life => 2.75,
            },
            '93m' => {
                half_life => 0.725,
            },
            94 => {
                half_life => 4.883333333,
            },
            '94m' => {
                half_life => 0.866666667,
            },
            95 => {
                half_life => 20,
            },
            '95m' => {
                half_life => 1464,
            },
            96 => {
                half_life => 102.72,
            },
            '96m' => {
                half_life => 51.5,
            },
            97 => {
                half_life => 22776000000,
            },
            '97m' => {
                half_life => 2162.4,
            },
            98 => {
                half_life => 36792000000,
            },
            99 => {
                half_life => 1849236000,
            },
            '99m' => {
                half_life => 6.01,
            },
            100 => {
                half_life => 0.004388889,
            },
            101 => {
                half_life => 0.237,
            },
            102 => {
                half_life => 0.001466667,
            },
            '102m' => {
                half_life => 0.0725,
            },
            103 => {
                half_life => 0.015055556,
            },
            104 => {
                half_life => 0.305,
            },
            105 => {
                half_life => 0.126666667,
            },
            106 => {
                half_life => 0.009888889,
            },
            107 => {
                half_life => 0.005888889,
            },
            108 => {
                half_life => 0.001436111,
            },
            109 => {
                half_life => 0.000241667,
            },
            110 => {
                half_life => 0.000255556,
            },
            111 => {
                half_life => 8.33333e-05,
            },
            112 => {
                half_life => 7.77778e-05,
            },
            113 => {
                half_life => 3.61111e-05,
            },
        },
        44 => {symb => 'Ru', name => 'ruthenium' },
        45 => {symb => 'Rh', name => 'rhodium'   },
        46 => {symb => 'Pd', name => 'palladium' },
        47 => {symb => 'Ag', name => 'silver'    },
        48 => {symb => 'Cd', name => 'cadmium'   },
        49 => {symb => 'In', name => 'indium'    },
        50 => {symb => 'Sn', name => 'tin'       },
    );
    my %prod_nucls;  # Storage for product nuclides
    my %parts = (
        # Homogeneous: Ejectiles are multiplied by integers in the loop below.
        g => {
            name     => 'gamma',
            num_neut => 0,
            num_prot => 0,
            max_ejec => {
                # (key) projectile
                # (val) max_ejec
                g => 1,
                n => 1,
                p => 1,
            },
        },
        n => {
            name     => 'neutron',
            num_neut => 1,
            num_prot => 0,
            max_ejec => {
                g => 3,
                n => 3,
                p => 3,
            },
        },
        p => {
            name     => 'proton',
            num_neut => 0,
            num_prot => 1,
            max_ejec => {
                g => 1,
                n => 3,
                p => 2,
            },
        },
        d => {
            name     => 'deuteron',
            num_neut => 1,
            num_prot => 1,
            max_ejec => {
                g => 1,
                n => 1,
                p => 1,
            },
        },
        t => {
            name     => 'triton',
            num_neut => 2,
            num_prot => 1,
            max_ejec => {
                g => 1,
                n => 1,
                p => 1,
            },
        },
        a => {
            name     => 'alpha',
            num_neut => 2,
            num_prot => 2,
            max_ejec => {
                g => 1,
                n => 1,
                p => 1,
            },
        },

        # Heterogeneous: Number of ejectiles are invariable.
        np => {  # For neutron reactions
            num_neut => 1,
            num_prot => 1,
        },
        pn => {  # For proton reactions
            num_neut => 1,
            num_prot => 1,
        },
        an => {
            num_neut => 3,
            num_prot => 2,
        },
        ann => {
            num_neut => 4,
            num_prot => 2,
        },
        ap => {
            num_neut => 2,
            num_prot => 3,
        },
        app => {
            num_neut => 2,
            num_prot => 4,
        },
    );

    # Homogeneous ejectiles
    my %ejecs = (
        # (key) projectile
        # (val) ejecs_hetero
        g => [qw(g n p a)],
        n => [qw(g n p d t a)],
        p => [qw(g n p d t a)],
    );
    # Heterogeneous ejectiles
    my %ejecs_hetero = (
        # (key) projectile
        # (val) ejecs_hetero
        g => [qw(np)],
        n => [qw(np an ann ap app)],
        p => [qw(pn an ann ap)],
    );

    #
    # (1/2) Arithmetic for nuclear reaction channels
    #

    # $moo3{consti_elems} = ['mo', 'o']
    foreach my $elem_str (@{$mat_href->{consti_elems}}) {
        # Redirect the atomic number of the constituent element
        # for clearer coding.
        my $atomic_num = $mat_href->{$elem_str}{href}{atomic_num};

        # $mo{mass_nums} = ['92', '94', '95', '96', '97', '98', '100']
        foreach my $mass_num (@{$mat_href->{$elem_str}{href}{mass_nums}}) {
            # ('g', 'n', 'p')
            foreach my $proj (@$projs) {
                # Homogeneous ejectiles
                # e.g. ('g', 'n', 'p', 'd', 't', 'a')
                foreach my $ejec (@{$ejecs{$proj}}) {
                    foreach my $num_ejec (1..$parts{$ejec}{max_ejec}{$proj}) {
                        # Atomic number of the product nuclide
                        my $new_atomic_num =
                            $atomic_num
                            + $parts{$proj}{num_prot}
                            - $num_ejec * $parts{$ejec}{num_prot};

                        # Mass number of the product nuclide
                        my $new_mass_num =
                            $mass_num
                            + $parts{$proj}{num_neut}
                            + $parts{$proj}{num_prot}
                            - $num_ejec * $parts{$ejec}{num_neut}
                            - $num_ejec * $parts{$ejec}{num_prot};

                        # Autovivified
                        my $reaction = sprintf(
                            "%s%s%s%s%s",
                            $elem_str,
                            $mass_num,
                            $proj,
                            ($num_ejec > 1 ? $num_ejec : ''),
                            $ejec,
                        );
                        # Skip nn, pp, ...
                        next if $num_ejec == 1 and $proj eq $ejec;
                        $prod_nucls{$proj}{$new_atomic_num}
                                   {$new_mass_num}{$reaction} =
                                $mat_href->{$elem_str.$mass_num}{dcc};
                    }
                }

                # Heterogeneous ejectiles
                # e.g. ('np', 'an', 'ann', 'ap', 'app')
                foreach my $ejecs (@{$ejecs_hetero{$proj}}) {
                    # Atomic number of the product nuclide
                    my $new_atomic_num =
                        $atomic_num
                        + $parts{$proj}{num_prot}
                        - $parts{$ejecs}{num_prot};

                    # Mass number of the product nuclide
                    my $new_mass_num =
                        $mass_num
                        + $parts{$proj}{num_neut}
                        + $parts{$proj}{num_prot}
                        - $parts{$ejecs}{num_neut}
                        - $parts{$ejecs}{num_prot};

                    # Autovivified
                    my $reaction = sprintf(
                        "%s%s%s%s",
                        $elem_str,
                        $mass_num,
                        $proj,
                        $ejecs,
                    );
                    $prod_nucls
                        {$proj}{$new_atomic_num}{$new_mass_num}{$reaction} =
                            $mat_href->{$elem_str.$mass_num}{dcc};
                }
            }
        }
    }

    #
    # (2/2) Generate reporting files.
    #
    my %convs = (
        isot      => '%-3s',
        half_life => '%7.1f',
        stable    => '%8s',  # 7.1f => 8s
        react     => '%-10s',
    );
    my %seps = (
        col        => "  ",  # or: \t
        data_block => "\n",
        dataset    => "\n\n",
    );
    my $not_a_number = "NaN";
    my %filters = (
        half_lives => {
            min => 10 / 60,   # h; 10 min
            max => 24 * 365,  # h; 1 y
        },
        stable => 'off',  # on:show stable nucl
    );
    state $is_first = 1;  # Hook - onetime on
    foreach my $proj (@$projs) {
        mkdir $out_path if not -e $out_path;
        (my $from = $enri_lev_range_first) =~ s/[.]/p/;
        (my $to   = $enri_lev_range_last)  =~ s/[.]/p/;
        my $nucls_rpt_bname = sprintf(
            "%s_%s_%s_%s_%s_%s_%s",
            $mat,
            $enri_nucl,
            $enri_lev_type,
            $from,
            $to,
            (
                $depl_order =~ /asc/i  ? 'asc' :
                $depl_order =~ /desc/i ? 'desc' :
                                         'rand'
            ),
            $proj,
        );
        my $nucls_rpt_fname = "$out_path/$nucls_rpt_bname.dat";
        unlink $nucls_rpt_fname if -e $nucls_rpt_fname and $is_first;

        open my $nucls_rpt_fh, '>>:encoding(UTF-8)', $nucls_rpt_fname;
        select($nucls_rpt_fh);

        # Front matter and warnings
        if ($is_first) {
            my $dt = DateTime->now(time_zone => 'local');
            my $ymd = $dt->ymd();
            my $hms = $dt->hms(':');
            say "#".("-" x 79);
            say "#";
            printf(
                "# Product nuclides of Mo %s reactions associated with DCCs\n",
                $parts{$proj}{name},
            );
            say "# Generated by $0 (J. Jang)";
            printf("# %s %s\n", $ymd, $hms);
            say "#";
            say "# Display conditions for product nuclides";
            printf(
                "# > Min half-life:  %.5e h (%.5e m; %.5e y)\n",
                $filters{half_lives}{min},
                $filters{half_lives}{min} * 60,
                $filters{half_lives}{min} / 24 / 365,
            );
            printf(
                "# > Max half-life:  %.5e h (%.5e m; %.5e y)\n",
                $filters{half_lives}{max},
                $filters{half_lives}{max} * 60,
                $filters{half_lives}{max} / 24 / 365,
            );
            say "# > Stable nuclide: $filters{stable}";
            say "#";
            say "#".("-" x 79);
        }

        # Dataset header: Current enrichment level
        print $seps{dataset} unless $is_first;  # Dataset separator
        say "#".("=" x 79);
        printf(
            "# [%s] <= %s %s in %s\n",
            $enri_lev,
            $enri_nucl,
            $enri_lev_type,
            $mat,
        );
        say "#".("=" x 79);

        # Layer 1: Chemical element
        my @elems_asc =
            sort { $a <=> $b } keys %{$prod_nucls{$proj}};
        # 39, 40, 41, ... (atomic number)
        foreach my $elem (@elems_asc) {
            # Data block header: Atomic number
            say "#".("-" x 79);
            print "# Z = $elem";
            print $elems{$elem}{symb} ? " ($elems{$elem}{symb}" : "";
            print $elems{$elem}{name} ? "; $elems{$elem}{name}" : "";
            print $elems{$elem}{symb} ? ")" : "";
            print "\n";
            say "#".("-" x 79);

            # Layer 2: Isotope
            my @isots_asc =
                sort { $a <=> $b } keys %{$prod_nucls{$proj}{$elem}};
            foreach my $isot (@isots_asc) {
                # Layer 3: Isotope and its isomer
                my @the_isots = ($isot);
                if (
                    exists $elems{$elem}{$isot.'m'}
                    and (
                        $elems{$elem}{$isot.'m'}{half_life}
                        > $filters{half_lives}{min}
                    )
                    and (
                        $elems{$elem}{$isot.'m'}{half_life}
                        < $filters{half_lives}{max}
                    )
                ) { push @the_isots, $isot.'m' }
                foreach my $the_isot (@the_isots) {
                    # Filtering
                    if ($elems{$elem}{$the_isot}{half_life}) {
                        next if (
                            $elems{$elem}{$the_isot}{half_life} =~ /stable/i
                            and not $filters{stable} =~ /on/i
                        );
                        next if (
                            $elems{$elem}{$the_isot}{half_life} =~ /[0-9]+/
                            and (
                                $elems{$elem}{$the_isot}{half_life}
                                < $filters{half_lives}{min}
                            )
                        );
                        next if (
                            $elems{$elem}{$the_isot}{half_life} =~ /[0-9]+/
                            and (
                                $elems{$elem}{$the_isot}{half_life}
                                > $filters{half_lives}{max}
                            )
                        );
                    }

                    # Mass number
                    printf(
                        "$convs{isot}%s",
                        $the_isot,
                        $seps{col},
                    );

                    # Half-life
                    printf(
                        (
                            $elems{$elem}{$the_isot}{half_life} =~ /[0-9]+/ ?
                                $convs{half_life}."h" : $convs{stable}
                        ),
                        $elems{$elem}{$the_isot}{half_life},
                    ) if $elems{$elem}{$the_isot}{half_life};
                    print $not_a_number
                        if not $elems{$elem}{$the_isot}{half_life};
                    print $seps{col};

                    # Layer 3: Nuclear reaction
                    (my $isot = $the_isot) =~ s/m$//i;
                    my @reacts_sorted =
                        sort keys %{$prod_nucls{$proj}{$elem}{$isot}};
                    foreach my $react (@reacts_sorted) {
                        printf(
                            "$convs{react}%s%s%s",
                            $react,
                            $seps{col},
                            $prod_nucls{$proj}{$elem}{$isot}{$react},
                            ($react eq $reacts_sorted[-1] ? "" : $seps{col}),
                        );
                    }
                    print "\n";
                }
            }
            print $seps{data_block} unless $elem == $elems_asc[-1];
        }

        select(STDOUT);
        close $nucls_rpt_fh;

        if ($enri_lev == $enri_lev_range_last) {
            say "[$nucls_rpt_fname] generated.";
        }
    }
    $is_first = 0;  # Hook - off

    if ($is_verbose) {
        dump(\%prod_nucls);
        pause_shell("Press enter to continue...");
    }

    return;
}


sub gen_chem_hrefs {
    # """Generate href of chemical data hrefs."""

    #
    # Notes
    #
    # Abbreviations
    # - TBC: To be calculated
    # - TBF: To be filled
    # - TBP: To be passed
    #
    # Idiosyncrasies
    # - Naturally occurring nuclides of a chemical element are registered
    #   to the element hash by their mass numbers as the hash keys.
    #   Also, an anonymous array of these keys is registered to the element
    #   hash by 'mass_nums' as the hash key. This array plays important roles
    #   throughout the program; examples include weighted-average molar mass
    #   calculation and enrichment level redistribution. Also,
    #   the use of the array enables changing the order of the nuclides
    #   to be depleted in the process of the enrichment of a specific nuclide.
    #

    #==========================================================================
    # Data: Chemical elements
    #==========================================================================
    #--------------------------------------------------------------------------
    # Z=8: oxygen
    #--------------------------------------------------------------------------
    my %o = (
        data_type  => 'elem',  # Used for decimal places adjustment (postproc)
        atomic_num => 8,       # Used for nuclide production mapping
        label      => 'o',     # Used for referring to the hash name
        symb       => 'O',     # Used for output files
        name       => 'oxygen',
        mass_frac_sum      => 0,  # TBC; used for mass-fraction weighting
        wgt_avg_molar_mass => 0,  # TBC
        # Naturally occurring isotopes of this element
        # - Used for the calculation of its weighted-average molar mass
        #   and for enrichment level redistribution.
        # - Put the nuclides in the ascending order of mass number.
        mass_nums => [  # Iteration control; values must be keys of this hash
            '16',
            '17',
            '18',
        ],
        # amt_frac
        # - Natural abundance by "amount" fraction found in
        #   http://www.ciaaw.org/isotopic-abundances.htm
        #
        # mass_frac
        # - Calculated based on the amount fraction above
        #
        # molar_mass
        # - Atomic mass found in
        #   - http://www.ciaaw.org/atomic-masses.htm
        #   - wang2017.pdf
        '16' => {
            data_type      => 'nucl',
            mass_num       => 16,
            label          => 'o16',
            symb           => 'O-16',
            name           => 'oxygen-16',
            amt_frac       => 0.99757,
            mass_frac      => 0,             # TBC
            molar_mass     => 15.994914619,  # g mol^-1
            wgt_molar_mass => 0,             # TBC
        },
        '17' => {
            data_type      => 'nucl',
            mass_num       => 17,
            label          => 'o17',
            symb           => 'O-17',
            name           => 'oxygen-17',
            amt_frac       => 0.0003835,
            mass_frac      => 0,
            molar_mass     => 16.999131757,
            wgt_molar_mass => 0,
        },
        '18' => {
            data_type      => 'nucl',
            mass_num       => 18,
            label          => 'o18',
            symb           => 'O-18',
            name           => 'oxygen-18',
            amt_frac       => 0.002045,
            mass_frac      => 0,
            molar_mass     => 17.999159613,
            wgt_molar_mass => 0,
        },
    );
    #--------------------------------------------------------------------------
    # Z=40: zirconium
    #--------------------------------------------------------------------------
    my %zr = (
        data_type          => 'elem',
        atomic_num         => 40,
        label              => 'zr',
        symb               => 'Zr',
        name               => 'zirconium',
        mass_frac_sum      => 0,
        wgt_avg_molar_mass => 0,
        mass_nums => [
            '90',
            '91',
            '92',
            '94',
            '96',
        ],
        '90' => {
            data_type      => 'nucl',
            mass_num       => 90,
            label          => 'zr90',
            symb           => 'Zr-90',
            name           => 'zirconium-90',
            amt_frac       => 0.5145,
            mass_frac      => 0,
            molar_mass     => 89.90469876,
            wgt_molar_mass => 0,
        },
        '90m' => {
            data_type => 'nucl',
            mass_num  => 90,
            label     => 'zr90m',
            symb      => 'Zr-90m',
            name      => 'zirconium-90m',
            # Radioactive
            half_life => (809.2e-3 / 3600),           # h
            dec_const => log(2) / (809.2e-3 / 3600),  # h^-1
            yield                      => 0,  # TBC
            yield_per_microamp         => 0,  # TBC
            sp_yield                   => 0,  # TBC
            sp_yield_per_microamp      => 0,  # TBC
            sp_yield_per_microamp_hour => 0,  # TBC
        },
        '91' => {
            data_type      => 'nucl',
            mass_num       => 91,
            label          => 'zr91',
            symb           => 'Zr-91',
            name           => 'zirconium-91',
            amt_frac       => 0.1122,
            mass_frac      => 0,
            molar_mass     => 90.90564022,
            wgt_molar_mass => 0,
        },
        '92' => {
            data_type      => 'nucl',
            mass_num       => 92,
            label          => 'zr92',
            symb           => 'Zr-92',
            name           => 'zirconium-92',
            amt_frac       => 0.1715,
            mass_frac      => 0,
            molar_mass     => 91.90503532,
            wgt_molar_mass => 0,
        },
        '93' => {
            data_type => 'nucl',
            mass_num  => 93,
            label     => 'zr93',
            symb      => 'Zr-93',
            name      => 'zirconium-93',
            # Radioactive
            half_life => (1.53e+6 * 365 * 24),
            dec_const => log(2) / (1.53e+6 * 365 * 24),
            yield                      => 0,
            yield_per_microamp         => 0,
            sp_yield                   => 0,
            sp_yield_per_microamp      => 0,
            sp_yield_per_microamp_hour => 0,
        },
        '94' => {
            data_type      => 'nucl',
            mass_num       => 94,
            label          => 'zr94',
            symb           => 'Zr-94',
            name           => 'zirconium-94',
            amt_frac       => 0.1738,
            mass_frac      => 0,
            molar_mass     => 93.90631252,
            wgt_molar_mass => 0,
        },
        '95' => {
            data_type => 'nucl',
            mass_num  => 95,
            label     => 'zr95',
            symb      => 'Zr-95',
            name      => 'zirconium-95',
        },
        '96' => {
            data_type      => 'nucl',
            mass_num       => 96,
            label          => 'zr96',
            symb           => 'Zr-96',
            name           => 'zirconium-96',
            amt_frac       => 0.0280,
            mass_frac      => 0,
            molar_mass     => 95.90827762,
            wgt_molar_mass => 0,
        },
        '98' => {
            data_type => 'nucl',
            mass_num  => 98,
            label     => 'zr98',
            symb      => 'Zr-98',
            name      => 'zirconium-98',
            # Radioactive
            half_life => (30.7  / 3600),
            dec_const => log(2) / (30.7  / 3600),
            yield                      => 0,
            yield_per_microamp         => 0,
            sp_yield                   => 0,
            sp_yield_per_microamp      => 0,
            sp_yield_per_microamp_hour => 0,
        },
    );
    #--------------------------------------------------------------------------
    # Z=41: niobium
    #--------------------------------------------------------------------------
    my %nb = (
        data_type          => 'elem',
        atomic_num         => 41,
        label              => 'nb',
        symb               => 'Nb',
        name               => 'niobium',
        mass_frac_sum      => 0,
        wgt_avg_molar_mass => 0,
        mass_nums => [
            '93',
        ],
        '93' => {
            data_type      => 'nucl',
            mass_num       => 93,
            label          => 'nb93',
            symb           => 'Nb-93',
            name           => 'niobium-93',
            amt_frac       => 1.00000,
            mass_frac      => 0,
            molar_mass     => 92.9063732,
            wgt_molar_mass => 0,
        },
    );
    #--------------------------------------------------------------------------
    # Z=42: molybdenum
    #--------------------------------------------------------------------------
    my %mo = (
        data_type          => 'elem',
        atomic_num         => 42,
        label              => 'mo',
        symb               => 'Mo',
        name               => 'molybdenum',
        mass_frac_sum      => 0,
        wgt_avg_molar_mass => 0,
        mass_nums => [
            '92',
            '94',
            '95',
            '96',
            '97',
            '98',
            '100',
        ],
        '92' => {
            data_type      => 'nucl',
            mass_num       => 92,
            label          => 'mo92',
            symb           => 'Mo-92',
            name           => 'molybdenum-92',
            amt_frac       => 0.14649,
            mass_frac      => 0,
            molar_mass     => 91.906807,
            wgt_molar_mass => 0,
        },
        '94' => {
            data_type      => 'nucl',
            mass_num       => 94,
            label          => 'mo94',
            symb           => 'Mo-94',
            name           => 'molybdenum-94',
            amt_frac       => 0.09187,
            mass_frac      => 0,
            molar_mass     => 93.905084,
            wgt_molar_mass => 0,
        },
        '95' => {
            data_type      => 'nucl',
            mass_num       => 95,
            label          => 'mo95',
            symb           => 'Mo-95',
            name           => 'molybdenum-95',
            amt_frac       => 0.15873,
            mass_frac      => 0,
            molar_mass     => 94.9058374,
            wgt_molar_mass => 0,
        },
        '96' => {
            data_type      => 'nucl',
            mass_num       => 96,
            label          => 'mo96',
            symb           => 'Mo-96',
            name           => 'molybdenum-96',
            amt_frac       => 0.16673,
            mass_frac      => 0,
            molar_mass     => 95.9046748,
            wgt_molar_mass => 0,
        },
        '97' => {
            data_type      => 'nucl',
            mass_num       => 97,
            label          => 'mo97',
            symb           => 'Mo-97',
            name           => 'molybdenum-97',
            amt_frac       => 0.09582,
            mass_frac      => 0,
            molar_mass     => 96.906017,
            wgt_molar_mass => 0,
        },
        '98' => {
            data_type      => 'nucl',
            mass_num       => 98,
            label          => 'mo98',
            symb           => 'Mo-98',
            name           => 'molybdenum-98',
            amt_frac       => 0.24292,
            mass_frac      => 0,
            molar_mass     => 97.905404,
            wgt_molar_mass => 0,
        },
        '99' => {
            data_type => 'nucl',
            mass_num  => 99,
            label     => 'mo99',
            symb      => 'Mo-99',
            name      => 'molybdenum-99',
            # Radioactive
            half_life => 65.94,
            dec_const => log(2) / 65.94,
            yield                      => 0,
            yield_per_microamp         => 0,
            sp_yield                   => 0,
            sp_yield_per_microamp      => 0,
            sp_yield_per_microamp_hour => 0,
        },
        '100' => {
            data_type      => 'nucl',
            mass_num       => 100,
            label          => 'mo100',
            symb           => 'Mo-100',
            name           => 'molybdenum-100',
            amt_frac       => 0.09744,
            mass_frac      => 0,
            molar_mass     => 99.907468,
            wgt_molar_mass => 0,
        },
    );
    #--------------------------------------------------------------------------
    # Z=43: technetium
    #--------------------------------------------------------------------------
    my %tc = (
        data_type          => 'elem',
        atomic_num         => 43,
        label              => 'tc',
        symb               => 'Tc',
        name               => 'technetium',
        mass_frac_sum      => 0,
        wgt_avg_molar_mass => 0,
        mass_nums => [
            '',
        ],
        '99' => {
            data_type => 'nucl',
            mass_num  => 99,
            label     => 'tc99',
            symb      => 'Tc-99',
            name      => 'technetium-99',
            # Radioactive
            half_life => 2.111e5 * 365 * 24,  # 211,100 years
            dec_const => log(2) / (2.111e5 * 365 * 24),
            yield                      => 0,
            yield_per_microamp         => 0,
            sp_yield                   => 0,
            sp_yield_per_microamp      => 0,
            sp_yield_per_microamp_hour => 0,
        },
        '99m' => {
            data_type => 'nucl',
            mass_num  => 99,
            label     => 'tc99m',
            symb      => 'Tc-99m',
            name      => 'technetium-99m',
            # Radioactive
            half_life => 6.01,
            dec_const => log(2) / 6.01,
            yield                      => 0,
            yield_per_microamp         => 0,
            sp_yield                   => 0,
            sp_yield_per_microamp      => 0,
            sp_yield_per_microamp_hour => 0,
        },
    );
    #--------------------------------------------------------------------------
    # Z=79: gold
    #--------------------------------------------------------------------------
    my %au = (
        data_type          => 'elem',
        atomic_num         => 79,
        label              => 'au',
        symb               => 'Au',
        name               => 'gold',
        mass_frac_sum      => 0,
        wgt_avg_molar_mass => 0,
        mass_nums => [
            '197',
        ],
        '196' => {
            data_type => 'nucl',
            mass_num  => 196,
            label     => 'au196',
            symb      => 'Au-196',
            name      => 'gold-196',
            # Radioactive
            half_life => 6.183 * 24,
            dec_const => log(2) / (6.183 * 24),
            yield                      => 0,
            yield_per_microamp         => 0,
            sp_yield                   => 0,
            sp_yield_per_microamp      => 0,
            sp_yield_per_microamp_hour => 0,
        },
        '197' => {
            data_type      => 'nucl',
            mass_num       => 197,
            label          => 'au197',
            symb           => 'Au-197',
            name           => 'gold-197',
            amt_frac       => 1.00000,
            mass_frac      => 0,
            molar_mass     => 196.966570,
            wgt_molar_mass => 0,
        },
    );

    #==========================================================================
    # Data: Materials
    #==========================================================================
    #--------------------------------------------------------------------------
    # molybdenum metal
    #--------------------------------------------------------------------------
    my %momet = (
        data_type    => 'mat',
        label        => 'momet',
        symb         => 'Mo_{met}',
        name         => 'molybdenum metal',
        molar_mass   => 0,      # TBC
        mass_dens    => 10.28,  # g cm^-3
        num_dens     => 0,      # cm^-3. TBC
        vol          => 0,      # TBP
        mass         => 0,      # TBC using 'mass_dens' and 'vol' above
        consti_elems => [  # Iteration ctrl; values must be keys of this hash
            'mo',
        ],
        mo => {
            # Properties of the constituent elements
            # "independent" on materials
            href      => \%mo,
            # Properties of the constituent elements
            # "dependent" on materials
            # - Embedded in each material
            amt_subs  => 1,  # Amount of substance (aka number of moles)
            mass_frac => 0,  # TBC
            mass      => 0,  # TBC
            mass_dens => 0,  # TBC
            num_dens  => 0,  # TBC
        },
    );
    #--------------------------------------------------------------------------
    # molybdenum(IV) oxide
    #--------------------------------------------------------------------------
    my %moo2 = (
        data_type    => 'mat',
        label        => 'moo2',
        symb         => 'MoO_{2}',
        name         => 'molybdenum dioxide',
        molar_mass   => 0,
        mass_dens    => 6.47,
        num_dens     => 0,
        vol          => 0,
        mass         => 0,
        consti_elems => [
            'mo',
            'o',
        ],
        mo => {
            href      => \%mo,
            amt_subs  => 1,
            mass_frac => 0,
            mass      => 0,
            mass_dens => 0,
            num_dens  => 0,
        },
        o => {
            href      => \%o,
            amt_subs  => 2,
            mass_frac => 0,
            mass      => 0,
            mass_dens => 0,
            num_dens  => 0,
        },
    );
    #--------------------------------------------------------------------------
    # molybdenum(VI) oxide
    #--------------------------------------------------------------------------
    my %moo3 = (
        data_type    => 'mat',
        label        => 'moo3',
        symb         => 'MoO_{3}',
        name         => 'molybdenum trioxide',
        molar_mass   => 0,
        mass_dens    => 4.69,
        num_dens     => 0,
        vol          => 0,
        mass         => 0,
        consti_elems => [
            'mo',
            'o',
        ],
        mo => {
            href      => \%mo,
            amt_subs  => 1,
            mass_frac => 0,
            mass      => 0,
            mass_dens => 0,
            num_dens  => 0,
        },
        o => {
            href      => \%o,
            amt_subs  => 3,
            mass_frac => 0,
            mass      => 0,
            mass_dens => 0,
            num_dens  => 0,
        },
    );
    #--------------------------------------------------------------------------
    # gold metal
    #--------------------------------------------------------------------------
    my %aumet = (
        data_type    => 'mat',
        label        => 'aumet',
        symb         => 'Au_{met}',
        name         => 'gold metal',
        molar_mass   => 0,
        mass_dens    => 19.3,
        num_dens     => 0,
        vol          => 0,
        mass         => 0,
        consti_elems => [
            'au',
        ],
        au => {
            href      => \%au,
            amt_subs  => 1,
            mass_frac => 0,
            mass      => 0,
            mass_dens => 0,
            num_dens  => 0,
        },
    );

    #==========================================================================
    # The above hashes must be registered to the hashes below.
    #==========================================================================
    my %elem_hrefs = (
        o  => \%o,
        zr => \%zr,
        nb => \%nb,
        mo => \%mo,
        tc => \%tc,
        au => \%au,
    );
    my %mat_hrefs = (
        momet => \%momet,
        moo2  => \%moo2,
        moo3  => \%moo3,
        aumet => \%aumet,
    );
    my %registry = (
        %elem_hrefs,
        %mat_hrefs,
    );

    return \%registry;
}


sub enri_preproc {
    # """Preprocessor for enri(): Populate chemical entity hashes and
    # prepare for DCC calculation."""
    my @hnames_ordered = @{$_[0]->{hnames}};
    my (  # Strings to be used as the keys of %registry
        $mat,
        $enri_nucl_elem,
        $enri_nucl_mass_num,
        $enri_lev,
    ) = @{$_[0]->{dcc_preproc}}{
        'mat',
        'enri_nucl_elem',
        'enri_nucl_mass_num',
        'enri_lev',  # Used only for decimal places calculation
    };
    my $enri_lev_type       = $_[0]->{enri_lev_type};
    my $min_depl_lev_global = $_[0]->{min_depl_lev_global};
    my %min_depl_lev_local  = %{$_[0]->{min_depl_lev_local}}
        if $_[0]->{min_depl_lev_local};
    my $depl_order = $_[0]->{depl_order};
    my $is_verbose = $_[0]->{is_verbose};

    # Notification
    if ($is_verbose) {
        say "\n".("=" x 70);
        printf(
            "[%s]\n",
            join('::', (caller(0))[3])
        );
        say "=" x 70;
        printf(
            "populating the hashes of [%s]...\n",
            join(', ', @hnames_ordered),
        );
    }

    # Generate chem hrefs.
    my %registry = %{gen_chem_hrefs()};

    #==========================================================================
    # Additional data for nuclides: Set the minimum depletion levels
    # which will be used in enrich_or_deplete().
    #==========================================================================
    foreach my $chem_dat (@hnames_ordered) {
        # Global minimum depletion level
        if (
            exists $registry{$chem_dat}{mass_nums}
            and ref $registry{$chem_dat}{mass_nums} eq ARRAY
        ) {
            printf(
                "Assigning the global minimum depletion level [%s]".
                " to [%s] isotopes...\n",
                $min_depl_lev_global,
                $registry{$chem_dat}{label},
            ) if $is_verbose;
            foreach my $mass_num (@{$registry{$chem_dat}{mass_nums}}) {
                $registry{$chem_dat}{$mass_num}{min_depl_lev} =
                    $min_depl_lev_global;
            }
        }

        # Local minimum depletion levels: Overwrite 'min_depl_lev's if given.
        foreach my $elem (keys %min_depl_lev_local) {
            if ($registry{$chem_dat}{label} eq $elem) {
                printf(
                    "Overwriting the global minimum depletion level of".
                    " [%s] isotopes using the local depletion levels...\n",
                    $elem,
                ) if $is_verbose;
                foreach my $mass_num (keys %{$min_depl_lev_local{$elem}}) {
                    $registry{$chem_dat}{$mass_num}{min_depl_lev} =
                        $min_depl_lev_local{$elem}{$mass_num};
                }
            }
        }
    }

    #==========================================================================
    # (a) & (b) Calculate the mass fractions of the isotopes of the elements
    #           using their natural abundances.
    #==========================================================================
    printf(
        "Calculating the initial mass fractions of [%s] isotopes ".
        "using their natural abundances for the [%s] material...\n",
        join(', ', @{$registry{$mat}->{consti_elems}}),
        $registry{$mat}->{label},
    ) if $is_verbose;

    # (a) Calculate the weighted-average molar masses of the constituent
    #     elements of the material using the natural abundances
    #     (amount fractions) of their isotopes.
    calc_consti_elem_wgt_avg_molar_masses(
        $registry{$mat},
        'amt_frac',
        $is_verbose,
    );

    # (b) Convert the amount fractions of the nuclides (the isotopes of
    #     the elements) to mass fractions.
    convert_fracs(
        $registry{$mat},
        'amt_to_mass',
        $is_verbose,
    );

    # (c) Redistribute the enrichment levels of the nuclides to reflect
    #     the enrichment of the nuclide of interest.
    # - The use of a conversion (format specifier) for $dcc_for is necessary
    #   to make the number of decimal places of the natural enrichment
    #   levels which will fill in '.._frac_bef' the same as the number of
    #   decimal places of the enrichment levels which will be passed to enri().
    #   This will in turn enable dcc = 1 at the natural enrichment level.
    #   e.g. If the mass fractions to be passed to enri() have four decimal
    #        places, here we do:
    #        0.101460216237459 of $mo{100}{mass_frac} --> 0.1015
    my $decimal_places = (split /[.]/, $enri_lev)[1];
    my $conv = '%.'.length($decimal_places).'f';
    my $dcc_for = sprintf(
        "$conv",
        $registry{$enri_nucl_elem}{$enri_nucl_mass_num}{$enri_lev_type},
    );
    enrich_or_deplete(               # e.g.
        $registry{$enri_nucl_elem},  # \%mo
        $enri_nucl_mass_num,         # '100'
        $dcc_for,                    # 0.1015
        $enri_lev_type,              # 'amt_frac'
        $depl_order,                 # 'ascend'
        $is_verbose,                 # 1 (boolean)
    );

    # (d) Convert the redistributed enrichment levels.
    #     (i)  If the amount fraction represents the enrichment level,
    #          convert the redistributed amount fractions to mass fractions.
    #     (ii) If the mass fraction represents the enrichment level,
    #          convert the redistributed mass fractions to amount fractions.
    convert_fracs(
        $registry{$mat},  # e.g. \%moo3
        (
            $enri_lev_type eq 'amt_frac' ?
                'amt_to_mass' :  # Conv redistributed amt fracs to mass fracs
                'mass_to_amt'    # Conv redistributed mass fracs to amt fracs
        ),
        $is_verbose,  # e.g. 1 (boolean)
    );

    # (e) Again calculate the weighted-average molar masses of the constituent
    #     elements, but now using the enrichment levels of their isotopes.
    #     (the enrichment level can either be 'amt_frac' or 'mass_frac'
    #     depending on the user's input)
    calc_consti_elem_wgt_avg_molar_masses(
        $registry{$mat},  # e.g. \%moo3
        $enri_lev_type,   # e.g. 'amt_frac' or 'mass_frac'
        $is_verbose,      # e.g. 1 (boolean)
    );

    # (f) Calculate:
    # - The molar mass of the material using the weighted-average
    #   molar masses of its constituent elements obtained in (e)
    # - Mass fractions and masses of the constituent elements using
    #   the molar mass of the material
    # - Masses of the isotopes
    #   ********************************************************************
    # - *** Most importantly, populate the 'mass_frac_bef' attribute for ***
    #   *** density change coefficient calculation in enri().               ***
    #   ********************************************************************
    printf(
        "Populating the [$enri_lev_type\_bef] attributes of [%s] ".
        "for DCC calculation...\n",
        join(', ', @{$registry{$mat}->{consti_elems}}),
    ) if $is_verbose;
    calc_mat_molar_mass_and_subcomp_mass_fracs_and_dccs(
        $registry{$mat},  # e.g. \%moo3
        $enri_lev_type,   # e.g. 'amt_frac' or 'mass_frac'
        $is_verbose,      # e.g. 1 (boolean)
        'dcc_preproc',    # Tells the routine that it's a preproc call
    );

    # Return a hash of chemical entity hashes.
    my %chem_hrefs;
    foreach my $hname (@hnames_ordered) {
        $chem_hrefs{$hname} = $registry{$hname} if $registry{$hname};
    }
    return \%chem_hrefs;
}


sub enri {
    # """Calculate enrichment-dependent quantities."""
    my (                      # e.g.
        $chem_hrefs,          # {o => \%o, mo => \%mo, momet => \%momet, ...}
        $mat,                 # momet, moo2, moo3, ...
        $enri_nucl_elem,      # mo, o, ...
        $enri_nucl_mass_num,  # '100', '98', ...
        $enri_lev,            # 0.9739, 0.9954, ...
        $enri_lev_type,       # 'amt_frac'
        $depl_order,          # 'ascend'
        $is_verbose,          # 1 (boolean)
    ) = @_;

    # (1) Redistribute the enrichment levels of the nuclides to reflect
    #     the enrichment of the nuclide of interest.
    my $is_exit = enrich_or_deplete(     # e.g.
        $chem_hrefs->{$enri_nucl_elem},  # \%mo
        $enri_nucl_mass_num,             # '100'
        $enri_lev,                       # 0.9739
        $enri_lev_type,                  # 'amt_frac'
        $depl_order,                     # 'ascend'
        $is_verbose,                     # 1 (boolean)
    );
    return $is_exit if $is_exit;  # Use it as a signal NOT to accumulate data.

    # (2) Convert the redistributed enrichment levels.
    convert_fracs(              # e.g.
        $chem_hrefs->{$mat},    # \%moo3
        (
            $enri_lev_type eq 'amt_frac' ?
                'amt_to_mass' :  # Conv redistributed amt fracs to mass fracs
                'mass_to_amt'    # Conv redistributed mass fracs to amt fracs
        ),
        $is_verbose,            # 1 (boolean)
    );

    # (3) Calculate the weighted-average molar masses of the constituent
    #     elements using the enrichment levels of their isotopes.
    calc_consti_elem_wgt_avg_molar_masses(
        $chem_hrefs->{$mat},  # \%moo3
        $enri_lev_type,       # 'amt_frac' or 'mass_frac'
        $is_verbose,          # 1 (boolean)
    );

    # (4) Calculate:
    # - The molar mass of the material using the weighted-average
    #   molar masses of its constituent elements obtained in (3)
    # - Mass fractions and masses of the constituent elements using
    #   the molar mass of the material
    # - Masses of the isotopes
    #   ******************************************************************
    # - *** Most importantly, density change coefficients of the isotopes ***
    #   ******************************************************************
    calc_mat_molar_mass_and_subcomp_mass_fracs_and_dccs(
        $chem_hrefs->{$mat},  # \%moo3
        $enri_lev_type,       # 'amt_frac' or 'mass_frac'
        $is_verbose,          # 1 (boolean)
    );

    # (5) Calculate:
    # - Number density of the material
    # - Mass and number densities of the constituent elements and
    #   their isotopes
    calc_mass_dens_and_num_dens(
        $chem_hrefs->{$mat},  # \%moo3
        $enri_lev_type,       # 'amt_frac' or 'mass_frac'
        $is_verbose,          # 1 (boolean)
    );

    return;
}


sub enri_postproc {
    # """Postprocessor for enri()"""
    my (
        $chem_hrefs,            # e.g.
        $mat,                   # 'moo3'
        $enri_nucl,             # 'mo100'
        $enri_lev,              # 0.9739, 0.9954, ...
        $enri_lev_range_first,  # 0.0000
        $enri_lev_range_last,   # 0.9739
        $enri_lev_type,         # 'amt_frac'
        $depl_order,            # 'ascend'
        $out_path,              # './mo100'
        $projs,                 # ['g', 'n', 'p']
        $precision_href,
        $is_verbose,            # 1 (boolean)
    ) = @_;

    # (6) Adjust the number of decimal places of calculation results.
    adjust_num_of_decimal_places(
        $chem_hrefs,
        $precision_href,
        $enri_lev_range_first,
    );

    # (7) Associate product nuclides with nuclear reactions and DCCs.
    assoc_prod_nucls_with_reactions_and_dccs(
        $chem_hrefs,
        $mat,
        $enri_nucl,
        $enri_lev,
        $enri_lev_range_first,
        $enri_lev_range_last,
        $enri_lev_type,
        $depl_order,
        $out_path,
        $projs,
        $is_verbose,
    );

    return;
}


sub read_in_mc_flues {
    # """Read in Monte Carlo fluences to array refs."""
    my (                # e.g.
        $_mc_flue_dir,  # ./beam_nrg_35/wrcc-vhgt-frad-fgap
        $_mc_flue_dat,  # wrcc-vhgt0p10-frad2p50-fgap0p13-track-eng-moo3.ang
        $_mc_flue_dat_proj_col,  # 4
    ) = @_;

    # To-be-returned hash
    my %mc_flue = (
        unit => {
            val  => 0,
            expl => '',
        },
        nrg => {
            ev      => [],
            mega_ev => [],
            de      => 0,
        },
        proj => [],  # Projectile particle fluences
    );

    #
    # Read in the Monte Carlo fluences with their corresponding energies
    # to array refs nested to %mc_flue.
    #
    open my $mc_flue_dat_fh, '<', $_mc_flue_dir.'/'.$_mc_flue_dat;
    chomp(my @mc_flue_content = <$mc_flue_dat_fh>);
    close $mc_flue_dat_fh;

    # Identify the fluence unit.
    $mc_flue{unit}{val}  = first { /^\s*unit/ } @mc_flue_content;
    $mc_flue{unit}{val}  =~ s/^\s*unit\s*=\s*([0-9]+)\s*#.*/$1/i;
    $mc_flue{unit}{expl} = first { /^\s*unit/ } @mc_flue_content;
    $mc_flue{unit}{expl} =~ s/.*\[(.*)\].*/$1/i;

    # Identify de.
    $mc_flue{nrg}{de} = first { /^\s*#*\s*edel/ } @mc_flue_content;
    $mc_flue{nrg}{de} =~ s/^\s*#*\s*edel\s*=\s*([0-9.E+-]+)\s*#.*/$1/i;

    foreach (@mc_flue_content) {
        next unless /^\s*[0-9]/;
        s/^\s+//;
        # Take the middle of e-lower and e-upper.
        my $_e_lower = (split)[0];
        my $_e_upper = (split)[1];
        my $_e_avg = ($_e_lower + $_e_upper) / 2;
        push @{$mc_flue{nrg}{ev}},      $_e_avg * 1e6;
        push @{$mc_flue{nrg}{mega_ev}}, $_e_avg;
        # If the fluence unit is 'cm^-2 MeV^-1 source-^1' (PHITS track unit 2),
        # multiply the energy mesh width (de) to the fluence, which results in
        # the unit 'cm^-2 source-^1' (PHITS track unit 1).
        push @{$mc_flue{proj}}, $mc_flue{unit}{val} == 2 ?
            (split)[$_mc_flue_dat_proj_col] * $mc_flue{nrg}{de} :
            (split)[$_mc_flue_dat_proj_col];
    }

    #++++ Debugging ++++#
#    say @{$mc_flue{proj}} * 1;
    #+++++++++++++++++++#

    return \%mc_flue;
}


sub interp_and_read_in_micro_xs {
    # """Interpolate microscopic xs and read them in to array refs."""
    my (                         # e.g.
        $_micro_xs_dir,          # ./xs
        $_micro_xs_dat,          # tendl2015_mo100_gn_mf3_t4.dat
        $_micro_xs_interp_algo,  # csplines
        $_micro_xs_emin,         # 0
        $_micro_xs_emax,         # 35e6
        $_micro_xs_ne,           # 1000
    ) = @_;
    (my $micro_xs_emax = $_micro_xs_emax) =~ s/e[0-9]+//;
    # $bname
    # - Extensionless fname of the original xs file
    my ($bname, $ext) = (split /[.]/, $_micro_xs_dat)[0, 1];
    my $micro_xs_dat_eps = "$bname.eps";
    # $bname2
    # - For differentiating xs files having different emax and ne
    # - $bname2 == $bname appended by
    #   - $micro_xs_emax (string modified in this routine)
    #   - $_micro_xs_ne (string pass to this routine)
    my $bname2 = sprintf(
        "%s_emax%s_ne%s",
        $bname,
        $micro_xs_emax,
        $_micro_xs_ne,
    );
    my $micro_xs_dat            = "$bname2.$ext";
    my $micro_xs_interp_dat     = "$bname2\_$_micro_xs_interp_algo.$ext";
    my $micro_xs_interp_dat_eps = "$bname2\_$_micro_xs_interp_algo.eps";
    my $micro_xs_interp_gp      = "$bname2\_$_micro_xs_interp_algo.gp";
    my $micro_xs_interp_plt     = "$bname2\_$_micro_xs_interp_algo.plt";
    my $mega = "1e6";
    my $sub_name = join('::', (caller(0))[3]);

    # To-be-returned hash
    my %xs = (
        nrg   => {ev   => [], mega_ev => []},
        micro => {barn => [], 'cm^2'  => []},
        macro => {            'cm^-1' => []},  # macro barn: not needed
    );

    #
    # Generate and run a gnuplot script.
    #
    my $where_routine_began = getcwd();
    mkdir $_micro_xs_dir unless -e $_micro_xs_dir;
    chdir $_micro_xs_dir;

    #
    # (i) Microscopic xs interpolation
    #

    # Generate a gnuplot script that interpolates the modified xs file.
    if (not -e $micro_xs_interp_gp) {
        open my $micro_xs_interp_gp_fh,
            '>:encoding(UTF-8)',
            $micro_xs_interp_gp;
        select($micro_xs_interp_gp_fh);

        say "#!/usr/bin/gnuplot";
        say "";
        say "dat    = '$_micro_xs_dat'";
        say "interp = '$micro_xs_interp_dat'";
        say "";
        say "xmin = $_micro_xs_emin";
        say "xmax = $_micro_xs_emax";
        say "nx   = $_micro_xs_ne";
        say "set xrange [xmin:xmax]";
        say "";
        say "set table interp";
        say "set samples nx";
        say "plot dat u 1:2 smooth $_micro_xs_interp_algo notitle";
        say "unset table";
        print "#eof";

        select(STDOUT);
        close $micro_xs_interp_gp_fh;

        say "[$sub_name] generated [$micro_xs_interp_gp].";
    }

    # Run the gnuplot interpolation script.
    if (not -e $micro_xs_interp_dat) {
        say "[$sub_name] running [$micro_xs_interp_gp] through [gnuplot]...";
        system "gnuplot $micro_xs_interp_gp";
    }

    # Process the interpolated xs data file.
    # - Remove comment and blank lines.
    # - Suppress leading spaces.
    # - Replace a negative microscopic xs with zero.
    #   A negative microscopic xs can result from gnuplot extrapolation,
    #   and gnuplot extrapolation takes places when its interpolation
    #   exceeds the last energy bin.
    my $xs_interp_tmp = 'xs_interp_tmp.dat';
    open my $micro_xs_interp_dat_fh, '<', $micro_xs_interp_dat;
    open my $micro_xs_interp_dat_tmp_fh, '>:encoding(UTF-8)', $xs_interp_tmp;
    foreach (<$micro_xs_interp_dat_fh>) {
        # Skip comment and blank lines, if exist.
        next if /^\s*#/ or /^$/;

        # Suppress leading spaces, if exist.
        s/^\s+//;

        # Replace a negative microscopic xs with zero, if exist.
        if ((split)[1] < 0) {
            my $_micro_xs = (split)[1];
            s/$_micro_xs/0/;
        }

        # Write to the outbound filehandle.
        print $micro_xs_interp_dat_tmp_fh $_;
    }
    close $micro_xs_interp_dat_fh;
    close $micro_xs_interp_dat_tmp_fh;
    copy($xs_interp_tmp, $micro_xs_interp_dat);
    unlink $xs_interp_tmp;

    #
    # (ii) Microscopic xs plotting
    #

    # Script generation
    if (not -e $micro_xs_interp_plt) {
        open my $micro_xs_interp_plt_fh,
            '>:encoding(UTF-8)',
            $micro_xs_interp_plt;
        select($micro_xs_interp_plt_fh);

        say "#!/usr/bin/gnuplot";
        say "";
        say "dat            = '$_micro_xs_dat'";
        say "dat_eps        = '$micro_xs_dat_eps'";
        say "interp_dat     = '$micro_xs_interp_dat'";
        say "interp_dat_eps = '$micro_xs_interp_dat_eps'";
        say "";
        say "set term postscript eps enhanced color font 'Helvetica, 26'";
        say "";
        say "set style line 1 lc rgb 'blue'";
        say "set style data lines";
        say "";
        say "xmin = 0";
        say "xmax = $_micro_xs_emax";
        say "xinc = 5e6";
        say "mega = $mega";
        say "set xrange [xmin:xmax]";
        say "set for [i=xmin:xmax:xinc] xtics (sprintf(\"\%d\", i/mega) i)";
        say "set xlabel 'Energy (MeV)'";
        say "set ytics format \"%.2f\"";
        say "set ytics add ('0' 0)";
        say "set ylabel 'Microscopic cross section (b)'";
        say "";
        say "set key at graph 0.99,0.95";
        say "";
        say "title1 = '^{100}Mo({/Symbol g},n)^{99}Mo'";
        say "set output dat_eps";
        say "plot dat u 1:2 ls 1 t title1";
        say "";
        say "set output interp_dat_eps";
        say "plot interp_dat u 1:2 ls 1 t title1";
        print "#eof";

        select(STDOUT);
        close $micro_xs_interp_plt_fh;

        say "[$sub_name] generated [$micro_xs_interp_plt].";
    }

    # Script run
    if (not -e $micro_xs_dat_eps or not -e $micro_xs_interp_dat_eps) {
        say "[$sub_name] running [$micro_xs_interp_plt] through [gnuplot]...";
        system "gnuplot $micro_xs_interp_plt";
    }

    #
    # Read in the interpolated microscopic xs with their corresponding energies
    # to array refs nested to %xs (in the units of 'barn' and 'cm^2').
    #
    my $barn = 1e-24;
    open $micro_xs_interp_dat_fh, '<', $micro_xs_interp_dat;
    foreach (<$micro_xs_interp_dat_fh>) {
        next if /^\s*#/ or /^$/;
        s/^\s+//;
        push @{$xs{nrg}{ev}},       (split)[0];
        push @{$xs{nrg}{mega_ev}},  (split)[0] / $mega;
        push @{$xs{micro}{barn}},   (split)[1];
        push @{$xs{micro}{'cm^2'}}, (split)[1] * $barn;
    }
    close $micro_xs_interp_dat_fh;

    #++++ Debugging ++++#
#    say @{$xs{micro}{barn}} * 1;
    #+++++++++++++++++++#

    chdir $where_routine_began;
    return \%xs;
}


sub pointwise_multiplication {
    # """Pointwise multiplication of MC fluences and xs"""
    my (                        # e.g.
        $_mc_flue,              # \%mc_flue
        $_xs,                   # \%xs
        $_react_nucl_num_dens,  # 1.91186648430e+021 (reactant nucl num dens)
        $_tar_vol,              # 0.392699081698
        $_avg_beam_curr,        # 1
    ) = @_;
    my $micro_amp = 6.24150934e+12,  # Number of charged pars per second in uA

    # To-be-returned hash
    my %pwm = (
        # (i) Microscopic PWM
        # - MC fluence      * m"i"croscopic xs
        #   cm^-2 source^-1 * cm^2
        #   => source^-1
        # - Number density of target nuclides "not yet" multiplied
        micro     => [],
        micro_tot => 0,  # Must be initialized as will be a cumulative sum

        # (ii) M"a"croscopic PWM
        # - MC fluence      * m"a"croscopic xs
        #   cm^-2 source^-1 * cm^-1
        #   => cm^-3 source^-1
        # - Number density of target nuclides multiplied
        macro     => [],
        macro_tot => 0,

        # (iii) Source rate
        source_rate => 0,

        # (iv) Reaction rate per volume
        #      (Number of reactions per second per target volume)
        # - macroscopic PWM * number of sources per second
        #   cm^-3 source^-1 * source s^-1 => cm^-3 s^-1
        react_rate_per_vol     => [],
        react_rate_per_vol_tot => 0,

        # (v) Reaction rate
        #     (Number of reactions per second)
        # - reaction rate per target volume * target volume
        #   cm^-3 s^-1                      * cm^3          => s^-1
        # - Equivalent to a production yield and radioactivity in Bq
        react_rate     => [],
        react_rate_tot => 0,
    );

    # Array size validation
    if (@{$_mc_flue->{proj}}*1 != @{$_xs->{micro}{'cm^2'}}*1) {
        croak "\n\nNonidentical array sizes:\n".
              "\@{\$_mc_flue->{proj}} array size: [".
              (@{$_mc_flue->{proj}} * 1)."]\n".
              "\@{\$_xs->{micro}{'cm^2'}} array size: [".
              (@{$_xs->{micro}{'cm^2'}} * 1)."]";
    }

    #
    # (1) "Under the integral" -> PWM
    #     - Caution: Use the cm^2 xs, not the original barn one.
    #

    for (my $i=0; $i<=$#{$_xs->{micro}{'cm^2'}}; $i++) {
        #----------------------------Commented out-----------------------------
        # Negative xs are now adjusted to zero
        # in interp_and_read_in_micro_xs().
        #----------------------------------------------------------------------
        # Skip a negative xs, which can result from gnuplot extrapolation.
        # (gnuplot extrapolation takes places when its interpolation
        # exceeds the last energy bin.)
#        next if $_xs->{micro}{'cm^2'}[$i] < 0;
        #----------------------------------------------------------------------

        # m"i"croscopic xs --> m"a"croscopic xs
        $_xs->{macro}{'cm^-1'}[$i] =   # cm^-1
            $_xs->{micro}{'cm^2'}[$i]  # cm^2
            * $_react_nucl_num_dens;   # cm^-3

        # Pointwise multiplication
        $pwm{micro}[$i] =               # source^-1
            $_xs->{micro}{'cm^2'}[$i]   # cm^2
            * $_mc_flue->{proj}[$i];    # cm^-2 source^-1
        $pwm{macro}[$i] =               # cm^-3 source^-1
            $_xs->{macro}{'cm^-1'}[$i]  # cm^-1
            * $_mc_flue->{proj}[$i];    # cm^-2 source^-1

        # Source rate
        $pwm{source_rate} =  # source s^-1
            $micro_amp
            * $_avg_beam_curr;

        # Reaction rate per target volume
        $pwm{react_rate_per_vol}[$i] =  # cm^-3 s^-1
            $pwm{macro}[$i]             # cm^-3 source^-1
            * $pwm{source_rate};        # source s^-1

        # Reaction rate
        $pwm{react_rate}[$i] =            # s^-1
            $pwm{react_rate_per_vol}[$i]  # cm^-3 s^-1
            * $_tar_vol;                  # cm^3
    }

    # Cumulative sums of the PWM products
    $pwm{micro_tot}              += $_ for @{$pwm{micro}};
    $pwm{macro_tot}              += $_ for @{$pwm{macro}};
    $pwm{react_rate_per_vol_tot} += $_ for @{$pwm{react_rate_per_vol}};
    $pwm{react_rate_tot}         += $_ for @{$pwm{react_rate}};

    return \%pwm;
}


sub tot_react_rate_to_yield_and_sp_yield {
    # """Convert a cumulative sum of PWMs to a yield and specific yield."""
    my (                  # e.g.
        $_pwm,            # \%pwm
        $_prod_nucl,      # $mo{'99'}, which is a ref to an anonymous hash
        $_avg_beam_curr,  # 1.0
        $_end_of_irr,     # 0.166666666666667
        $_react_nucl_elem_mass,  # 1.22763606324722 (reactant nucl elem mass)
        $_yield_denom,    # 1e3
    ) = @_;

    #
    # Take into account the decay of the product radionuclide.
    #

    #   $mo{'99'}{yield}
    $_prod_nucl->{yield} =
        (1 - exp(-$_prod_nucl->{dec_const}* $_end_of_irr))  # h^-1 * h
        * $_pwm->{react_rate_tot};                          # s^-1
    $_prod_nucl->{yield} /= $_yield_denom;  # Unit conversion
    $_prod_nucl->{yield_per_microamp} =     # per-uA yield
        $_prod_nucl->{yield}
        / $_avg_beam_curr;

    #
    # Calculate the specific yield.
    #

    #   $mo{'99'}{sp_yield}
    $_prod_nucl->{sp_yield} =
        $_prod_nucl->{yield}
        #**********************************************************************
        # NOT the mass of the target!
        #**********************************************************************
        / $_react_nucl_elem_mass;

    #   $mo{'99'}{sp_yield_per_microamp}
    $_prod_nucl->{sp_yield_per_microamp} =
        $_prod_nucl->{sp_yield}
        / $_avg_beam_curr;

    #   $mo{'99'}{sp_yield_per_microamp_hour}
    $_prod_nucl->{sp_yield_per_microamp_hour} =
        $_prod_nucl->{sp_yield_per_microamp}
        / $_end_of_irr;

    return;
}


sub calc_rn_yield {
    # """Calculate the yield and specific yield of a radionuclide."""
    my $calc_conds_href = shift;
    croak "The 1st arg of [".join('::', (caller(0))[3])."] must be a hash ref!"
        unless ref $calc_conds_href eq HASH;

    #--------------------------------------------------------------------------
    # Redirection for for clearer coding
    #--------------------------------------------------------------------------
    my (
        #-------------------------------------------------
        # For reactant nuclide number density calculation
        #-------------------------------------------------
        $tar_mat,
        $tar_dens_ratio,
        $tar_vol,
        $react_nucl,
        $react_nucl_enri_lev,
        $enri_lev_type,
        $prod_nucl,
        $min_depl_lev_global,
        $min_depl_lev_local_href,
        $depl_order,
        $is_verbose,
        #-----------------------
        # For yield calculation
        #-----------------------
        # Irradiation conditions
        $avg_beam_curr,  # uA
        $end_of_irr,     # Hour
        # Particle fluence data
        $mc_flue_dir,
        $mc_flue_dat,
        $mc_flue_dat_proj_col,
        # Microscopic xs data
        $micro_xs_dir,
        $micro_xs_dat,
        $micro_xs_interp_algo,
        $micro_xs_emin,
        $micro_xs_emax,
        $micro_xs_ne,
        # Format specifiers
        $precision_href,
        # Yield and specific yield units
        $yield_unit,
    ) = @{$calc_conds_href}{qw/
        tar_mat
        tar_dens_ratio
        tar_vol
        react_nucl
        react_nucl_enri_lev
        enri_lev_type
        prod_nucl
        min_depl_lev_global
        min_depl_lev_local_href
        depl_order
        is_verbose
        avg_beam_curr
        end_of_irr
        mc_flue_dir
        mc_flue_dat
        mc_flue_dat_proj_col
        micro_xs_dir
        micro_xs_dat
        micro_xs_interp_algo
        micro_xs_emin
        micro_xs_emax
        micro_xs_ne
        precision_href
        yield_unit
    /};
    $tar_dens_ratio          = 1.0000   if not $tar_dens_ratio;
    $min_depl_lev_global     = 0.0000   if not $min_depl_lev_global;
    $min_depl_lev_local_href = {}       if not $min_depl_lev_local_href;
    $depl_order              = 'ascend' if not $depl_order;
    (my $react_nucl_elem     = $react_nucl) =~ s/[^a-zA-Z]//g;
    (my $react_nucl_mass_num = $react_nucl) =~ s/[^0-9]//g;
    (my $prod_nucl_elem      = $prod_nucl)  =~ s/[^a-zA-Z]//g;
    (my $prod_nucl_mass_num  = $prod_nucl)  =~ s/[^0-9]//g;
    my $chem_hrefs = enri_preproc(
        {
            hnames => [  # Names of chemical entity hashes
                # Mo targets and elements
                'o',
                'mo',
                'momet',
                'moo2',
                'moo3',
                # Gold foil and element
                'au',
                'aumet',
            ],
            dcc_preproc => {  # Keys: strings
                mat                => $tar_mat,
                enri_nucl_elem     => $react_nucl_elem,
                enri_nucl_mass_num => $react_nucl_mass_num,
                # Below is used only for decimal places calculation;
                # use any of the enrichment levels.
                enri_lev           => $react_nucl_enri_lev,
            },
            enri_lev_type       => $enri_lev_type,
            min_depl_lev_global => $min_depl_lev_global,
            min_depl_lev_local  => $min_depl_lev_local_href,
            depl_order          => $depl_order,
            is_verbose          => $is_verbose,
        },
    );

    # Apply the density ratio to the target.
    $chem_hrefs->{$tar_mat}{dens_ratio} = $tar_dens_ratio;
    if (
        $chem_hrefs->{$tar_mat}{dens_ratio} >= 0.0000
        and $chem_hrefs->{$tar_mat}{dens_ratio} <= 1.0000
    ) {
        # Notification and multiplication to the mass density
        my $lead_symb = '#';
        printf("\n%s%s\n", $lead_symb, '-' x 69);
        printf(
            "%s %s mass density [%s g cm^-3] became ",
            $lead_symb,
            $chem_hrefs->{$tar_mat}{label},
            $chem_hrefs->{$tar_mat}{mass_dens},
        );
        $chem_hrefs->{$tar_mat}{mass_dens}
            *= $chem_hrefs->{$tar_mat}{dens_ratio};
        printf(
            "[%s g cm^-3] by the density ratio [%f].\n",
            $chem_hrefs->{$tar_mat}{mass_dens},
            $chem_hrefs->{$tar_mat}{dens_ratio},
        );
        printf("%s%s\n", $lead_symb, '-' x 69);
    }

    # Calculate the mass of the target.
    $chem_hrefs->{$tar_mat}{vol} = $tar_vol;
    $chem_hrefs->{$tar_mat}{mass} =
        # Assigned via the routine argument
        $chem_hrefs->{$tar_mat}{vol}
        # Tabulated val multiplied by TD ratio
        * $chem_hrefs->{$tar_mat}{mass_dens};

    # Yield unit
    my %yield_units = (
        # (key) Name of yield unit
        # (val) Bq or denominator for from-Bq conversion
        Bq  => 1.0,
        kBq => 1e3,
        MBq => 1e6,
        GBq => 1e9,
        TBq => 1e12,
        uCi => 37e3,
        mCi => 37e6,
        Ci  => 37e9,
    );
    # Default is 'Bq', which can be overridden if a correct key is given.
    $yield_unit = exists $yield_units{$yield_unit} ? $yield_unit : 'Bq';
    my $yield_denom = $yield_units{$yield_unit};

    #--------------------------------------------------------------------------
    # Calculate the number density of the reactant nuclide.
    #--------------------------------------------------------------------------
    enri(                      # e.g.
        $chem_hrefs,           # {o => \%o, mo => \%mo, momet => \%momet, ...}
        $tar_mat,              # momet, moo2, moo3, ...
        $react_nucl_elem,      # mo, o, ...
        $react_nucl_mass_num,  # '100', '98', ...
        $react_nucl_enri_lev,  # 0.9739, 0.9954, ...
        $enri_lev_type,        # 'amt_frac'
        $depl_order,           # 'ascend'
        $is_verbose,
    );

    #--------------------------------------------------------------------------
    # Calculate the yield and specific yield of the product nuclide.
    #--------------------------------------------------------------------------
    # (1) Read in the MC projectile fluences to array refs.
    my $mc_flue_href = read_in_mc_flues(
        $mc_flue_dir,
        $mc_flue_dat,
        $mc_flue_dat_proj_col,
    );
    my %mc_flue = %$mc_flue_href;

    # (2) xs interpolation
    # Interpolate microscopic cross sections using
    # the smooth option of the plot command of gnuplot,
    # and read them in to array refs in the units of barn and cm^2.
    my $xs_href = interp_and_read_in_micro_xs(
        $micro_xs_dir,
        $micro_xs_dat,
        $micro_xs_interp_algo,
        $micro_xs_emin,
        $micro_xs_emax,
        $micro_xs_ne,
    );
    my %xs = %$xs_href;

    # (3) Perform pointwise multiplication of the MC projectile fluence
    #     read in in (1) and the microscopic xs read in in (2).
    #     => Total reaction rate is obtained.
    my $pwm_href = pointwise_multiplication(
        \%mc_flue,
        \%xs,
        $chem_hrefs->{$tar_mat}{$react_nucl}{num_dens},
        $chem_hrefs->{$tar_mat}{vol},
        $avg_beam_curr,
    );
    my %pwm = %$pwm_href;

    # (4) Convert the total reaction rate to yield by taking into account
    #     the decay of the product radionuclide, and calculate the specific
    #     yield by dividing the yield by the mass of the target element.
    tot_react_rate_to_yield_and_sp_yield(
        \%pwm,
        #                                         $mo{'99'}
        $chem_hrefs->{$prod_nucl_elem}{$prod_nucl_mass_num},
        $avg_beam_curr,
        $end_of_irr,
        # Calculated in:
        # calc_mat_molar_mass_and_subcomp_mass_fracs_and_dccs()
        #                               $moo3{mo}{mass}
        $chem_hrefs->{$tar_mat}{$react_nucl_elem}{mass},
        $yield_denom,
    );

    #--------------------------------------------------------------------------
    # Adjust the number of decimal places of calculation results.
    #--------------------------------------------------------------------------
    adjust_num_of_decimal_places(
        $chem_hrefs,
        $precision_href,
        $react_nucl_enri_lev,
        1,  # $is_adjust_all
    );
    my $href_of_unbound_to_href = {  # For those "un"bound to a hash ref
        avg_beam_curr          => \$avg_beam_curr,
        end_of_irr             => \$end_of_irr,
        proj                   => $mc_flue{proj},
        pwm_micro              => $pwm{micro},
        pwm_micro_tot          => \$pwm{micro_tot},
        pwm_macro              => $pwm{macro},
        pwm_macro_tot          => \$pwm{macro_tot},
        source_rate            => \$pwm{source_rate},
        react_rate_per_vol     => $pwm{react_rate_per_vol},
        react_rate_per_vol_tot => \$pwm{react_rate_per_vol_tot},
        react_rate             => $pwm{react_rate},
        react_rate_tot         => \$pwm{react_rate_tot},
    };
    my $none_chem_hrefs = {
        href_of_unbound_to_href => $href_of_unbound_to_href,
        mc_flue_nrg => $mc_flue{nrg},
        xs_nrg      => $xs{nrg},
        xs_micro    => $xs{micro},
        xs_macro    => $xs{macro},
    };
    adjust_num_of_decimal_places(
        $none_chem_hrefs,
        $precision_href,
        $react_nucl_enri_lev,
        1,  # $is_adjust_all
    );

    #--------------------------------------------------------------------------
    # Return the calculated yield and specific yield to the caller package.
    #--------------------------------------------------------------------------
    return {
        # Target
        tar_mat_name   => $chem_hrefs->{$tar_mat}{name},
        tar_mat_symb   => $chem_hrefs->{$tar_mat}{symb},
        tar_dens_ratio => $chem_hrefs->{$tar_mat}{dens_ratio},
        tar_mass_dens  => $chem_hrefs->{$tar_mat}{mass_dens},
        tar_num_dens   => $chem_hrefs->{$tar_mat}{num_dens},
        tar_vol        => $chem_hrefs->{$tar_mat}{vol},
        tar_mass       => $chem_hrefs->{$tar_mat}{mass},

        # Chemical element of the reactant nuclide
        react_nucl_elem_name =>
            $chem_hrefs->{$tar_mat}{$react_nucl_elem}{href}{name},
        react_nucl_elem_symb =>
            $chem_hrefs->{$tar_mat}{$react_nucl_elem}{href}{symb},
        react_nucl_elem_mass_frac =>
            $chem_hrefs->{$tar_mat}{$react_nucl_elem}{mass_frac},
        react_nucl_elem_mass_dens =>
            $chem_hrefs->{$tar_mat}{$react_nucl_elem}{mass_dens},
        react_nucl_elem_num_dens =>
            $chem_hrefs->{$tar_mat}{$react_nucl_elem}{num_dens},
        react_nucl_elem_mass =>
            $chem_hrefs->{$tar_mat}{$react_nucl_elem}{mass},

        # Reactant nuclide
        react_nucl_name =>
            $chem_hrefs->{$react_nucl_elem}{$react_nucl_mass_num}{name},
        react_nucl_symb =>
            $chem_hrefs->{$react_nucl_elem}{$react_nucl_mass_num}{symb},
        react_nucl_amt_frac =>
            $chem_hrefs->{$tar_mat}{$react_nucl}{amt_frac},
        react_nucl_mass_frac =>
            $chem_hrefs->{$tar_mat}{$react_nucl}{mass_frac},
        react_nucl_mass_dens =>
            $chem_hrefs->{$tar_mat}{$react_nucl}{mass_dens},
        react_nucl_num_dens =>
            $chem_hrefs->{$tar_mat}{$react_nucl}{num_dens},
        react_nucl_mass =>
            $chem_hrefs->{$tar_mat}{$react_nucl}{mass},
        react_nucl_enri_lev =>
            $react_nucl_enri_lev,

        # Product nuclide
        prod_nucl_name =>
            $chem_hrefs->{$prod_nucl_elem}{$prod_nucl_mass_num}{name},
        prod_nucl_symb =>
            $chem_hrefs->{$prod_nucl_elem}{$prod_nucl_mass_num}{symb},
        prod_nucl_yield =>
            $chem_hrefs->{$prod_nucl_elem}{$prod_nucl_mass_num}{yield},
        prod_nucl_yield_per_microamp =>
            $chem_hrefs->{$prod_nucl_elem}
                         {$prod_nucl_mass_num}
                         {yield_per_microamp},
        prod_nucl_sp_yield =>
            $chem_hrefs->{$prod_nucl_elem}
                         {$prod_nucl_mass_num}
                         {sp_yield},
        prod_nucl_sp_yield_per_microamp =>
            $chem_hrefs->{$prod_nucl_elem}
                         {$prod_nucl_mass_num}
                         {sp_yield_per_microamp},
        prod_nucl_sp_yield_per_microamp_hour =>
            $chem_hrefs->{$prod_nucl_elem}
                         {$prod_nucl_mass_num}
                         {sp_yield_per_microamp_hour},

        # Irradiation conditions
        avg_beam_curr => $avg_beam_curr,
        end_of_irr    => $end_of_irr,

        # Particle fluences
        mc_flue_nrg_ev      => $mc_flue{nrg}{ev},       # Array ref
        mc_flue_nrg_mega_ev => $mc_flue{nrg}{mega_ev},  # Array ref
        mc_flue_nrg_ne      => @{$mc_flue{nrg}{mega_ev}} * 1,
        mc_flue_nrg_de      => $mc_flue{nrg}{de},
        mc_flue_proj        => $mc_flue{proj},          # Array ref
        mc_flue_unit        => sprintf(
            "%s (PHITS tally unit number %s)",
            $mc_flue{unit}{expl},
            $mc_flue{unit}{val},
        ),

        # Microscopic and macroscopic cross sections
        xs_nrg_ev        => $xs{nrg}{ev},         # Array ref
        xs_nrg_mega_ev   => $xs{nrg}{mega_ev},    # Array ref
        xs_nrg_ne        => @{$xs{nrg}{mega_ev}} * 1,
        xs_nrg_de        => $xs{nrg}{mega_ev}[1] - $xs{nrg}{mega_ev}[0],
        micro_xs_barn    => $xs{micro}{barn},     # Array ref
        'micro_xs_cm^2'  => $xs{micro}{'cm^2'},   # Array ref
        'macro_xs_cm^-1' => $xs{macro}{'cm^-1'},  # Array ref

        # PWM and reaction rate
        pwm_micro              => $pwm{micro},               # Array ref
        pwm_micro_tot          => $pwm{micro_tot},
        pwm_macro              => $pwm{macro},               # Array ref
        pwm_macro_tot          => $pwm{macro_tot},
        source_rate            => $pwm{source_rate},
        react_rate_per_vol     => $pwm{react_rate_per_vol},  # Array ref
        react_rate_per_vol_tot => $pwm{react_rate_per_vol_tot},
        react_rate             => $pwm{react_rate},          # Array ref
        react_rate_tot         => $pwm{react_rate_tot},

        # Yield unit
        yield_unit => $yield_unit,
    };
}


1;
__END__