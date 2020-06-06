#!/usr/bin/env python3
import re
import argparse
import yaml
import pandas as pd
import matplotlib.pyplot as plt


def parse_argv():
    """Parse sys.argv"""
    desc = ('Convert EXCEL-stored energy distribution data'
            + ' to PHITS e-type = 22 data')
    parser = argparse.ArgumentParser(description=desc)
    parser.add_argument('file',
                        help='.yaml file describing conversion conditions')
    return parser.parse_args()


def parse_yaml(file):
    """Parse a .yaml file"""
    fh = open(file)
    return yaml.load(fh, Loader=yaml.FullLoader)


def nrg2etype22(yml):
    """
    Convert EXCEL-stored energy distribution data to PHITS e-type = 22 data.
    """
    for sheet in yml['sheets_of_int']:
        # Inbound
        excel_f = yml['excel_path'] + '/' + yml['excel_fname']
        df = pd.read_excel(excel_f, sheet_name=sheet)
        xcol = yml[sheet]['xcol']
        ycol = yml[sheet]['ycol']
        df = df.loc[:, [xcol, ycol]]  # Take only the xcol and ycol.

        # Outbound: Text
        ycol_norm = 'Normalized'
        df[ycol_norm] = df[ycol] / df[ycol].sum()
        out_f = '{}/{}.txt'.format(yml['out_path'], yml[sheet]['out_bname'])
        df2 = df.loc[:, [xcol, xcol, ycol_norm]]
        df2.to_csv(out_f, sep=' ', header=False, index=False)
        print('[{}] generated.'.format(out_f))

        # Outbound: Plots
        fig, ax = plt.subplots()
        xdata = df[xcol]
        ydata = df[ycol_norm]
        ax.set_xlabel('Energy (MeV)')
        ax.set_ylabel('Normalized count')
        ax.plot(xdata, ydata, 'b-', label=yml[sheet]['lab'])
        plt.legend()
        plt.tight_layout()
        plt.pause(1)
        pdf = '{}/{}.pdf'.format(yml['out_path'], yml[sheet]['out_bname'])
        svg = '{}/{}.svg'.format(yml['out_path'], yml[sheet]['out_bname'])
        for v in [pdf, svg]:
            plt.savefig(v)
            print(f'[{v}] generated.')
        plt.close()


if __name__ == '__main__':
    args = parse_argv()
    if re.search('(?i)[.]ya?ml$', args.file):
        yml = parse_yaml(args.file)
        nrg2etype22(yml)
    else:
        print('Valid .yaml file not found. Terminating.')
