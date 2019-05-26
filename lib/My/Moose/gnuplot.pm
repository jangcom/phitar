#
# Moose class for gnuplot
#
# Copyright (c) 2018-2019 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package gnuplot;

use Moose;
use namespace::autoclean;

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.00';
our $LAST     = '2019-01-18';
our $FIRST    = '2018-08-18';

has 'Cmt' => (
    is      => 'ro',
    isa     => 'gnuplot::Cmt',
    lazy    => 1,
    default => sub { gnuplot::Cmt->new() },
);

has 'Ctrls' => (
    is      => 'ro',
    isa     => 'gnuplot::Ctrls',
    lazy    => 1,
    default => sub { gnuplot::Ctrls->new() },
);

has 'Data' => (
    is      => 'ro',
    isa     => 'gnuplot::Data',
    lazy    => 1,
    default => sub { gnuplot::Data->new() },
);

has 'exe' => (
    is       => 'ro',
    isa      => 'Str',
    default  => 'gnuplot.exe',
    lazy     => 1,
    writer   => 'set_exe',
);

__PACKAGE__->meta->make_immutable;
1;


package gnuplot::Cmt;

use Moose;
use namespace::autoclean;
with 'My::Moose::Cmt';

__PACKAGE__->meta->make_immutable;
1;


package gnuplot::Ctrls;

use Moose;
use namespace::autoclean;
with 'My::Moose::Ctrls';

__PACKAGE__->meta->make_immutable;
1;


package gnuplot::Data;

use Moose;
use namespace::autoclean;
with 'My::Moose::Data';

__PACKAGE__->meta->make_immutable;
1;