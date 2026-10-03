#!/usr/bin/env perl
# Print every .lvl file that contains a third-person camera block, with its section count.
#
#   find-camera-lvls.pl <dir|file.lvl> [...]        one line per hit: "<count>\t<path>"
#   find-camera-lvls.pl --paths <dir>               just the paths
#
# Which files hold camera blocks is not a fixed list. Stock keeps them in ingame.lvl and
# side/*.lvl, but a modded install moves them around: the 1.3 patch, BFX and the Remaster
# mod ship their own side/infantry.lvl, side/heroes.lvl, side/BFX/*.lvl and addon trees,
# each with fully resolved unit classes - so the installer has to look rather than assume.
#
# The test is a PROP chunk whose name hash is FNV-1a("camerasection"); that is a cheap
# index() scan, so sweeping a 20 GB install costs seconds rather than minutes.

use strict;
use warnings;
use File::Find;

my $PAT = pack("V", 0xbaca6bf1);     # fnv1a("camerasection")

my $paths_only = 0;
my @args;
for (@ARGV) { $_ eq '--paths' ? ($paths_only = 1) : push @args, $_ }
die "usage: $0 [--paths] <dir|file.lvl> [...]\n" unless @args;

my @files;
for my $a (@args) {
    if (-d $a) { find(sub { push @files, $File::Find::name if -f && /\.lvl$/i }, $a) }
    else       { push @files, $a }
}

for my $f (@files) {
    open(my $fh, "<:raw", $f) or next;
    local $/;
    my $d = <$fh>;
    close $fh;
    next unless defined $d;
    my ($n, $i) = (0, 0);
    while (($i = index($d, $PAT, $i)) >= 0) {
        $n++ if $i >= 8 && substr($d, $i - 8, 4) eq "PROP";
        $i++;
    }
    next unless $n;
    print $paths_only ? "$f\n" : "$n\t$f\n";
}
