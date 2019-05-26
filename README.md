# phitar

<?xml version="1.0" ?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="content-type" content="text/html; charset=utf-8" />
<link rev="made" href="mailto:" />
</head>

<body>



<ul id="index">
  <li><a href="#NAME">NAME</a></li>
  <li><a href="#SYNOPSIS">SYNOPSIS</a></li>
  <li><a href="#DESCRIPTION">DESCRIPTION</a></li>
  <li><a href="#OPTIONS">OPTIONS</a></li>
  <li><a href="#EXAMPLES">EXAMPLES</a></li>
  <li><a href="#REQUIREMENTS">REQUIREMENTS</a></li>
  <li><a href="#SEE-ALSO">SEE ALSO</a></li>
  <li><a href="#AUTHOR">AUTHOR</a></li>
  <li><a href="#COPYRIGHT">COPYRIGHT</a></li>
  <li><a href="#LICENSE">LICENSE</a></li>
</ul>

<h1 id="NAME">NAME</h1>

<p>phitar - A PHITS wrapper for targetry design</p>

<h1 id="SYNOPSIS">SYNOPSIS</h1>

<pre><code>    perl phitar.pl [run_mode] [-rpt_subdir=dname] [-rpt_fmts=ext ...]
                   [-rpt_flag=str] [-nofm] [-nopause]</code></pre>

<h1 id="DESCRIPTION">DESCRIPTION</h1>

<pre><code>    phitar is a PHITS wrapper written in Perl, intended for the design of
    bremsstrahlung converters and Mo targets. phitar can:
      - examine a range of targetry dimensions and beam parameters
        according to user specifications
      - generate MAPDL table and macro files
      - collect information from PHITS tally outputs and generate
        report files
      - collect information from PHITS general outputs and generate
        report files
      - modify ANGEL inputs and outputs
      - calculate yields and specific yields of Mo-99 and Au-196
      - convert ANGEL-generated .eps files to various image formats
      - generate animations using the converted rasters</code></pre>

<h1 id="OPTIONS">OPTIONS</h1>

<pre><code>    run_mode
        file
            An input file specifying simulation conditions.
            Refer to &#39;args.phi&#39; for the syntax.
        -d
            Run simulations with the default settings.
        -dump_src=particle
                electron
                photon
                neutron
            Run simulations with the dump source.

    -rpt_subdir=dname (short: -subdir, default: reports)
        Name of subdirectory to which report files will be stored.

    -rpt_fmts=ext ... (short: -fmts, default: dat,xlsx)
        Output file formats. Multiple formats are separated by the comma (,).
        all
            All of the following ext&#39;s.
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

    -rpt_flag=str (short: -flag)
        str is appended to the report filenames followed by an underscore.
        Use this option when different materials are simulated
        in the same batch.

    -nofm
        The front matter will not be displayed at the beginning of program.

    -nopause
        The shell will not be paused at the end of program.
        Use it for a batch run.</code></pre>

<h1 id="EXAMPLES">EXAMPLES</h1>

<pre><code>    perl phitar.pl args.phi
    perl phitar.pl -d
    perl phitar.pl -dump=electron -rpt_flag=elec_dmp args.phi
    perl phitar.pl args.phi &gt; phitar.log -nopause
    perl phitar.pl -rpt_flag=au args.phi
    perl phitar.pl -rpt_flag=moo3 args_moo3.phi</code></pre>

<h1 id="REQUIREMENTS">REQUIREMENTS</h1>

<pre><code>    Perl 5
        Moose, namespace::autoclean
        Text::CSV, Excel::Writer::XLSX, JSON, YAML
    PHITS, Ghostscript, Inkscape, ImageMagick, FFmpeg, gnuplot
    (optional) ANSYS MAPDL</code></pre>

<h1 id="SEE-ALSO">SEE ALSO</h1>

<p><a href="https://github.com/jangcom/phitar">phitar on GitHub</a></p>

<h1 id="AUTHOR">AUTHOR</h1>

<p>Jaewoong Jang &lt;jangj@korea.ac.kr&gt;</p>

<h1 id="COPYRIGHT">COPYRIGHT</h1>

<p>Copyright (c) 2018-2019 Jaewoong Jang</p>

<h1 id="LICENSE">LICENSE</h1>

<p>This software is available under the MIT license; the license information is found in &#39;LICENSE&#39;.</p>


</body>

</html>
