#!/usr/bin/env perl
# Survey every third-person camera block in a munged .lvl, grouped by the class that owns it.
#
# Side .lvl files do NOT store overrides — each unit class carries a fully resolved copy of
# its camera block, inherited values included. So patching com_inf_default inside ingame.lvl
# leaves every unit in every side/*.lvl still carrying the stock TiltValue. This tool shows
# who carries what, which is how the jet trooper's sprint-blend jolt was found: its own
# STAND/CROUCH sections kept tilt 7.5 while the SPRINT section it inherits had been zeroed,
# so tapping sprint blended between two differently-pitched cameras.
#
# Usage:
#   lvl-cameras.pl <file.lvl> [...]              list classes with camera sections
#   lvl-cameras.pl --nonzero <file.lvl> [...]    only classes with a non-zero TiltValue
#   lvl-cameras.pl --terse   <file.lvl> [...]    one line per class
#   lvl-cameras.pl --include-jet <file.lvl> [...]  also count jet troopers
#
# The flags combine: --terse --nonzero is one line per class still carrying a tilt, which
# is what tools/install-to-game.sh --status counts. Jet troopers are excluded
# from that count by default because tools/patch-camera.pl skips them by default too - pass
# --include-jet here if (and only if) the install being checked used that flag as well,
# otherwise units that were never meant to be patched count as a failed install.

use strict;
use warnings;

sub fnv1a { my $s = lc(shift); my $h = 2166136261;
  for my $c (split //, $s) { $h ^= ord($c); $h = ($h * 16777619) & 0xFFFFFFFF } $h }

my %H = map { pack("V", fnv1a($_)) => $_ }
  qw(CameraSection EyePointOffset TrackCenter TrackOffset TiltValue CameraBlendTime);

my ($only_nonzero, $terse, $include_jv) = (0, 0, 0);
my @files;
for (@ARGV) {
    if    ($_ eq '--nonzero')     { $only_nonzero = 1 }
    elsif ($_ eq '--terse')       { $terse = 1 }
    elsif ($_ eq '--include-jet') { $include_jv = 1 }
    else                          { push @files, $_ }
}
die "usage: $0 [--nonzero] [--terse] [--include-jet] <file.lvl> [...]\n" unless @files;

my $grand = 0;
for my $file (@files) {
    local $/;
    open(my $fh, "<:raw", $file) or die "open $file: $!";
    my $d = <$fh>; close $fh;

    my @classes;
    # Object containers are found with index() rather than by stepping a byte at a time:
    # the live install has 200 MB+ side .lvl files and a per-byte loop over those is slow.
    my @cand;
    for my $t (qw(entc wpnc ordc expc)) {
        my $j = 0;
        while (($j = index($d, $t, $j)) >= 0) { push @cand, $j; $j++ }
    }
    @cand = sort { $a <=> $b } @cand;

    my $done = 0;
    for my $i (@cand) {
        next if $i < $done || $i > length($d) - 8;
        my $tag = substr($d, $i, 4);
        my $esize = unpack("V", substr($d, $i + 4, 4));
        next if $esize < 8 || $esize > 1_000_000;
        my $end = $i + 8 + $esize;
        # A truncated .lvl (an interrupted download, a half-written mod install) can claim
        # a container that runs past the end of the file. Clamp, as patch-camera.pl does,
        # rather than walking off the buffer: --status discards this script's stderr, so
        # the substr warnings that followed were invisible and the class count came up short.
        $end = length($d) if $end > length($d);

        # [BASE][TYPE][PROP...]
        my $j = $i + 8;
        my ($base, $type) = ("", "");
        while ($j < $end - 8) {
            my $t  = substr($d, $j, 4);
            my $sz = unpack("V", substr($d, $j + 4, 4));
            last if $sz < 1 || $sz > 65536;
            if    ($t eq "BASE") { ($base = substr($d, $j + 8, $sz)) =~ s/\0.*$//s }
            elsif ($t eq "TYPE") { ($type = substr($d, $j + 8, $sz)) =~ s/\0.*$//s }
            else { last }
            $j += 8 + (($sz + 3) & ~3);
            last if $type ne "";
        }

        # Same rule as tools/patch-camera.pl: anything under entc that is not "_inf_", plus
        # anything with "jet" in the name regardless, is a vehicle or jet trooper and was
        # never patched by default - so it should not count as "still needs patching" either.
        # $done has to move past this container here too, same as patch-camera.pl - skipping
        # without it would let the next candidate index land inside these bytes and be
        # misread as a fresh container.
        if (!$include_jv && $tag eq 'entc' && ($type =~ /jet/i || $type !~ /_inf_/i)) {
            $done = $end;
            next;
        }

        my (@sections, $cur);
        my $k = $j;
        while ($k < $end - 12) {
            if (substr($d, $k, 4) ne "PROP") { $k++; next }
            my $sz = unpack("V", substr($d, $k + 4, 4));
            last if $sz < 4 || $sz > 65536;
            my $name = $H{ substr($d, $k + 8, 4) };
            (my $val = substr($d, $k + 12, $sz - 4)) =~ s/\0.*$//s;
            if (defined $name) {
                if ($name eq 'CameraSection') {
                    push @sections, ($cur = { name => $val, at => $k });
                } elsif ($cur) {
                    $cur->{$name} = $val;
                }
            }
            $k += 8 + (($sz + 3) & ~3);
        }
        push @classes, { type => $type, base => $base, at => $i, sections => \@sections }
            if @sections;
        $done = $end;
    }

    for my $c (@classes) {
        my @tilts = grep { defined } map { $_->{TiltValue} } @{ $c->{sections} };
        my $nonzero = grep { $_ + 0 != 0 } @tilts;
        next if $only_nonzero && !$nonzero;
        $grand++;
        if ($terse) {
            printf "%-14s %-34s %s\n", "$file:", $c->{type},
                   join(" ", map { ($_->{name} // '?') . "=" . ($_->{TiltValue} // '-') }
                             @{ $c->{sections} });
            next;
        }
        printf "\n%s  %s  (base %s, at %d)%s\n", $file, $c->{type}, $c->{base}, $c->{at},
               $nonzero ? "  << non-zero tilt" : "";
        for my $s (@{ $c->{sections} }) {
            printf "    %-11s tilt %-5s center %-14s offset %-14s blend %s\n",
                   $s->{name}, $s->{TiltValue} // '-', $s->{TrackCenter} // '-',
                   $s->{TrackOffset} // '-', $s->{CameraBlendTime} // '-';
        }
    }
}
printf "\n# %d class(es)%s\n", $grand, $only_nonzero ? " with non-zero tilt" : " with camera sections";
