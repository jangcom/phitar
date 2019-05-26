#
# Moose class for wrapping ImageMagick and ffmpeg
#
# Copyright (c) 2018-2019 Jaewoong Jang
# This script is available under the MIT license;
# the license information is found in 'LICENSE'.
#
package Animate;

use Moose;
use namespace::autoclean;
use feature qw(say);

our $PACKNAME = __PACKAGE__;
our $VERSION  = '1.02';
our $LAST     = '2019-05-18';
our $FIRST    = '2018-08-19';

has 'Cmt' => (
    is      => 'ro',
    isa     => 'Animate::Cmt',
    lazy    => 1,
    default => sub { Animate::Cmt->new() },
);

has 'Ctrls' => (
    is      => 'ro',
    isa     => 'Animate::Ctrls',
    lazy    => 1,
    default => sub { Animate::Ctrls->new() },
);

has 'FileIO' => (
    is      => 'ro',
    isa     => 'Animate::FileIO',
    lazy    => 1,
    default => sub { Animate::FileIO->new() },
);

has 'exes' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Str]',
    default => sub {
        {
            imagemagick          => 'magick.exe', # Legacy: 'convert.exe'
            imagemagick_identify => 'identify.exe',
            ffmpeg               => 'ffmpeg.exe',
        }
    },
    handles => {
        set_exes => 'set',
    }
);

# Reference to an array containing filename flags that will be used
# for grouping raster image files; the grouped rasters will then be
# converted to respective animation files.
has 'anim_flags' => (
    traits  => ['Array'],
    is      => 'rw',
    isa     => 'ArrayRef',
    default => sub { [] },
    handles => {
        uniq_anim_flags  => 'uniq',
        clear_anim_flags => 'clear',
    },
);

# To prevent unnecessary re-runs
has 'examined_dirs' => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
    handles => {
        set_examined_dirs   => 'set',
        clear_examined_dirs => 'clear',
    },
);

# Animating options
my %_anim_opts = ( # (key) attribute => (val) default
    loop          => 0,
    sec_per_frame => 1/100,
    delay         => 100,
);

has $_ => (
    is      => 'ro',
    isa     => 'Num',
    default => $_anim_opts{$_},
    lazy    => 1,
    writer  => 'set_'.$_,
) for keys %_anim_opts;


sub rasters_to_anims {
    # """Animate raster images."""
    
    #
    # Note on subroutine generalization
    #
    # 2019/05/15-16
    # > Initially written for phitar, this routine has now been generalized.
    #   Use img2ani for animating raster images.
    #
    
    my $self = shift;
    # Arg 1: an aref containing raster directories
    # > phitar:  aref containing multiple subdirectories
    # > img2ani: aref containing one directory
    my @raster_dirs = @{$_[0]};
    # Arg 2: a scalar containing the raster format to be animated
    # > 'png', 'jpg'
    my $raster_format = $_[1];
    $raster_format =~ s/jpeg/jpg/i;
    
    # Graphics resolutions for YUV420p
    # > When used with the -vf scale=<xres:yres> command-line
    #   option of FFmpeg, the number -2 in <xres:yres> adjusts
    #   the corresponding resolution such that it becomes divisible by 2
    #   while the original aspect ratio is preserved.
    #   For example:
    #   (1) By -vf scale=1280:-2,
    #       an input stream sized 842x595 (aspect ratio 1.415) becomes
    #       an output stream sized 1280x904 (aspect ratio 1.415).
    #   (2) (Preferable) By -vf scale=-2:720,
    #       an input stream sized 842x595 (aspect ratio 1.415) becomes
    #       an output stream sized 1018x720 (aspect ratio 1.414).
    #   (3) By -vf scale=640:-2,
    #       an input stream sized 842x595 (aspect ratio 1.415) becomes
    #       an output stream sized 640x452 (aspect ratio 1.416).
    #   (4) By -vf scale=-2:480,
    #       an input stream sized 842x595 (aspect ratio 1.415) becomes
    #       an output stream sized 680x480 (aspect ratio 1.417).
    my %resolutions = (
        # 4:3
        vga => {
            flag          => 'VGA',
            fixed         => '640:480',
            width_scaled  => '-2:480',
            height_scaled => '640:-2',
        },
        # 16:9
        hd => {
            flag          => 'HD',
            fixed         => '1280:720',
            width_scaled  => '-2:720',
            height_scaled => '1280:-2',
        },
        fhd => {
            flag          => 'Full HD',
            fixed         => '1920:1080',
            width_scaled  => '-2:1080',
            height_scaled => '1920:-2',
        },
        qhd => {
            flag          => 'Quad HD',
            fixed         => '2560:1440',
            width_scaled  => '-2:1440',
            height_scaled => '2560:-2',
        },
        four_k_uhd => { # Double full HD
            flag          => '4K UHD',
            fixed         => '3840:2160',
            width_scaled  => '-2:2160',
            height_scaled => '3840:-2',
        },
    );
    
    # Animating programs
    my %progs = (
        imagemagick  => {
            switch   => $self->Ctrls->gif_switch,
            flag     => 'ImageMagick',
            env_var  => '', # To be examined
            exe      => $self->exes->{imagemagick},
            mute_opt => $self->Ctrls->mute =~ /on/i ?
                '' : ' -verbose',
            gif      => {
                switch     => $self->Ctrls->gif_switch,
                # Below: To be filled in later
                fname      => '',
                fname_full => '',
                cmd_opts   => '',
            },
        },
        ffmpeg => {
            switch   => (
                   $self->Ctrls->avi_switch =~ /on/i
                or $self->Ctrls->mp4_switch =~ /on/i
            ) ? 'on' : 'off',
            flag     => 'ffmpeg',
            env_var  => '',
            exe      => $self->exes->{ffmpeg},
            mute_opt => $self->Ctrls->mute =~ /on/i ?
                ' -loglevel panic -hide_banner' : '',
            # .avi, to be encoded in "MPEG-4 and YUV420p"
            avi      => {
                fname      => '',
                fname_full => '',
                switch     => $self->Ctrls->avi_switch,
                cmd_opts   => '',
                vcodec     => 'mpeg4',   # FFmpeg default: mpeg4
                resolution => '',        # Determined wrto the raster size.
                chroma     => 'yuv420p', # FFmpeg default: yuv420p
                kbps       => $self->Ctrls->avi_kbps,
            },
            # .mp4, to be encoded in "H.264 and YUV420p"
            mp4      => {
                fname      => '',
                fname_full => '',
                switch     => $self->Ctrls->mp4_switch,
                cmd_opts   => '',
                vcodec     => 'libx264', # FFmpeg default: libx264
                resolution => '',
                chroma     => 'yuv420p', # FFmpeg default: yuv444p
                crf        => $self->Ctrls->mp4_crf,
            },
        },
    );
    
    # Define comment borders.
    $self->Cmt->set_symb('*');
    $self->Cmt->set_borders(
        leading_symb => $self->Cmt->symb,
        border_symbs => ['*', '=', '-'],
    );
    
    # Warn for insufficient path environment variables.
    # (1) Check path env var: ImageMagick
    # (2) Check path env var: FFmpeg - standalone
    foreach (split $self->FileIO->env_var_delim, $ENV{PATH}) {
        $progs{imagemagick}{env_var} = $_ if /imagemagick/i;
        $progs{ffmpeg}{env_var}      = $_ if /ffmpeg/i;
    }
    # (3) Check path env var: FFmpeg - Residing in the ImageMagick dir
    $progs{ffmpeg}{env_var} = 1 if (
        not $progs{ffmpeg}{env_var} # ffmpeg having no path env var,
        and -e (                    # but installed within ImageMagick dir
            $progs{imagemagick}{env_var}.
            $self->FileIO->path_delim.
            $progs{ffmpeg}{exe}
        )
    );
    # (4) Warn if the path env vars are not sufficient.
    my @_progs_switched = $progs{ffmpeg}{switch} =~ /on/i ?
        qw(imagemagick ffmpeg) : qw(imagemagick);
    foreach my $k (@_progs_switched) {
        if (not $progs{$k}{env_var}) {
            say "";
            say $self->Cmt->borders->{'*'};
            printf(
                "%s Env var for [%s] NOT found!\n\a",
                $self->Cmt->symb,
                $progs{$k}{flag}
            );
            say $self->Cmt->borders->{'*'};
        }
    }
    
    # Exit the routine if none of the animation switches has been turned on.
    if (
        $self->Ctrls->gif_switch =~ /off/i
        and $self->Ctrls->avi_switch =~ /off/i
        and $self->Ctrls->mp4_switch =~ /off/i
    ) {
        print "\n  No animation format specified; terminating.\n";
        return;
    }
    
    # Notify the beginning of the routine.
    say "";
    say $self->Cmt->borders->{'='}; # Top rule
    printf(
        "%s [%s] animating\n".
        "%s the \U$raster_format"." images through [%s]".
        "%s...\n",
        $self->Cmt->symb, join('::', (caller(0))[0, 3]),
        $self->Cmt->symb, $progs{imagemagick}{exe},
        $progs{ffmpeg}{switch} =~ /on/i ? " and \[$progs{ffmpeg}{exe}\]" : ""
    );
    
    # If the animation duration passed is zero or negative, default it to 5.
    if ($self->Ctrls->duration <= 0) {
        say $self->Cmt->symb;
        say $self->Cmt->symb." [duration] is less than or equal to 0;".
                             " defaulting to 5.";
        say $self->Cmt->symb;
        $self->Ctrls->set_duration(5);
    }
    say $self->Cmt->borders->{'='}; # Bottom rule
    
    # Hook for phitar
    my $is_phitar = 0;
    $is_phitar    = 1 if (split /\/|\\/, (caller)[1])[-1] =~ /phitar([.]pl)?/i;
    
    #
    # Iterate over the directories containing raster image files.
    #
    # I have intentionally not used the combination of 'chdir' and
    # 'grep /<regex>/, glob *', which can provide shorter lines of code,
    # so as to allow this subroutine path-independent.
    # One can do, for example, 'chdir ./some_dir/', glob, and grep the
    # raster image files, run magick.exe, and do 'chdir ../' to return
    # to the Perl-working directory to process the other subdirectories.
    # 
    # If, however, the directory arguments contain deeper subdirectories
    # like './some_dir/some_other_dir/', the command for returning to
    # the Perl-working directory 'chdir ../' will not work,
    # as the relative path to it will be now '../../'.
    # This can be solved by using the Cwd module and
    # memorizing the absolute path of the Perl script,
    # but I simply do not prefer to do so.
    #
    foreach my $dir (@raster_dirs) {
        next unless -d $dir;
        $dir =~ s/[\\\/]+$//; # Path delim will be added later.
        
        #
        # When a raster-containing subdirectory has been visited,
        # make the subdirectory not to be revisited.
        # This has two purposes:
        # (1) To prevent unnecessary reruns when both W and Mo are
        #     of interest. In such cases, if the switch for ImageMagick
        #     or FFmpeg has been turned on, raster images are animated
        #     in the order of W and Mo.
        #     Without the control below, the W raster directories are
        #     unnecessarily revisited and reanimated before
        #     the Mo raster images are animated.
        # (2) To prevent reanimation when both png and jpeg have been
        #     passed to this subroutine during the same program run.
        #     When a raster-containing subdirectory contains
        #     both png and jpeg rasters with the same barenames
        #     and if the png ones have been animated, reanimating
        #     the jpeg ones will overwrite the png-based GIFs.
        #
        next if defined $self->examined_dirs->{$dir};
        $self->set_examined_dirs($dir => 1);
        
        #
        # Collect filename flags to group raster images.
        #
        $self->clear_anim_flags(); # Initialization
        
        # (i) phitar-called
        # > Fixed:    a sequential string (e.g. '002' for photon)
        # > Variable: strings; e.g.
        #             w_rcc-vhgt0p33-frad1p00-fgap0p15-track-xz-
        #             w_rcc-vhgt0p34-frad1p00-fgap0p15-track-xz-
        #             w_rcc-vhgt0p35-frad1p00-fgap0p15-track-xz-
        if ($is_phitar) {
            opendir my $_dir_dh, $dir or die "Unable to open $dir: $!";
            foreach my $raster (readdir $_dir_dh) {
                next if not $raster =~ $raster_format; # e.g. .png, .jpg
                
                #
                # Take the last filename elements,
                # which are ascending numbers assigned by Ghostscript.
                #
                # e.g. The following PS images are rasterized by gs:
                #      w_rcc-vhgt0p33-frad1p00-fgap0p15-track-xz.eps
                #      w_rcc-vhgt0p34-frad1p00-fgap0p15-track-xz.eps
                #
                #      The following raster images are then generated:
                #      (as each of the PS image contains 3 pages)
                #      w_rcc-vhgt0p33-frad1p00-fgap0p15-track-xz-001.png
                #      w_rcc-vhgt0p33-frad1p00-fgap0p15-track-xz-002.png
                #      w_rcc-vhgt0p33-frad1p00-fgap0p15-track-xz-003.png
                #      w_rcc-vhgt0p34-frad1p00-fgap0p15-track-xz-001.png
                #      w_rcc-vhgt0p34-frad1p00-fgap0p15-track-xz-002.png
                #      w_rcc-vhgt0p34-frad1p00-fgap0p15-track-xz-003.png
                #
                #      We take the last digits:
                #      001, 002, 003 are taken and stored into
                #      @{$self->anim_flags}. (to be exact, in the above example,
                #      001, 002, 003, 001, 002, 003 are taken,
                #      but will be uniq-ed to 001, 002, 003.)
                #
                $raster =~ s/[.]$raster_format$//; # Remove ext and its delim.
                push @{$self->anim_flags},
                    (split $self->FileIO->fname_sep, $raster)[-1];
            }
            closedir $_dir_dh;
            
            # Remove duplicate items.
            @{$self->anim_flags} = $self->uniq_anim_flags();
            
            # Show the dir of interest and flags identified.
            say "" if $dir ne $raster_dirs[0]; # Row sep from 2nd iter
            say $self->Cmt->borders->{'-'};
            print $self->Cmt->symb." Dir of interest:  [$dir]\n";
            print $self->Cmt->symb." Flags identified: ";
            print "[$_]" for @{$self->anim_flags};
            print "\n";
            say $self->Cmt->borders->{'-'};
        }
        
        # (ii) Called by other than phitar (e.g. img2ani)
        # > Fixed:    a string (e.g. shiba)
        # > Variable: sequential strings (e.g. 001, 002, ...)
        else { push @{$self->anim_flags}, $self->FileIO->seq_bname }
        
        #
        # Iterate over the collected filename flags.
        #
        foreach my $flag (@{$self->anim_flags}) {
            say "" if $flag ne $self->anim_flags->[0]; # Row sep from 2nd iter
            say "  Flag of interest: [$flag]";
            
            # Buffer the rasters to be animated.
            my @to_be_anim; # Initialization
            my $is_first_raster = 1;
            opendir my $dir_dh, $dir or die "Unable to open $dir: $!";
            foreach my $raster (sort readdir $dir_dh) {
                next if not $raster =~ /[.]$raster_format$/;
                
                if ($raster =~ /$flag/i) {
                    # ani_bname for img2ani-called
                    # > Look up "ani_bname for phitar-called"
                    if (
                        not $is_phitar #<--Important hook
                        and $is_first_raster
                        and not $self->FileIO->ani_bname
                    ) {
                        $self->FileIO->set_ani_bname($&); # The matched part
                        $is_first_raster = 0;
                    }
                    
                    # Fill in a storage with to-be-animated rasters.
                    # > Store the rasters including their paths.
                    # > The 'next' command below is necessary not to animate
                    #   fname.png and fname_trn.png together, which can be
                    #   generated from the convert routine of Image.pm.
                    #   Use this hook for phitar.
                    next if $is_phitar and not $raster =~ /$flag[.]/i;
                    push @to_be_anim, sprintf(
                        "%s%s%s",
                        $dir,
                        $self->FileIO->path_delim,
                        $raster,
                    );
                }
            }
            close $dir_dh;
            
            # Exit the routine if no raster file is available.
            if (not $to_be_anim[0]) {
                print "\n  No [$raster_format] file found; terminating.\n";
                return;
            }
            
            #
            # Determine the video resolution based on the pixel size of
            # the "first" raster out of the rasters in queue.
            #
            
            # Fetch the pixel size using the identify executable of ImageMagick.
            my($_the_cmd, $_identified_width_height);
            $_the_cmd = sprintf(
                "%s -ping -format \"%s\" %s",
                $self->exes->{imagemagick_identify},
                '%w:%h',
                $to_be_anim[0],
            );
            $_identified_width_height = `$_the_cmd`;
            
            # Find the closest height to the identified height.
            my $_is_first_iter  = 1;
            my $_abs_diff       = 0;
            my $_least_abs_diff = 0;
            my $the_resolution  = 'hd'; # Default
            foreach my $k (keys %resolutions) {
                # Absolute height difference between the first raster
                # and the resolution standards
                $_abs_diff = abs(
                      (split /[:]/, $_identified_width_height)[1]
                    - (split /[:]/, $resolutions{$k}{fixed})[1]
                );
                # One-time initialization
                if ($_is_first_iter) {
                    $_least_abs_diff = $_abs_diff;
                    $the_resolution  = $k;
                    $_is_first_iter  = 0; # Block-blocker
                }
                # Find the smallest absolute height difference.
                if ($_abs_diff < $_least_abs_diff) {
                    $_least_abs_diff = $_abs_diff;
                    $the_resolution  = $k;
                }
            }
            
            # Assign the resolutions to the video formats.
            foreach my $video (qw(avi mp4)) {
                $progs{ffmpeg}{$video}{resolution} =
                    $resolutions{$the_resolution}{width_scaled};
            }
            
            # Show the frame information identified and
            # its effects on the animation settings.
            my $fps = (
                $self->Ctrls->duration
                * $self->delay
                * $self->sec_per_frame
                / @to_be_anim
            )**-1;
            printf(
                "  Frame pixel size: [%s] => %s (%s)\n",
                $_identified_width_height,
                $resolutions{$the_resolution}{fixed},
                $resolutions{$the_resolution}{flag}
            );
            printf("  Number of frames: [%d]\n",       (@to_be_anim * 1)     );
            printf("  Duration:         [%s s]\n",     $self->Ctrls->duration);
            printf("  Frame rate:       [%.4g fps]\n", $fps                  );
            
            #
            # Define the animation filenames using the raster dir name.
            #
            
            # ani_bname for phitar-called
            # > Look up "ani_bname for img2ani-called"
            if ($is_phitar) {
                (my $ani_backbone = $dir) =~ s!^ [.(/ | \\)]* !!x;
                $self->FileIO->set_ani_bname(
                    $ani_backbone.            # w_rcc-vhgt-frad-fgap-track-xz
                    $self->FileIO->fname_sep. # -
                    $flag                     # 001
                )
            }
            
            # ImageMagick - .gif
            $progs{imagemagick}{gif}{fname} =
                $self->FileIO->ani_bname.
                $self->FileIO->fname_ext_delim.
                $self->FileIO->fname_exts->{gif};
            $progs{imagemagick}{gif}{fname_full} =
                $dir.
                $self->FileIO->path_delim.
                $progs{imagemagick}{gif}{fname};
            
            # FFmpeg - .avi, .mp4
            foreach my $ani (qw(avi mp4)) {
                $progs{ffmpeg}{$ani}{fname} =
                    $self->FileIO->ani_bname.
                    $self->FileIO->fname_ext_delim.
                    $self->FileIO->fname_exts->{$ani};
                $progs{ffmpeg}{$ani}{fname_full} =
                    $dir.
                    $self->FileIO->path_delim.
                    $progs{ffmpeg}{$ani}{fname};
            }
            
            #
            # Define the command-line options.
            #
            
            # ImageMagick - .gif
            $progs{imagemagick}{gif}{cmd_opts} = sprintf(
                "%s".  # Verbose option
                " -loop %s".
                " -delay %s".
                " %s". # Inputs
                " %s", # The output
                $progs{imagemagick}{mute_opt},
                $self->loop,
                $self->Ctrls->duration * $self->delay / @to_be_anim,
                join(' ', @to_be_anim),
                $progs{imagemagick}{gif}{fname_full},
            );
            
            # FFmpeg - Common
            # > QuickTime and PowerPoint (For 2010, QuickTime installation
            #   required. For >2013, NOT required.) can play back videos
            #   chroma-subsampled in YUV 4:2:0 (to which YUV420p belongs),
            #   BUT NOT the ones subsampled in YUV 4:2:2 or YUV 4:2:4.
            # > Important chroma subsampling requirements:
            #   > YUV 4:2:0 requires the video "height" to be divisible by 2.
            #   > YUV 4:2:2 requires the video "width"  to be divisible by 2.
            #   > YUV 4:4:4 does not requre any.
            # > H.264/MPEG-4 AVC, or simply H.264, is video compression
            #   standard preferable to the once widely used MPEG-4.
            # > x264 (FFmpeg's libx264) is an open-source library for H.264.
            
            # FFmpeg - .avi
            # > FFmpeg (>v3.4) defaults: MPEG-4, YUV420p
            $progs{ffmpeg}{avi}{cmd_opts} = sprintf(
                "-y ".           # Overwrite existing files
                #----------------#
                "%s".            # Log level and banner switch; used for muting.
                " -i %s".        # A single GIF file generated by ImageMagick
                " -vcodec %s".   # Video encoder
                " -vf scale=%s". # Video resolution scaled for YUV420p
                " -pix_fmt %s".  # Chroma subsampling type
                " -b:v %s".      # Constant bitrate (-b:v == -vb)
                " %s",           # A single AVI output
                #----------------#
                $progs{ffmpeg}{mute_opt},
                $progs{imagemagick}{gif}{fname_full},
                $progs{ffmpeg}{avi}{vcodec},
                $progs{ffmpeg}{avi}{resolution},
                $progs{ffmpeg}{avi}{chroma},
                $progs{ffmpeg}{avi}{kbps},
                $progs{ffmpeg}{avi}{fname_full},
            );
            
            # FFmpeg - .mp4
            # > FFmpeg (>v3.4) defaults: H.264, YUV444p <= Change it to YUV420p!
            $progs{ffmpeg}{mp4}{cmd_opts} = sprintf(
                "-y ".
                #--------------------#
                "%s".                #
                " -i %s".            #
                " -vcodec %s".       #
                " -vf scale=%s".     #
                " -pix_fmt %s".      #
                " -crf %s".          # Constant rate factor
                " %s",               #
                #--------------------#
                $progs{ffmpeg}{mute_opt},
                $progs{imagemagick}{gif}{fname_full},
                $progs{ffmpeg}{mp4}{vcodec},
                $progs{ffmpeg}{mp4}{resolution},
                $progs{ffmpeg}{mp4}{chroma},
                $progs{ffmpeg}{mp4}{crf},
                $progs{ffmpeg}{mp4}{fname_full},
            );
            
            #
            # Run the executable and notify the file generations.
            #
            # As FFmpeg takes GIF inputs generated by ImageMagick,
            # ImageMagick must always be run before FFmpeg.
            #
            # Why make videos via ImageMagick-generated GIF files?
            # > FFmpeg can take a sequence of image streams by using
            #   the format specifier. (multiple use of the flag -i
            #   is also possible, but does not work for a stack of
            #   the images, even with stream mapping)
            #   Therefore, sequential raster images can be animated
            #   to many media formats, even including the GIF,
            #   for which I use ImageMagick.
            # > However, the FFmpeg syntax of input streams
            #   is "NOT friendly to phitar". This is because the sequence
            #   of filenames generated phitar is not purely numerical:
            #   w_rcc-vhgt0p10-frad1p00-fgap0p15-track-xz-001.png
            #   w_rcc-vhgt0p11-frad1p00-fgap0p15-track-xz-001.png
            #   w_rcc-vhgt0p12-frad1p00-fgap0p15-track-xz-001.png
            #   ...
            # > In this case we can still use an FFmpeg command like:
            #   -start_number 10 \
            #   -i w_rcc-vhgt0p%02d-frad1p00-fgap0p15-track-xz-001.png
            # > What if, however, the sequence involves a change
            #   in the integer part? that is:
            #   w_rcc-vhgt0p99-frad1p00-fgap0p15-track-xz-001.png
            #   w_rcc-vhgt1p00-frad1p00-fgap0p15-track-xz-001.png
            #   The format specifier 0p%02d will no longer recognize
            #   the sequence. A workaround can be to remove those 'p's
            #   from the filenames, animate them, and rename them again
            #   to restore the 'p's. Another workaround can be to generate
            #   different videos for different integers and concatenate them.
            #   Obviously, in either way the code will be less readable.
            # > The input syntax of ImageMagick, on the other hand,
            #   does not require the -i flag, and a stack of input streams
            #   can simply be recognized by multiple filenames separated by
            #   the space character. Therefore, as can be seen in the section
            #   '# ImageMagick - .gif' of '# Define the command-line options.'
            #   of this Moose class, I simply pass a series of filenames
            #   of raster images to the ImageMagick executable
            #   and obtain a GIF animation sequence.
            # > This ImageMagick-generated GIF image can simply be converted
            #   into video files by FFmpeg, now without a format specifier
            #   as we have only one input stream.
            #
            
            # ImageMagick - .gif
            # > Even if its switch has been turned off,
            #   ImageMagick is executed to provide FFmpeg with GIF images
            #   as its input streams.
            # > If ImageMagick is turned off while FFmpeg is on,
            #   the intermediary GIF is removed after the FFmpeg execution
            #   is over. (See the last lines of this routine.)
            system sprintf(
                "%s %s",
                $progs{imagemagick}{exe},
                $progs{imagemagick}{gif}{cmd_opts},
            );
            # Notify the GIF generation only when the ImageMagick
            # switch has been turned on.
            if ($self->Ctrls->gif_switch =~ /on/i) {
                printf(
                    "[%s] generated.\n",
                    $progs{imagemagick}{gif}{
                        $is_phitar ? 'fname' : 'fname_full'
                    },
                );
            }
            
            # FFmpeg - .avi
            if ($self->Ctrls->avi_switch =~ /on/i) {
                system sprintf(
                    "%s %s",
                    $progs{ffmpeg}{exe},
                    $progs{ffmpeg}{avi}{cmd_opts},
                );
                printf(
                    "[%s] generated. (%s,%s%s, %s, %g kbit\/s)\n",
                    $progs{ffmpeg}{avi}{
                        $is_phitar ? 'fname' : 'fname_full'
                    },
                    $progs{ffmpeg}{avi}{vcodec},
                    ($self->Ctrls->mp4_switch =~ /on/i ? '   ' : ' '),
                    $progs{ffmpeg}{avi}{chroma},
                    $resolutions{$the_resolution}{flag},
                    ($progs{ffmpeg}{avi}{kbps} / 1e3),
                );
            }
            
            # FFmpeg - .mp4
            if ($self->Ctrls->mp4_switch =~ /on/i) {
                my $_conv = '';
                if ($self->Ctrls->avi_switch =~ /on/i) {
                    $_conv = length(
                        sprintf(
                            "%g kbit\/s",
                            ($progs{ffmpeg}{avi}{kbps} / 1e3),
                        )
                    ) - length(
                        sprintf(
                            "CRF: %d",
                            $progs{ffmpeg}{mp4}{crf},
                        )
                    );
                }
                $_conv = '%'.$_conv.'s';
                system sprintf(
                    "%s %s",
                    $progs{ffmpeg}{exe},
                    $progs{ffmpeg}{mp4}{cmd_opts},
                );
                printf(
                    "[%s] generated. (%s, %s, %s, CRF: %d$_conv)\n",
                    $progs{ffmpeg}{mp4}{
                        $is_phitar ? 'fname' : 'fname_full'
                    },
                    $progs{ffmpeg}{mp4}{vcodec},
                    $progs{ffmpeg}{mp4}{chroma},
                    $resolutions{$the_resolution}{flag},
                    $progs{ffmpeg}{mp4}{crf},
                    ($self->Ctrls->avi_switch =~ /on/i ? ' ' : ''),
                );
            }
            
            # Remove the GIF image if its switch has been turned off.
            # (must be placed after the FFmpeg executions)
            if ($self->Ctrls->gif_switch =~ /off/i) {
                unlink $progs{imagemagick}{gif}{fname_full};
            }
        }
    }
    
    return;
}

__PACKAGE__->meta->make_immutable;
1;


package Animate::Cmt;

use Moose;
use namespace::autoclean;
with 'My::Moose::Cmt';

__PACKAGE__->meta->make_immutable;
1;


package Animate::Ctrls;

use Moose;
use namespace::autoclean;
with 'My::Moose::Ctrls';

# Additional animation options
my %_additional_anim_opts = (
    # (key) attribute, (val) default
    raster_format => 'png', # Raster format to be animated
    duration      => 5,     # Animation duration in second
);

has $_ => (
    is      => 'ro',
    isa     => 'Str|Num',
    lazy    => 1,
    default => $_additional_anim_opts{$_},
    writer  => 'set_'.$_,
) for keys %_additional_anim_opts;

# Additional switches
my %_additional_switches = (
    gif_switch => 'off',
    avi_switch => 'off',
    mp4_switch => 'off', 
);

has $_ => (
    is      => 'ro',
    isa     => 'My::Moose::Ctrls::OnOff',
    lazy    => 1,
    default => $_additional_switches{$_},
    writer  => 'set_'.$_,
) for keys %_additional_switches;

# .avi encoding options for MPEG-4 bitrate in kbit/s
has 'avi_kbps' => (
    is      => 'rw',
    isa     => 'Int',
    lazy    => 1,
    # Saturated at 1000 kbps under 4-kbps bitrate tolerance.
    # To see the video quality change wrto bitrate,
    # refer to the AVI files found in: \cs\graphics\ffmpeg\mpeg4_bitrate_comp\
    default => 1000 * 1e3, # == 1000 kbps, as the FFmpeg bitrate unit is bps.
);

sub set_avi_kbps {
    my $self = shift;
    
    if (defined $_[0] and $_[0] <= 0) {
        printf(
            "\nkbps [%s] less than or equal to zero; defaulting to [%s].\n",
            $_[0],
            1000,
        );
        # Do nothing.
    }
    
    elsif (defined $_[0] and $_[0] > 0) {
        $self->avi_kbps($_[0] * 1e3);
    }
    
    return;
}

# .mp4 encoding options for H.264 constant rate factor (CRF)
has 'mp4_crf' => (
    is      => 'rw',
    isa     => 'Int',
    lazy    => 1,
    # > Used for specifying the H.264 quality.
    # > 0 lossless, 51 worst. Choose one in 15--25.
    # > The degree to which the CRF affects the bitrate and thereby
    #   the size of the H.264 video depends largely on the pixel
    #   and file sizes of the original stream.
    # > Accordingly, in phitar, the CRF should be decreased
    #   if the raster DPI is increased.
    #   For ANGEL track files with xmesh=100, ymesh=100, zmesh=100,
    #   the pair of a DPI and a CRF I recommend is
    #   150:18, which have been set as the default values.
    #   This pair, however, may not be appropriate
    #   for ANGEL files with different mesh sizes.
    # > To see the video quality change wrto CRF,
    #   refer to the MP4 files found in: \cs\graphics\ffmpeg\h264_crf_comp\
    default => 18,
);

sub set_mp4_crf {
    my $self = shift;
    
    if (defined $_[0] and $_[0] <= 0) {
        printf(
            "\ncrf [%s] less than or equal to zero; defaulting to [%s].\n",
            $_[0],
            $self->mp4_crf,
        );
        # Do nothing.
    }
    
    elsif (defined $_[0] and $_[0] > 0) {
        $self->mp4_crf($_[0]);
    }
    
    return;
}

__PACKAGE__->meta->make_immutable;
1;


package Animate::FileIO;

use Moose;
use namespace::autoclean;
with 'My::Moose::FileIO';

# Basenames
my %_basenames = (
    # (key) attribute, (val) default
    seq_bname => '',
    ani_bname => '',
);
has $_ => (
    is      => 'ro',
    isa     => 'Str|RegexpRef',
    lazy    => 1,
    default => $_basenames{$_},
    writer  => 'set_'.$_,
) for keys %_basenames;

__PACKAGE__->meta->make_immutable;
1;