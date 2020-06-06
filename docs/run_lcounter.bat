@echo off
set rpt_path=./lines_counted
set phitar_path=..
set lib_path=../lib/My
set moose_path=%lib_path%/Moose
set file1=%phitar_path%/phitar.pl
set file2=%lib_path%/Toolset.pm
set file3=%lib_path%/Nuclear.pm
set file4=%moose_path%/Animate.pm
set file5=%moose_path%/ANSYS.pm
set file6=%moose_path%/Cmt.pm
set file7=%moose_path%/Ctrls.pm
set file8=%moose_path%/Data.pm
set file9=%moose_path%/FileIO.pm
set file10=%moose_path%/gnuplot.pm
set file11=%moose_path%/Image.pm
set file12=%moose_path%/Linac.pm
set file13=%moose_path%/MonteCarloCell.pm
set file14=%moose_path%/Parser.pm
set file15=%moose_path%/PHITS.pm
set file16=%moose_path%/Phys.pm
set file17=%moose_path%/Tally.pm
set file18=%moose_path%/Yield.pm

lcounter.pl --path=%rpt_path% %file1% %file2% %file3% %file4% %file5% %file6% %file7% %file8% %file9% %file10% %file11% %file12% %file13% %file14% %file15% %file16% %file17% %file18%
