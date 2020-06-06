# yld2datagen

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

<p>yld2datagen - Convert phitar yield files to a datagen input file</p>

<h1 id="SYNOPSIS">SYNOPSIS</h1>

<pre><code>    python yld2datagen.py [-h] --nrg_of_int NRG_OF_INT -o OUT
                          file [file ...]</code></pre>

<h1 id="DESCRIPTION">DESCRIPTION</h1>

<pre><code>    By converting phitar yield files to a datagen input file,
    the phitar yield data can become a function of a different
    independent variable.
    For example, phitar yields calculated as a function of beam energy
    can become a function of of W-MoO3 gap.</code></pre>

<h1 id="OPTIONS">OPTIONS</h1>

<pre><code>    -h, --help
        The argparse help message will be displayed.

    --nrg_of_int NRG_OF_INT
        Beam energy of interest

    -o OUT, --out OUT
        Output file to become a datagen input file

    file ...
        Ordered list of phitar yield files</code></pre>

<h1 id="EXAMPLES">EXAMPLES</h1>

<pre><code>    python yld2datagen.py ^
        gap0p1_yields_mo99-vnrg-wrcc-vhgt0p0001to0p70_peaks_by_fit_annot_peak_data_array.txt ^
        gap0p5_yields_mo99-vnrg-wrcc-vhgt0p0001to0p70_peaks_by_fit_annot_peak_data_array.txt ^
        --nrg_of_int 20 ^
        --out nrg20_fwhm15p0_gap1_to_20.gen</code></pre>

<h1 id="REQUIREMENTS">REQUIREMENTS</h1>

<p>Python 3</p>

<h1 id="SEE-ALSO">SEE ALSO</h1>

<p><a href="https://github.com/jangcom/phitar">phitar</a></p>

<p><a href="https://github.com/jangcom/datagen">datagen</a></p>

<h1 id="AUTHOR">AUTHOR</h1>

<p>Jaewoong Jang &lt;jangj@korea.ac.kr&gt;</p>

<h1 id="COPYRIGHT">COPYRIGHT</h1>

<p>Copyright (c) 2020 Jaewoong Jang</p>

<h1 id="LICENSE">LICENSE</h1>

<p>This software is available under the MIT license; the license information is found in &#39;LICENSE&#39;.</p>


</body>

</html>
