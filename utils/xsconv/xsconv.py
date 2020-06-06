#!/usr/bin/env python3
import re
import argparse
import yaml
import pandas as pd


def parse_argv():
    """Parse sys.argv"""
    desc = ('Convert the units of cross section variables')
    parser = argparse.ArgumentParser(description=desc)
    parser.add_argument('file',
                        help='.yaml file describing conversion conditions')
    return parser.parse_args()


def parse_yaml(file):
    """Parse a .yaml file"""
    fh = open(file)
    return yaml.load(fh, Loader=yaml.FullLoader)


def xsconv(yml):
    """Convert the units of cross section variables."""
    for xs in yml['xs_of_int']:
        # Preproc
        nrg_col = int(yml[xs]['nrg']['col'])
        nrg_factor = float(yml[xs]['nrg']['multiply_by'])
        xs_col = int(yml[xs]['xs']['col'])
        xs_factor = float(yml[xs]['xs']['multiply_by'])

        # Inbound
        df = pd.read_csv(yml[xs]['inp'], sep=r'\s+', header=None, comment='#')
        df['nrg'] = df.iloc[:, nrg_col] * float(nrg_factor)
        df['xs'] = df.iloc[:, xs_col] * float(xs_factor)

        # Outbound
        out_fh = open(yml[xs]['out'], 'w', encoding='utf-8')
        if yml[xs]['preserve_comments']['toggle']:
            start = int(yml[xs]['preserve_comments']['start_row'])
            stop = int(yml[xs]['preserve_comments']['stop_row'])
            inp_fh = open(yml[xs]['inp'])
            lines = inp_fh.readlines()
            inp_fh.close()
            for i in range(len(lines)):
                if i >= start and i <= stop:
                    out_fh.write(lines[i])
        out_fh.write('# {} {}\n'.format(yml[xs]['headers']['nrg'],
                                        yml[xs]['headers']['xs']))
        out_fh.close()
        df = df.loc[:, ['nrg', 'xs']]
        df.to_csv(yml[xs]['out'], sep=' ', float_format='%g',
                  header=False, index=False, mode='a')
        print('[{}] generated.'. format(yml[xs]['out']))


if __name__ == '__main__':
    args = parse_argv()
    if re.search('(?i)[.]ya?ml$', args.file):
        yml = parse_yaml(args.file)
        xsconv(yml)
    else:
        print('Valid .yaml file not found. Terminating.')
