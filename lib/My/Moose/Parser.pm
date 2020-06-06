#
# Moose class for parsing the input file
#
# Copyright (c) 2018-2020 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package Parser;

use Moose;
use namespace::autoclean;

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.00';
our $LAST     = '2019-01-01';
our $FIRST    = '2018-08-18';

has 'Data' => (
    is      => 'ro',
    isa     => 'Parser::Data',
    lazy    => 1,
    default => sub { Parser::Data->new() },
);

has 'FileIO' => (
    is      => 'ro',
    isa     => 'Parser::FileIO',
    lazy    => 1,
    default => sub { Parser::FileIO->new() },
);

__PACKAGE__->meta->make_immutable;
1;


package Parser::Data;

use Moose;
use namespace::autoclean;
with 'My::Moose::Data';

#
# Additional attributes
#

# Data storage for a list of values
has 'list_val' => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
);

# Delimiters hash
has 'delims' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
    handles => {
        set_delims => 'set',
    },
);

__PACKAGE__->meta->make_immutable;
1;


package Parser::FileIO;

use Moose;
use namespace::autoclean;
with 'My::Moose::FileIO';

__PACKAGE__->meta->make_immutable;
1;