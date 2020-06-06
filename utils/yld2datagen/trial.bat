@echo off
set f_path=./samples
set inp1=%f_path%/gap0p1_yields_mo99-vnrg-wrcc-vhgt0p0001to0p70_peaks_by_fit_annot_peak_data_array.txt
set inp2=%f_path%/gap0p5_yields_mo99-vnrg-wrcc-vhgt0p0001to0p70_peaks_by_fit_annot_peak_data_array.txt
set inp3=%f_path%/gap1p0_yields_mo99-vnrg-wrcc-vhgt0p0001to0p70_peaks_by_fit_annot_peak_data_array.txt
set inp4=%f_path%/gap1p5_yields_mo99-vnrg-wrcc-vhgt0p0001to0p70_peaks_by_fit_annot_peak_data_array.txt
set inp5=%f_path%/gap2p0_yields_mo99-vnrg-wrcc-vhgt0p0001to0p70_peaks_by_fit_annot_peak_data_array.txt
set nrg_of_int=20
set out=%f_path%/nrg20_fwhm15p0_gap1_to_20.gen

python yld2datagen.py %inp1% %inp2% %inp3% %inp4% %inp5% --nrg_of_int %nrg_of_int% --out %out%
