#!/usr/bin/env python3
import re
import argparse
import yaml
import numpy as np
import scipy.optimize as opt
import pandas as pd
import matplotlib as mpl
import matplotlib.pyplot as plt
from matplotlib.ticker import AutoMinorLocator


def parse_argv():
    """Parse sys.argv"""
    desc = ('Augment cross section data')
    parser = argparse.ArgumentParser(description=desc)
    parser.add_argument('file',
                        help='.yaml file describing augmentation conditions')
    return parser.parse_args()


def parse_yaml(file):
    """Parse a .yaml file"""
    fh = open(file)
    return yaml.load(fh, Loader=yaml.FullLoader)


def exp1(x, a, b):
    """Fitting function: One-term exponential"""
    return a*np.exp(b*x)


def exp2(x, a, b, c, d):
    """Fitting function: Two-term exponential"""
    return a*np.exp(b*x) + c*np.exp(d*x)


def xsaug(yml):
    """Augment cross section data."""
    for xs in yml['xs_of_int']:
        # Preproc
        inp = yml[xs]['inp']
        out_bname = yml[xs]['out_bname']
        headers_nrg = yml[xs]['headers']['nrg']
        headers_xs = yml[xs]['headers']['xs']
        nrg_col = int(yml[xs]['nrg']['col'])
        nrg_fit_start = float(yml[xs]['nrg']['fit_start'])
        nrg_fit_stop = float(yml[xs]['nrg']['fit_stop'])
        nrg_extrap_start = float(yml[xs]['nrg']['extrap_start'])
        nrg_extrap_stop = float(yml[xs]['nrg']['extrap_stop'])
        nrg_extrap_num = int(yml[xs]['nrg']['extrap_num'])
        xs_col = int(yml[xs]['xs']['col'])
        _fit_func = yml[xs]['fit']['func']
        fit_p0 = yml[xs]['fit']['p0']
        plt_style = yml[xs]['plt']['style']
        plt_title = yml[xs]['plt']['title']
        plt_dat_lab = yml[xs]['plt']['dat']['lab']
        plt_dat_mrk = yml[xs]['plt']['dat']['mrk']
        plt_extrap_lab = yml[xs]['plt']['extrap']['lab']
        plt_extrap_mrk = yml[xs]['plt']['extrap']['mrk']
        plt_xlim_start = float(yml[xs]['plt']['xlim']['min'])
        plt_xlim_stop = float(yml[xs]['plt']['xlim']['max'])
        plt_fmts = yml[xs]['plt']['fmts']

        # Inbound
        df = pd.read_csv(inp, sep=r'\s+', header=None, comment='#')
        df['nrg'] = df.iloc[:, nrg_col]
        df['xs'] = df.iloc[:, xs_col]

        # Fitting
        fit_func = exp2 if re.search(r'(?i)exp.*2$', _fit_func) else exp1
        nrg_fit = df.loc[((df['nrg'] >= nrg_fit_start)
                          & (df['nrg'] <= nrg_fit_stop)), 'nrg']
        xs_fit = df.loc[((df['nrg'] >= nrg_fit_start)
                         & (df['nrg'] <= nrg_fit_stop)), 'xs']
        coeffs, covar = opt.curve_fit(fit_func, nrg_fit, xs_fit, p0=fit_p0)

        # Extrapolation
        nrg_extrap = np.linspace(nrg_extrap_start, nrg_extrap_stop,
                                 num=nrg_extrap_num)
        xs_extrap = fit_func(nrg_extrap, *coeffs)

        # Data concatenation and export
        out = f'{out_bname}.dat'
        out_fh = open(out, 'w', encoding='utf-8')
        if yml[xs]['preserve_comments']['toggle']:
            start = int(yml[xs]['preserve_comments']['start_row'])
            stop = int(yml[xs]['preserve_comments']['stop_row'])
            inp_fh = open(inp)
            lines = inp_fh.readlines()
            inp_fh.close()
            for i in range(len(lines)):
                if i >= start and i <= stop:
                    out_fh.write(lines[i])
        out_fh.write(f'# {headers_nrg} {headers_xs}\n')
        out_fh.close()
        nrg_first_half = df.loc[df['nrg'] <= nrg_fit_stop, 'nrg']
        xs_first_half = df.loc[df['nrg'] <= nrg_fit_stop, 'xs']
        nrg_concat = list(nrg_first_half) + list(nrg_extrap)
        xs_concat = list(xs_first_half) + list(xs_extrap)
        df2 = pd.DataFrame({headers_nrg: nrg_concat, headers_xs: xs_concat})
        df2.to_csv(out, sep=' ', float_format='%g',
                   header=False, index=False, mode='a')
        print(f'[{out}] generated.')

        # Plotting
        plt.style.use(plt_style)
        serifs = ['Arial'] + mpl.rcParams['font.sans-serif']  # Arial first
        serifs = list(dict.fromkeys(serifs))
        mpl.rcParams.update({'font.sans-serif': serifs,
                             'pdf.fonttype': 42})
        fig, ax = plt.subplots()
        ax.set_title(plt_title)
        ax.tick_params(axis='both', which='major', direction='in',
                       length=5, labelsize=12)
        ax.xaxis.set_minor_locator(AutoMinorLocator(2))
        ax.yaxis.set_minor_locator(AutoMinorLocator(2))
        ax.set_xlabel(headers_nrg, labelpad=15)
        ax.set_ylabel(headers_xs, labelpad=15)
        ax.set_xlim(plt_xlim_start, plt_xlim_stop)
        ax.plot(nrg_first_half, xs_first_half, plt_dat_mrk,
                label=plt_dat_lab, alpha=.5)
        ax.plot(nrg_extrap, xs_extrap, plt_extrap_mrk,
                label=plt_extrap_lab, alpha=.5)
        ax.legend()
        fig.tight_layout()
        plt.pause(1)
        for fmt in plt_fmts:
            f = out_bname + '.' + fmt.lower()
            fig.savefig(f)
            print(f'[{f}] generated.')


if __name__ == '__main__':
    args = parse_argv()
    if re.search('(?i)[.]ya?ml$', args.file):
        yml = parse_yaml(args.file)
        xsaug(yml)
    else:
        print('Valid .yaml file not found. Terminating.')
