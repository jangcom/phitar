@echo off
set f_path=./samples
set inp1=%f_path%/yields_mo99-vnrg20-wrcc-vhgt0p0001to0p0500.dat
set inp2=%f_path%/yields_mo99-vnrg20-wrcc-vhgt0p10to0p70.dat
set out=%f_path%/yields_mo99-vnrg20-wrcc-vhgt0p0001to0p70.dat

python joinyld.py --out %out% %inp1% %inp2%
