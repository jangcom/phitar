#!/usr/bin/env python3
import sys
import os
import re
import argparse

tpl_top = """\
# Perl code snippet for datagen.pl
# Simple version
# J. Jang
# 2019-04-21

#
# (i)-(iv):  Required
# (v)-(vii): Optional
#

# (i) Number of data columns
$num_of_cols = 5;

# (ii) Headings
# - The number of elements must be the same as $num_of_cols assigned in (i).
#   (assign "" where no heading is necessary)
$heads_aref = [
    "Beam energy",
    "Beam size in FWHM",
    "Gap between W and MoO_{3}",
    "W thickness at peak ^{99}Mo yield",
    "Peak ^{99}Mo yield",
];

# (iii) Subheadings
# - The number of elements must be the same as $num_of_cols assigned in (i).
#   (assign "" where no subheading is necessary)
$subheads_aref = [
    "(MeV)",
    "(mm)",
    "(mm)",
    "(mm)",
    "(kBq g^{-1} uA^{-1})",
];
"""

tpl_mid = """
# (iv) Columnar data
# - The number of elements must be an integer multiple of
#   $num_of_cols assigned in (i). For example, if $num_of_cols is 4,
#   the number of elements of $data_aref must be 4, 8, 12, ..., etc.
$data_aref = [
"""

tpl_bot = """\
];

# (v) Column ordinal numbers where the sums will be calculated and appended
# - Assign [] if not necessary.
$sum_idx = [];

# (vi) Column ordinal numbers where the data will be aligned ragged-left
# - Assign [] if not necessary.
$ragged_left_idx = [1..4];

# (vii) An Excel cell at which the pane will be frozen.
# - Assign "" if not necessary.
$freeze_panes = "C4"; # e.g. 'C4' or {row => 3, col => 2}
"""


def parse_argv():
    """Parse sys.argv"""
    desc = 'Convert phitar yield files to a datagen input file'
    parser = argparse.ArgumentParser(description=desc)
    parser.add_argument('--nrg_of_int',
                        required=True,
                        help='beam energy of interest')
    parser.add_argument('-o', '--out',
                        required=True,
                        help='output file to become a datagen input file')
    parser.add_argument('file',
                        nargs='+',
                        help='ordered list of phitar yield files')
    return parser.parse_args()


def yld2datagen(args):
    """Convert phitar yield files to a datagen input file."""
    # datagen template: Top and middle
    datagen_fh = open(args.out, 'w', encoding='utf-8')
    datagen_fh.write(tpl_top)
    datagen_fh.write(tpl_mid)

    # datagen template: Data array
    print('-' * 70)
    for yld_f in args.file:
        print('[{}] read in.'.format(yld_f))
        for line in open(yld_f):
            if re.search(r'^\s*#', line):
                continue
            nums = re.split(r',?\s+', line)
            # Write a line to the output file if its first element is
            # equal to the designated energy of interest.
            if nums[0] == args.nrg_of_int:
                datagen_fh.write(' ' * 4)
                datagen_fh.write(', '.join(nums))
                datagen_fh.write('\n')

    # datagen template: Bottom
    datagen_fh.write(tpl_bot)
    datagen_fh.close()

    print('-' * 70)
    print('-> Converted to [{}].'.format(args.out))


if __name__ == '__main__':
    args = parse_argv()
    for f in args.file:
        if not os.path.exists(f):
            print(f'[{f}] not found. Terminating.')
            sys.exit()
        if not os.path.isfile(f):
            print(f'[{f}] is not a file. Terminating.')
            sys.exit()

    yld2datagen(args)
    input('Press enter to exit...')
