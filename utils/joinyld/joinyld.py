#!/usr/bin/env python3
import sys
import os
import re
import argparse


def parse_argv():
    """Parse sys.argv"""
    parser = argparse.ArgumentParser(description='Join phitar yield files')
    parser.add_argument('-o', '--out',
                        required=True,
                        help='output yield file')
    file_help = ('yield files to be joined;'
                 + ' 2nd files onward will be appended to the 1st file')
    parser.add_argument('file',
                        nargs='+',
                        help=file_help)
    return parser.parse_args()


def joinyld(args):
    """Join phitar yield files."""
    # (1) Reference yield file
    i = 0
    print('Yield file [{}]: [{}]'.format(i, args.file[i]))
    yld0_fh = open(args.file[i])
    yld0_content = yld0_fh.read()
    yld0_fh.close()

    # Remove the closing strings.
    closing_re = re.compile(r'#-+\r?\n#eof')
    closing = closing_re.findall(yld0_content)
    yld0_content = re.sub(closing_re, '', yld0_content)

    # Write to the output file.
    out_fh = open(args.out, 'w', encoding='utf-8')
    out_fh.write(yld0_content)

    # (2) Remaining yield files
    i += 1
    for f in args.file[i:]:
        print('Yield file [{}]: [{}]'.format(i, f))
        yld_fh = open(f)
        yld_content = yld_fh.read()
        yld_fh.close()

        # Remove non-columnar data.
        yld_content = re.sub(r'(\r?\n)\r?\n', r'\1', yld_content)
        yld_content = re.sub(r'#.*\r?\n', '', yld_content)
        yld_content = re.sub(r'#eof', '', yld_content)

        # Append to the output file.
        out_fh.write(yld_content)
        i += 1  # Does not affect [i:]

    # (3) Recover the closing strings and notify the file generation.
    out_fh.write(closing[0])
    out_fh.close()
    idt = len('Yield file [{}]'.format(i)) - len('Output file')
    print('Output file:{} [{}]'.format(' ' * idt, args.out))


if __name__ == '__main__':
    args = parse_argv()
    for f in args.file:
        if not os.path.exists(f):
            print(f'[{f}] not found. Terminating.')
            sys.exit()
        if not os.path.isfile(f):
            print(f'[{f}] is not a file. Terminating.')
            sys.exit()

    joinyld(args)
    input('Press enter to exit...')
