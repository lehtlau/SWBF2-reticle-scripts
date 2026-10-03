#!/usr/bin/env perl
# Undo the edits recorded in a patch journal, byte for byte.
#
#   revert-journal.pl [--root <dir>] [--dry-run] <journal.tsv>
#
# tools/patch-camera.pl --journal writes one TSV line per edit:
#
#   label <TAB> offset <TAB> old <TAB> new <TAB> class <TAB> section <TAB> property
#
# Reverting reads the file, checks that the bytes at <offset> are still <new>, and puts
# <old> back. Old and new are always the same length, so nothing moves and no chunk size
# needs rewriting - the same property that makes the forward patch safe.
#
# This is why the installer does not keep a copy of every file it touches: the side .lvl
# files in a modded install run past 250 MB each, and a journal is a few kilobytes.
#
# A file whose bytes at an offset are neither <new> nor <old> has been replaced since it
# was patched (a mod install, or Steam's "verify integrity"). Those are reported and left
# alone - guessing would corrupt them.

use strict;
use warnings;
use File::Basename qw(dirname);

my ($root, $dry) = (undef, 0);
my @pos;
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--root')    { $root = shift @ARGV }
    elsif ($a eq '--dry-run') { $dry = 1 }
    else { push @pos, $a }
}
my $journal = $pos[0] or die "usage: $0 [--root dir] [--dry-run] <journal.tsv>\n";
my $root_given = defined $root;
$root = dirname($journal) unless defined $root;

open(my $jf, "<", $journal) or die "open $journal: $!";
my (%edits, @order);
while (my $l = <$jf>) {
    chomp $l;
    next if $l =~ /^\s*(#|$)/;
    my ($label, $off, $old, $new) = split /\t/, $l;
    next unless defined $new;
    push @order, $label unless exists $edits{$label};
    push @{ $edits{$label} }, [$off, $old, $new];
}
close $jf;

my ($files, $reverted, $already, $stale) = (0, 0, 0, 0);
for my $label (@order) {
    # A label is normally a path relative to the install root, so --root decides what it
    # means. Testing the bare label first let a matching relative path in the current
    # directory win, which could aim the revert at an install other than the one named.
    my $path = $label =~ m{^(?:/|[A-Za-z]:[\\/])} ? $label : "$root/$label";
    # Resolving against the current directory is only a fallback for a journal written by a
    # standalone patch run, where the label is whatever path was on that command line. An
    # explicit --root is the last word: a stale or mistyped one has to come up missing
    # rather than quietly revert some other tree that happens to sit under the cwd.
    $path = $label if !$root_given && !-f $path && -f $label;
    unless (-f $path) {
        printf "  ? %-28s missing - skipped\n", $label;
        $stale++;
        next;
    }
    local $/;
    open(my $fh, "<:raw", $path) or die "open $path: $!";
    my $d = <$fh>; close $fh;

    my ($n, $a, $s) = (0, 0, 0);
    for my $e (@{ $edits{$label} }) {
        my ($off, $old, $new) = @$e;
        my $have = substr($d, $off, length $new);
        if ($have eq $new)    { substr($d, $off, length $old) = $old; $n++ }
        elsif ($have eq $old) { $a++ }
        else                  { $s++ }
    }

    if ($n && !$dry) {
        my $tmp = "$path.revert.$$";
        my $mode = (stat($path))[2];
        open(my $o, ">:raw", $tmp) or die "open $tmp: $!";
        print $o $d; close $o;
        # Carry the original mode across: the replacement is a brand new file, so without
        # this a revert would hand the .lvl back with whatever the umask says.
        chmod($mode & 07777, $tmp) if defined $mode;
        # rename, never an in-place write: the playable instance hardlinks these files to
        # the reference tree, and writing through a shared inode would edit both.
        rename($tmp, $path) or die "rename $tmp -> $path: $!";
    }
    printf "  %s %-28s %d %s%s%s\n", ($s ? q{!} : q{-}), $label, $n,
           ($dry ? "still patched" : "reverted"),
           ($a ? ", $a already stock" : ""), ($s ? ", $s UNRECOGNISED (file replaced?)" : "");
    $files++; $reverted += $n; $already += $a; $stale += $s;
}

printf "%s %d file(s), %d edit(s)%s, %d already stock%s\n",
       ($dry ? "would revert:" : "reverted:"), $files, $reverted,
       ($dry ? " still in place" : " reverted"), $already,
       ($stale ? ", $stale unrecognised" : "");
exit($stale ? 2 : 0);
