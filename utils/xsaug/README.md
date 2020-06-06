# xsaug

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

<p>xsaug - Augment cross section data</p>

<h1 id="SYNOPSIS">SYNOPSIS</h1>

<pre><code>    python xsaug.py [-h] file</code></pre>

<h1 id="DESCRIPTION">DESCRIPTION</h1>

<pre><code>    Augment cross section data so that
    they can be correctly read by phitar.</code></pre>

<h1 id="OPTIONS">OPTIONS</h1>

<pre><code>    -h, --help
        The argparse help message will be displayed.

    file
        .yaml file describing augmentation conditions</code></pre>

<h1 id="EXAMPLES">EXAMPLES</h1>

<pre><code>    python xsaug.py exfor.yaml</code></pre>

<h1 id="REQUIREMENTS">REQUIREMENTS</h1>

<pre><code>    Python 3
        PyYAML, NumPy, SciPy, pandas, Matplotlib</code></pre>

<h1 id="SEE-ALSO">SEE ALSO</h1>

<p><a href="https://github.com/jangcom/phitar">phitar</a></p>

<p><a href="https://github.com/jangcom/phitar/tree/master/utils/xsconv/xsconv.py">xsconv - Convert the units of cross section variables</a></p>

<h1 id="AUTHOR">AUTHOR</h1>

<p>Jaewoong Jang &lt;jangj@korea.ac.kr&gt;</p>

<h1 id="COPYRIGHT">COPYRIGHT</h1>

<p>Copyright (c) 2020 Jaewoong Jang</p>

<h1 id="LICENSE">LICENSE</h1>

<p>This software is available under the MIT license; the license information is found in &#39;LICENSE&#39;.</p>


</body>

</html>