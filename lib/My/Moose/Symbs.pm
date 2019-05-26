#
# Moose class for frequently used symbols
#
# Copyright (c) 2018-2019 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package Symbs;

use Moose::Role;
use namespace::autoclean;

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.00';
our $LAST     = '2019-01-01';
our $FIRST    = '2018-08-16';

has 'symbs' => (
    is      => 'ro',
    isa     => 'HashRef[Str]',
    lazy    => 1,
    builder => '_build_symbs',
);

sub _build_symbs {
    return {
        tilde          => '~',
        backtick       => '`',
        exclamation    => '!',
        at_sign        => '@',
        hash           => '#',
        dollar         => '$',
        percent        => '%',
        caret          => '^',
        ampersand      => '&',
        asterisk       => '*',
        parenthesis_lt => '(',
        parenthesis_rt => ')',
        dash           => '-',
        underscore     => '_',
        plus           => '+',
        equals         => '=',
        bracket_lt     => '[',
        bracket_rt     => ']',
        curl_lt        => '{',
        curl_rt        => '}',
        backslash      => '/',
        vert_bar       => '|',
        semicolon      => ',',
        colon          => ':',
        quote          => '\'',
        double_quote   => '"',
        comma          => ',',
        angle_quote_lt => '<',
        period         => '.',
        angle_quote_rt => '>',
        slash          => '/',
        question       => '?',
        space          => ' ',
        tab            => "\t", # Use double quotes to use \t
    };
}

1;