#!/usr/bin/env perl
# Patch third-person infantry camera blocks directly inside munged .lvl files.
#
# No munge toolchain needed. Munged ODF properties are stored as:
#
#     "PROP" [size:4 LE] [name_hash:4 LE] [value: NUL-terminated ASCII, 4-byte aligned]
#
# where name_hash is FNV-1a 32-bit over the lowercased property name (verified by munging
# com_inf_default.odf with the ModTools' OdfMunge.exe and matching the result against the
# shipped ingame.lvl, which stores the same bytes uncompressed).
#
# Because values are ASCII, a same-length edit needs no resizing: "10.0" -> "00.0" is a
# valid float and keeps every offset in the container intact. This script REFUSES any
# replacement of a different length rather than risk shifting the file.
#
# Usage: patch-camera.pl [options] <in.lvl> <out.lvl> <variant>
#
#   variants: recommended | centered-view | shoulder-view | clear | tilt0
#
#   options:  --shoulder <m> absolute lateral camera offset (negative = left; --right is
#                            an accepted older spelling of the same option)
#             --raise <m>    metres to lift the camera
#             --back  <m>    metres to pull the camera further back
#             --quiet        print only the summary line
#             --journal <f>  append every edit to <f> as TSV, so it can be reverted
#                            byte-exactly later (tools/revert-journal.pl)
#             --label <s>    name this file by <s> in the journal (default: in.lvl)
#             --check-variant <v>  validate a variant name and exit, touching no files
#             --include-jet  also patch jet troopers (skipped by default
#                            - see the entc/"_inf_"/"jet" check below)
#             --zoom-shoulder <m>  ZOOM's shoulder, relative to --shoulder's (not absolute)
#             --zoom-raise    <m>  ZOOM's lift, on top of --raise's - so "--raise 0.4
#                            --zoom-raise -0.1" lifts hip-fire 0.4 m and ZOOM 0.3 m
#
# An explicit option always overrides what the variant name asked for, so any preset can be
# nudged: "recommended --raise 0.5". Naming one also turns the camera move on for variants
# that would not otherwise do it, so "tilt0 --raise 0.3" is the aim fix plus a 30 cm lift
# and nothing else; whatever is not named stays as the unit authored it.
#
#   centered-view  center shoulder, a 0.175 m lift and 1.0 m further back - the aim fix plus
#                  just enough raise to clear the reticle, nothing else moved
#   shoulder-view  centered-view, shoulder pushed out to +0.6 m
#   recommended    centered-view, ZOOM's shoulder at +0.6 m while hip-fire stays centered
#   tilt0          zero every TiltValue, so bolts follow the reticle - the actual aim fix
#   clear          tilt0 plus a camera lift, leaving the authored x alone: the first fix for
#                  the model covering the reticle
#
# Every infantry class in the file is patched, not only com_inf_default. Side .lvl files
# store each unit's camera block fully resolved - inherited values included - so units that
# author their own sections (jedi, heroes) keep the stock tilt unless they are patched too.
# Jet troopers are skipped on purpose: see the entc/"_inf_"/"jet" check below.

use strict; use warnings;

sub fnv1a { my $s = lc(shift); my $h = 2166136261;
  for my $c (split //, $s) { $h ^= ord($c); $h = ($h * 16777619) & 0xFFFFFFFF; } $h }

my %H = map { pack("V", fnv1a($_)) => $_ }
  qw(CameraSection EyePointOffset TrackCenter TrackOffset TiltValue CameraBlendTime);

# The ready-made presets - see the header comment above for what each one is. back matches
# the framing matrix's old "-back" step (1.0 m), so distance is never left merely "as
# authored" unless the caller overrides it with --back.
my %RECOMMENDED = (
    'centered-view' => { shoulder => 0.0, lift => 0.175, back => 1.0 },
    'shoulder-view' => { shoulder => 0.6, lift => 0.175, back => 1.0 },
    recommended     => { shoulder => 0.0, lift => 0.175, back => 1.0, zoom_shoulder => 0.6 },
);

my ($LIFT, $SHOULDER, $BACK, $QUIET, $JOURNAL, $LABEL, $CHECK, $INCLUDE_JV,
    $ZOOM_SHOULDER, $ZOOM_RAISE)
  = (0.4, undef, 0.0, 0, undef, undef, undef, 0, 0, 0);

# A distance that is not a number used to be taken as zero: "--raise abc" reported
# "raise=abc" in its summary and moved nothing. Reject it at the boundary instead.
sub metres {
    my ($opt, $v) = @_;
    die "$opt needs a distance in metres, got '" . (defined $v ? $v : "") . "'\n"
      unless defined $v && $v =~ /^[+-]?(?:\d+\.?\d*|\.\d+)$/;
    return $v + 0;
}

my (%given, @pos);
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--raise')    { $LIFT = metres($a, shift @ARGV);     $given{raise} = 1 }
    elsif ($a eq '--shoulder') { $SHOULDER = metres($a, shift @ARGV); $given{shoulder} = 1 }
    elsif ($a eq '--right')    { $SHOULDER = metres($a, shift @ARGV); $given{shoulder} = 1 }  # older name
    elsif ($a eq '--back')     { $BACK = metres($a, shift @ARGV);     $given{back} = 1 }
    elsif ($a eq '--quiet')    { $QUIET = 1 }
    elsif ($a eq '--journal')  { $JOURNAL = shift @ARGV }
    elsif ($a eq '--label')    { $LABEL = shift @ARGV }
    elsif ($a eq '--check-variant') { $CHECK = shift @ARGV }
    elsif ($a eq '--include-jet') { $INCLUDE_JV = 1 }
    elsif ($a eq '--zoom-shoulder') { $ZOOM_SHOULDER = metres($a, shift @ARGV); $given{zoom_shoulder} = 1 }
    elsif ($a eq '--zoom-raise')    { $ZOOM_RAISE    = metres($a, shift @ARGV); $given{zoom_raise} = 1 }
    else { push @pos, $a }
}
my ($in, $out, $variant) = @pos;
# --check-variant <name> validates a name (and any overrides beside it) and exits, so a
# caller patching a whole install can reject a typo once up front rather than refusing
# every file in turn and still reporting a successful install.
$variant = $CHECK if defined $CHECK;
die "usage: $0 [--shoulder m] [--raise m] [--back m] [--quiet] [--include-jet]\n"
  . "       [--zoom-shoulder m] [--zoom-raise m] [--journal f] [--label s]\n"
  . "       <in.lvl> <out.lvl> <variant>\n"
  . "       $0 --check-variant <variant>\n"
  unless defined($CHECK) || ($in && $out && $variant);

# What the variant does, before any explicit option overrides it.
my ($do_tilt, $do_offset) = (0, 0);
if    ($variant eq 'tilt0') { $do_tilt = 1 }
elsif ($variant eq 'clear') { $do_tilt = 1; $do_offset = 1 }
elsif (exists $RECOMMENDED{$variant}) {
    my %p = %{ $RECOMMENDED{$variant} };
    ($do_tilt, $do_offset) = (1, 1);
    $SHOULDER      = $p{shoulder}                unless $given{shoulder};
    $LIFT          = $p{lift}                    unless $given{raise};
    $BACK          = $p{back}                    unless $given{back};
    $ZOOM_SHOULDER = $p{zoom_shoulder} // 0       unless $given{zoom_shoulder};
    $ZOOM_RAISE    = $p{zoom_raise}    // 0       unless $given{zoom_raise};
}
else {
    die "unknown variant '$variant'\n"
      . "  variants: " . join(" | ", sort keys %RECOMMENDED) . " | clear | tilt0\n";
}

# An explicit --raise/--shoulder/--back/--zoom-* means the caller wants the camera moved,
# whatever the variant asked for - which is what the help has always promised. Without
# this, "tilt0 --raise 0.3" zeroed the tilt and silently ignored the lift, because only
# 'clear' and the matrix turn the TrackOffset edit on.
if (!$do_offset && ($given{raise} || $given{shoulder} || $given{back}
                     || $given{zoom_shoulder} || $given{zoom_raise})) {
    $do_offset = 1;
    # Only what was named should move. 0.4 is 'clear's lift, not a neutral default, so a
    # bare "--shoulder -0.5" would otherwise raise the camera 40 cm as well.
    $LIFT = 0.0 unless $given{raise};
}

exit 0 if defined $CHECK;

# Zero while keeping the byte length: 10.0 -> 00.0, 7.5 -> 0.0, 10 -> 00, 5 -> 0.
sub zero_like {
    my $n = length shift;
    return "0" x $n if $n < 3;
    return ("0" x ($n - 3)) . "0.0";
}

# Rewrite a "x y z" camera offset to hit (x, y, z) while keeping the whole string's byte
# length, so the chunk never has to be resized. z is the gap between the soldier and the
# camera, so a larger z is further back.
#
# Three attempts, least invasive first. The byte budget is what makes this fiddly: a field
# holding "0.0" has three bytes, and "-0.5" needs four, so a left-shoulder offset cannot be
# written component-by-component - it has to borrow a byte from somewhere else in the string.
sub place_vector {
    my ($val, @t) = @_;
    my @c = split /\s+/, $val;
    return undef unless @c == 3;
    return in_place(\@c, \@t)
        // reflow(\@c, \@t, length($val))
        // squeeze(\@c, \@t, length($val));
}

# Render $v in exactly $want bytes. Tries every decimal count, then falls back to padding
# with leading zeros ("0.4" -> "00.4"), which the engine's float parsing reads unchanged.
# Returns undef only if $v cannot be expressed in $want bytes at all.
sub fixed_width {
    my ($v, $want) = @_;
    for my $d (reverse 0 .. ($want > 2 ? $want - 2 : 0)) {
        my $s = sprintf("%.*f", $d, $v);
        return $s if length($s) == $want;
    }
    for my $d (reverse 0 .. ($want > 2 ? $want - 2 : 0)) {
        my $s = sprintf("%.*f", $d, $v);
        next if length($s) > $want;
        my $pad = "0" x ($want - length($s));
        return $s =~ /^-/ ? "-" . $pad . substr($s, 1) : $pad . $s;
    }
    return undef;
}

# 1. Hold every component to its authored width. Keeps patched data reading like stock.
sub in_place {
    my ($c, $t) = @_;
    my @out;
    for my $i (0 .. 2) {
        if ($t->[$i] == $c->[$i]) { push @out, $c->[$i]; next }
        my $s = fixed_width($t->[$i], length($c->[$i]));
        return undef unless defined $s;
        # A field too narrow to hold the value would silently round the move away and leave
        # this section inconsistent with its neighbours. Refuse rather than drift.
        return undef if abs(($s + 0) - $t->[$i]) > 0.051;
        push @out, $s;
    }
    my $new = join(" ", @out);
    return length($new) == length(join(" ", @$c)) ? $new : undef;
}

# 2. Spend the whole string's budget instead of holding each component to its authored
# width. The small units author integer distances ("0.0 -0.5 5"), and one byte cannot hold
# 5.8 - but the string can, because "0" says as much as "0.0". Each component is rendered at
# the shortest length that is still exact, and the bytes left over become leading zeros.
sub reflow {
    my ($c, $t, $want) = @_;
    my @out;
    for my $i (0 .. 2) {
        my $s;
        for my $dec (0 .. 4) {
            $s = sprintf("%.*f", $dec, $t->[$i]);
            last if abs(($s + 0) - $t->[$i]) < 1e-9;
        }
        return undef if abs(($s + 0) - $t->[$i]) > 1e-9;
        push @out, $s;
    }
    return pad_to(\@out, $want, $t);
}

# 3. Give up precision, cheapest axis first. This is what makes a left shoulder reachable:
# "0.0 0.0 3.2" has no room for "-0.5 0.4 3.2", but "-0.5 0.4 3" fits, and 20 cm of camera
# distance is not something anyone can see. Lateral and vertical placement stay exact to
# 5 cm - those are the two the player is actually judging - while z may round by up to half
# a metre.
sub squeeze {
    my ($c, $t, $want) = @_;
    my ($best, $best_err);
    for my $dz (reverse 0 .. 2) {
        for my $dy (reverse 0 .. 2) {
            for my $dx (reverse 0 .. 2) {
                my @out = map { sprintf("%.*f", $_->[0], $_->[1]) }
                          ([$dx, $t->[0]], [$dy, $t->[1]], [$dz, $t->[2]]);
                my @err = map { abs(($out[$_] + 0) - $t->[$_]) } 0 .. 2;
                next if $err[0] > 0.051 || $err[1] > 0.051 || $err[2] > 0.51;
                my $padded = pad_to(\@out, $want, $t);
                next unless defined $padded;
                # Weight the axes the player can see far above camera distance.
                my $err = ($err[0] + $err[1]) * 100 + $err[2];
                ($best, $best_err) = ($padded, $err)
                    if !defined $best_err || $err < $best_err;
            }
        }
    }
    return $best;
}

# Pad a rendered triple out to exactly $want bytes. Spare bytes are spent on extra decimals
# first - "4" -> "4.0" says the same thing and reads like the stock data - starting from z,
# where they are cheapest. Anything still left over becomes leading zeros on the first
# component, which the engine's float parsing also reads unchanged ("-0.5" -> "-00.5").
sub pad_to {
    my ($out, $want, $t) = @_;
    my @o = @$out;
    my $spare = $want - length(join(" ", @o));
    return undef if $spare < 0;

    if ($spare && $t) {
        for my $i (2, 1, 0) {
            my $dec = $o[$i] =~ /\.(\d*)$/ ? length($1) : 0;
            while ($spare > 0 && $dec < 4) {
                my $cand = sprintf("%.*f", $dec + 1, $t->[$i]);
                my $grow = length($cand) - length($o[$i]);
                last if $grow <= 0 || $grow > $spare;
                # More decimals only ever move the rendering closer to the target.
                $o[$i] = $cand;
                $spare -= $grow;
                $dec++;
            }
        }
    }
    if ($spare) {
        my $pad = "0" x $spare;
        $o[0] = $o[0] =~ /^-/ ? "-" . $pad . substr($o[0], 1) : $pad . $o[0];
    }
    my $new = join(" ", @o);
    return length($new) == $want ? $new : undef;
}

my $jfh;
if (defined $JOURNAL) {
    open($jfh, ">>", $JOURNAL) or die "open $JOURNAL: $!";
    $LABEL = $in unless defined $LABEL;
}

local $/;
open(my $fh, "<:raw", $in) or die "open $in: $!";
my $d = <$fh>; close $fh;
printf "read  %s (%d bytes)\n", $in, length($d) unless $QUIET;

my ($classes, $sections, $patched, $skipped) = (0, 0, 0, 0);

# Walk the object containers rather than scanning the whole file: TrackOffset also appears
# on classes that have nothing to do with the infantry camera, and an unbounded search
# would corrupt them.
# Object containers are found with index() rather than by stepping a byte at a time: the
# live install has 200 MB+ side .lvl files and a per-byte loop over those takes minutes.
my @cand;
for my $t (qw(entc wpnc ordc expc)) {
    my $i = 0;
    while (($i = index($d, $t, $i)) >= 0) { push @cand, $i; $i++ }
}
@cand = sort { $a <=> $b } @cand;

my $done = 0;      # end of the last container actually parsed; skip candidates inside it
for my $i (@cand) {
    next if $i < $done || $i > length($d) - 8;
    my $tag = substr($d, $i, 4);
    my $esize = unpack("V", substr($d, $i + 4, 4));
    next if $esize < 8 || $esize > 1_000_000;
    my $end = $i + 8 + $esize;
    $end = length($d) if $end > length($d);

    # [BASE][TYPE][PROP...]
    my $j = $i + 8;
    my $type = "";
    while ($j < $end - 8) {
        my $t  = substr($d, $j, 4);
        my $sz = unpack("V", substr($d, $j + 4, 4));
        last if $sz < 1 || $sz > 65536;
        if ($t eq "TYPE") { ($type = substr($d, $j + 8, $sz)) =~ s/\0.*$//s }
        elsif ($t ne "BASE") { last }
        $j += 8 + (($sz + 3) & ~3);
        last if $type ne "";
    }

    # Entity classes follow <side>_<category>_<name> (com_inf_default, all_inf_rifleman):
    # "_inf_" is the on-foot soldier category, so anything else under entc - all_fly_*,
    # *_hover_*, *_walk_*, turrets - is a vehicle and its chase camera is left alone. Jet
    # troopers are "_inf_" too but get skipped by name regardless: their jetpack hover camera
    if (!$INCLUDE_JV && $tag eq 'entc' && ($type =~ /jet/i || $type !~ /_inf_/i)) {
        $done = $end;
        next;
    }

    my ($section, $hits, $header) = ("", 0, 0);
    my $k = $j;
    while ($k < $end - 12) {
        if (substr($d, $k, 4) ne "PROP") { $k++; next }
        my $sz = unpack("V", substr($d, $k + 4, 4));
        last if $sz < 4 || $sz > 65536;
        my $name = $H{ substr($d, $k + 8, 4) } // '';
        my $vpos = $k + 12;
        (my $val = substr($d, $vpos, $sz - 4)) =~ s/\0.*$//s;
        $k += 8 + (($sz + 3) & ~3);

        if ($name eq 'CameraSection') { $section = $val; $hits++; $sections++; next }
        next if $section eq '';

        my $new;
        if ($name eq 'TiltValue' && $do_tilt) {
            $new = zero_like($val);
        }
        elsif ($name eq 'TrackOffset' && $do_offset) {
            my $is_zoom = $section =~ /ZOOM$/;
            my @c = split /\s+/, $val;
            if (@c == 3) {
                # --zoom-shoulder/--zoom-raise are deltas on top of whatever shoulder/lift
                # this section would otherwise get, not absolute values of their own - "ZOOM
                # relative to non-ZOOM" is what lets "--shoulder 1 --zoom-shoulder -0.5" put
                # ZOOM at 0.5 without having to know what --shoulder resolved to.
                my $shoulder = defined $SHOULDER ? $SHOULDER + 0 : $c[0] + 0;
                $shoulder += $ZOOM_SHOULDER if $is_zoom;
                my $lift = $LIFT + ($is_zoom ? $ZOOM_RAISE : 0);
                # x is set (the shoulder), y and z are nudged from what the unit authored.
                my @target = ($shoulder, $c[1] + $lift, $c[2] + $BACK);
                $new = place_vector($val, @target);
                unless (defined $new) {
                    warn sprintf("  ! %s %s: cannot fit TrackOffset '%s' as (%s, %s, %s) in %d bytes\n",
                                 $type, $section, $val, @target, length($val));
                    $skipped++;
                }
            }
        }

        next unless defined $new && $new ne $val;
        die "refusing: '$val' -> '$new' changes length\n" if length($new) != length($val);
        substr($d, $vpos, length($new)) = $new;
        # The journal is what makes this reversible without keeping a 260 MB copy of every
        # file: offset, the bytes that were there, and the bytes written.
        printf $jfh "%s\t%d\t%s\t%s\t%s\t%s\t%s\n",
               $LABEL, $vpos, $val, $new, $type, $section, $name if $jfh;
        unless ($QUIET) {
            printf "\n%s\n", $type unless $header++;
            printf "  %-11s %-12s %-14s -> %s\n", $section, $name, $val, $new;
        }
        $patched++;
    }
    $classes++ if $hits;
    $done = $end;
}

close $jfh if $jfh;

open(my $o, ">:raw", $out) or die "open $out: $!";
print $o $d; close $o;
# This file is written to replace $in, so it has to carry $in's mode across. A fresh file
# takes whatever the umask says, which quietly re-permissioned every .lvl it patched.
if (defined(my $mode = (stat($in))[2])) { chmod($mode & 07777, $out) }
printf "%s: %d properties in %d sections across %d classes (variant=%s%s)%s\n",
       $out, $patched, $sections, $classes, $variant,
       ($do_offset ? sprintf(", shoulder=%s raise=%s back=%s%s",
                             defined $SHOULDER ? $SHOULDER : "as authored", $LIFT, $BACK,
                             ($ZOOM_SHOULDER || $ZOOM_RAISE)
                                 ? sprintf(" zoom-shoulder+=%s zoom-raise+=%s",
                                           $ZOOM_SHOULDER, $ZOOM_RAISE)
                                 : "")
                   : ""),
       ($skipped ? " - $skipped SKIPPED" : "");
