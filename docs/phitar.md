# NAME

phitar - A PHITS wrapper for targetry design

# SYNOPSIS

    perl phitar.pl [run_mode] [--rpt_subdir=dname] [--rpt_fmts=ext ...]
                   [--rpt_flag=str] [--nopause]

# DESCRIPTION

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

# OPTIONS

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

# EXAMPLES

    perl phitar.pl args.phi
    perl phitar.pl -d
    perl phitar.pl --dump=electron --rpt_flag=elec_dmp args.phi
    perl phitar.pl args.phi > phitar.log -nopause
    perl phitar.pl --rpt_flag=au args.phi
    perl phitar.pl --rpt_flag=moo3 args_moo3.phi

# REQUIREMENTS

    Perl 5
        Moose, namespace::autoclean
        Text::CSV, Excel::Writer::XLSX, JSON, YAML
    PHITS, Ghostscript, Inkscape, ImageMagick, FFmpeg, gnuplot
    (optional) ANSYS MAPDL

# SEE ALSO

[phitar on GitHub](https://github.com/jangcom/phitar)

[phitar in a paper: _Nucl. Instrum. Methods Phys. Res. A_ **987** (2021) 164815](https://doi.org/10.1016/j.nima.2020.164815)

## Utilities

- [excel2etype22 - Convert EXCEL-stored energy distribution data to PHITS e-type = 22 data](https://github.com/jangcom/phitar/tree/master/utils/excel2etype22/excel2etype22.py)
- [xsconv - Convert the units of cross section variables](https://github.com/jangcom/phitar/tree/master/utils/xsconv/xsconv.py)
- [xsaug - Augment cross section data](https://github.com/jangcom/phitar/tree/master/utils/xsaug/xsaug.py)
- [joinyld - Join phitar yield files](https://github.com/jangcom/phitar/tree/master/utils/joinyld/joinyld.py)
- [yld2datagen - Convert phitar yield files to a datagen input file](https://github.com/jangcom/phitar/tree/master/utils/yld2datagen/yld2datagen.py)

# AUTHOR

Jaewoong Jang <jangj@korea.ac.kr>

# COPYRIGHT

Copyright (c) 2018-2020 Jaewoong Jang

# LICENSE

This software is available under the MIT license;
the license information is found in 'LICENSE'.
