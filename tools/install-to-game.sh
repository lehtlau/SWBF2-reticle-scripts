#!/usr/bin/env bash
# Install the reticle fix into a real game installation (Steam, GOG, retail), including
# modded ones.
#
#   tools/install-to-game.sh                        no arguments: asks for the variant
#   tools/install-to-game.sh --variant recommended  the ready-made preset (see VARIANTS)
#   tools/install-to-game.sh --list                 show the variants
#   tools/install-to-game.sh --variant tilt0        no camera lift, only zero the tilt
#   tools/install-to-game.sh --raise 0.3            override the lift of any variant
#   tools/install-to-game.sh --shoulder -0.6        override the lateral offset
#   tools/install-to-game.sh --back 0.8             override the pull-back
#   tools/install-to-game.sh --include-jet          also patch jet troopers
#   tools/install-to-game.sh --zoom-shoulder -0.5   ZOOM's shoulder, relative to --shoulder's
#   tools/install-to-game.sh --zoom-raise -0.3      ZOOM's lift, on top of --raise's
#   tools/install-to-game.sh --game /path/GameData
#   tools/install-to-game.sh --status               what is installed right now
#   tools/install-to-game.sh --restore              put the original values back
#   tools/install-to-game.sh --dry-run              list what would be patched
#   tools/install-to-game.sh --help                 print this header
#
# Which install is acted on comes from tools/game-path.sh, or from --game / $SWBF_GAME.
# Pass any flag (even just --variant clear) to install straight away without the prompts;
# the prompts only run when the script is invoked with no arguments at all, from a terminal.
#
# VARIANTS
#
#   recommended    centered-view, ZOOM's shoulder at +0.6 m while hip-fire stays centered -
#                  the ready-made starting point
#   centered-view  center shoulder, a 0.175 m lift, 1.0 m further back
#   shoulder-view  centered-view, shoulder pushed out to +0.6 m
#   clear          lift 0.4 m, lateral offsets left as authored
#   tilt0          the aim fix alone, no framing change
#
# recommended/centered-view/shoulder-view are just --shoulder/--raise/--back/--zoom-shoulder
# fixed to specific numbers (including a 1.0 m pull-back, so distance is never left merely
# "as authored"), so they take the same overrides as everything else - combine any variant
# with --raise/--shoulder/--back/--zoom-shoulder/--zoom-raise to build your own numbers from
# it.
#
# WHAT IT TOUCHES
#
# Every .lvl in the install that carries a third-person camera block - not just
# ingame.lvl. Side .lvl files store each unit's camera fully resolved, inherited values
# included, so com_inf_default alone does not reach the jedi, the heroes, or anything a mod
# ships.
# Patching only some of the rest leaves units whose postures blend between a tilted and an
# untilted camera, which reads as a lurch when sprint is tapped.
#
# Properties are located by FNV-1a name hash, never by byte offset, and every replacement
# is the same byte length as the value it replaces, so no chunk is ever resized. A file
# whose camera block does not parse is left untouched rather than half-written.
#
# REVERTING
#
# Each edit is journalled (offset, old bytes, new bytes) under
# $GAMEDATA/.swbf-reticle-fix/, and --restore puts the old bytes back byte for byte. That
# is why no copies are kept: a modded install's side files run past 250 MB each.
#
# Steam's "Verify integrity of game files" replaces .lvl files and silently undoes the fix;
# re-run the installer afterwards. Installing another mod over the top does the same to
# whichever files it replaces - --status will show them as stock again.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/tools/game-path.sh"
VARIANT="clear"
GAMEDATA=""
ACTION="install"
# Overrides are passed through only when given, so each variant keeps its own numbers:
# patch-camera.pl owns the variant list and this script does not duplicate it.
OVERRIDE=()
# Zero arguments is what a first-time run looks like, so that is the one case asked about
# before anything is installed - any explicit flag (even a redundant "--variant clear") is
# taken as already having decided, and skips straight to installing.
NOARGS=0
[ $# -eq 0 ] && NOARGS=1

while [ $# -gt 0 ]; do
    case "$1" in
        --variant)  VARIANT="${2:?}"; shift 2 ;;
        --raise)    OVERRIDE+=(--raise "${2:?}"); shift 2 ;;
        --shoulder) OVERRIDE+=(--shoulder "${2:?}"); shift 2 ;;
        --right)    OVERRIDE+=(--shoulder "${2:?}"); shift 2 ;;   # older name
        --up)    OVERRIDE+=(--raise "${2:?}"); shift 2 ;;
        --back)     OVERRIDE+=(--back "${2:?}"); shift 2 ;;
        --include-jet) OVERRIDE+=(--include-jet); shift ;;
        --zoom-shoulder) OVERRIDE+=(--zoom-shoulder "${2:?}"); shift 2 ;;
        --zoom-raise)    OVERRIDE+=(--zoom-raise "${2:?}"); shift 2 ;;
        --game)     GAMEDATA="${2:?}"; shift 2 ;;
        --restore)  ACTION="restore"; shift ;;
        --status)   ACTION="status"; shift ;;
        --dry-run)  ACTION="dryrun"; shift ;;
        --list)     ACTION="list"; shift ;;
        # The header down to the first blank line IS the help text, so editing one cannot
        # leave the other behind - a fixed line range did exactly that.
        -h|--help)  sed -n '2,/^$/p' "$0" | sed 's/^#\( \|$\)//'; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

# No arguments at all: ask rather than silently installing 'clear' on whatever install
# tools/game-path.sh finds first. Only when it is a terminal - a non-interactive caller
# with no arguments (a script, a CI job) gets the old no-prompt default instead of a `read`
# that would block forever.
if [ "$NOARGS" = 1 ] && [ "$ACTION" = install ] && [ -t 0 ]; then
    echo "No arguments given - nothing will be installed until these are answered."
    echo "(pass any flag, e.g. --variant clear, to skip straight to installing; --help for all of them)"
    echo
    echo "variants: recommended | centered-view | shoulder-view  (ready-made presets)"
    echo "          clear | tilt0  (build your own)"
    echo "          (tools/install-to-game.sh --list shows all of them)"
    read -rp "variant to install [recommended]: " ans
    VARIANT="${ans:-recommended}"
    perl "$REPO/tools/patch-camera.pl" --check-variant "$VARIANT" || exit 1
    echo
fi

if [ "$ACTION" = list ]; then
    printf '%-20s %9s %8s %s\n' variant shoulder lift "camera distance"
    echo "---------------------------------------------------------"
    printf '%-20s %7s m %6s m %s\n' recommended   "0.0" "+0.175" "+1.0 m (ZOOM shoulder +0.6)"
    printf '%-20s %7s m %6s m %s\n' centered-view "0.0" "+0.175" "+1.0 m"
    printf '%-20s %7s m %6s m %s\n' shoulder-view "+0.6" "+0.175" "+1.0 m"
    echo
    echo "combine any variant with --raise/--shoulder/--back/--zoom-shoulder/--zoom-raise to build your own numbers:"
    printf '%-20s %7s   %6s m %s\n' clear "authored" "+0.40" "as authored"
    printf '%-20s %7s   %6s   %s\n' tilt0 "authored" "none"  "as authored  (aim fix only)"
    exit 0
fi

# Reject a bad variant or a non-numeric override here, before anything is scanned or
# written. patch-camera.pl owns the variant list, so it is what gets to rule on the name -
# this script still does not duplicate it. Without the check, a typo refused all 34 files
# one by one and the run then recorded a successful install of nothing.
if [ "$ACTION" = install ]; then
    perl "$REPO/tools/patch-camera.pl" --check-variant "$VARIANT" \
        "${OVERRIDE[@]+${OVERRIDE[@]}}" || exit 1
fi

# Auto-detect: tools/game-path.sh owns the candidate list, so every tool in the repo agrees
# on which install is "the" install. SWBF_GAME overrides it.
if [ -z "$GAMEDATA" ]; then
    if root="$(swbf_resolve_game)"; then GAMEDATA="$root/GameData"; fi
fi
[ -n "$GAMEDATA" ] || { echo "error: no game found; pass --game /path/to/GameData" >&2; exit 1; }
[ -f "$GAMEDATA/data/_lvl_pc/ingame.lvl" ] || {
    echo "error: $GAMEDATA does not look like a GameData directory" >&2; exit 1; }

STATE="$GAMEDATA/.swbf-reticle-fix"
JOURNAL="$STATE/journal.tsv"
INSTALLED="$STATE/installed"

echo "game: $GAMEDATA"

# --- status ---------------------------------------------------------------------------
if [ "$ACTION" = status ]; then
    # lvl-cameras.pl excludes jet troopers from its count by default, same as
    # patch-camera.pl excludes them from patching - so the count below has to make the same
    # exception this install actually made, or units that were never meant to be touched
    # show up looking like a failed install.
    STATUS_FLAGS=()
    if [ -f "$INSTALLED" ] && grep -q -- '--include-jet' "$INSTALLED"; then
        STATUS_FLAGS=(--include-jet)
    fi
    if [ -f "$INSTALLED" ]; then
        echo
        cat "$INSTALLED"
        echo
        # The journal is the only record of what was changed, so say so plainly when it has
        # gone rather than reporting "0 edit(s)" and letting the reverter die on the open.
        if [ -f "$JOURNAL" ]; then
            echo "journal: $(grep -c . "$JOURNAL") edit(s), $JOURNAL"
            echo "checking the files are still as the journal left them..."
            perl "$REPO/tools/revert-journal.pl" --root "$GAMEDATA" --dry-run "$JOURNAL" || true
        else
            echo "journal: MISSING ($JOURNAL) - --restore cannot undo this install"
        fi
    else
        echo "not installed (no $INSTALLED)"
    fi
    # Collect the paths before counting. Feeding one xargs straight into the next loses the
    # difference between "scanned everything, nothing left" and "scanned nothing": with no
    # paths to hand on, perl got no file arguments, printed its usage and exited 255, which
    # aborts xargs - and the empty output that followed counted as a reassuring zero.
    mapfile -t SCAN < <(find "$GAMEDATA" -iname '*.lvl' -size +4k -print0 \
        | xargs -0 -r -P 8 -n 12 perl "$REPO/tools/find-camera-lvls.pl" --paths)
    if [ "${#SCAN[@]}" -eq 0 ]; then
        echo "error: no .lvl with a camera block found under $GAMEDATA" >&2
        exit 1
    fi
    left=$(printf '%s\n' "${SCAN[@]}" \
             | xargs -d'\n' -r perl "$REPO/tools/lvl-cameras.pl" --terse --nonzero \
                 "${STATUS_FLAGS[@]+${STATUS_FLAGS[@]}}" 2>/dev/null \
             | grep -c ':' || true)
    echo "scanned ${#SCAN[@]} file(s) with camera blocks"
    echo "classes still carrying a non-zero TiltValue: $left"
    exit 0
fi

# --- restore -------------------------------------------------------------------------
if [ "$ACTION" = restore ]; then
    [ -f "$JOURNAL" ] || { echo "error: nothing to restore (no $JOURNAL)" >&2; exit 1; }
    rc=0
    perl "$REPO/tools/revert-journal.pl" --root "$GAMEDATA" "$JOURNAL" || rc=$?
    # 0 = every edit put back. 2 = some files no longer hold the bytes we wrote, because a
    # mod or Steam replaced them; the reverter names those and there is nothing more to do
    # for them. Anything else is an I/O failure partway through, and then the journal is
    # the only record of what is still patched: keep it, keep the marker, and fail. This
    # used to swallow every status and print "restored." over a revert that wrote nothing.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
        echo "error: revert failed (exit $rc); nothing retired, re-run --restore once the" >&2
        echo "       cause is fixed - the journal is still $JOURNAL" >&2
        exit "$rc"
    fi
    mv -f "$JOURNAL" "$JOURNAL.reverted"
    rm -f "$INSTALLED"
    [ "$rc" -eq 2 ] && echo "restored, except the unrecognised files listed above."
    [ "$rc" -eq 0 ] && echo "restored."
    echo "(the spent journal is kept as $JOURNAL.reverted)"
    exit 0
fi

# --- find the files ------------------------------------------------------------------
echo "scanning for camera blocks..."
mapfile -t FILES < <(find "$GAMEDATA" -iname '*.lvl' -size +4k -print0 \
    | xargs -0 -r -P 8 -n 12 perl "$REPO/tools/find-camera-lvls.pl" --paths | sort)
[ "${#FILES[@]}" -gt 0 ] || { echo "error: no .lvl with a camera block found" >&2; exit 1; }
echo "found ${#FILES[@]} file(s) with camera blocks"

if [ "$ACTION" = dryrun ]; then
    for f in "${FILES[@]}"; do
        printf '  %s\n' "${f#"$GAMEDATA/"}"
    done
    echo "(dry run: nothing written)"
    exit 0
fi

# --- revert any earlier install first -------------------------------------------------
# The camera lift is a delta on the authored offset, so applying it twice would lift twice.
# Always patch from the values the game shipped with.
mkdir -p "$STATE"
if [ -f "$JOURNAL" ]; then
    echo "reverting the previous install first..."
    rc=0
    perl "$REPO/tools/revert-journal.pl" --root "$GAMEDATA" "$JOURNAL" || rc=$?
    # 2 is fine: those files were replaced since they were patched, so they carry somebody
    # else's authored values now and will be patched fresh from those. Any other failure
    # means files are still holding OUR values, and patching those again would apply the
    # lift twice - exactly what this step exists to prevent. Stop instead.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
        echo "error: could not revert the previous install (exit $rc)." >&2
        echo "       patching on top of it would apply the camera lift twice; aborting." >&2
        exit "$rc"
    fi
    mv -f "$JOURNAL" "$JOURNAL.previous"
fi

# --- patch ---------------------------------------------------------------------------
tmpj="$STATE/journal.partial"
: > "$tmpj"
patched_files=0
patched_props=0
skipped_props=0
current_tmp=""      # the temp of the file being patched right now, "" between files
before=0            # journal line count when that file started

# Drop the journal lines this file added. An edit recorded for a file that is then thrown
# away is an edit that never happened, and it would show up in --status's journal count and
# as a phantom "already stock" entry on every later revert.
rewind_journal() {
    head -n "$1" "$tmpj" > "$tmpj.rewind" && mv -f "$tmpj.rewind" "$tmpj"
}

# A run that is killed has really patched the files it got to, so the journal has to survive
# the interrupt. Without this the edits stayed in journal.partial, which nothing reads:
# --status said "not installed" and --restore refused, over a half-patched install.
rescue_journal() {
    local rc=$?
    trap - INT TERM HUP EXIT
    # The patcher records its edits as it goes, but the file only becomes real at the mv.
    # A file still in flight was never installed, so drop its temp and its journal lines
    # together - otherwise the rescued journal overstates what was written and every later
    # revert reports those edits as "already stock".
    if [ -n "$current_tmp" ]; then
        rm -f "$current_tmp"
        rewind_journal "$before"
    fi
    [ -f "$tmpj" ] || exit "$rc"
    if [ -s "$tmpj" ]; then
        mv -f "$tmpj" "$JOURNAL"
        cat > "$INSTALLED" <<EOF
variant:   $VARIANT
state:     INTERRUPTED - a partial install, revert it before patching again
edits:     $(grep -c . "$JOURNAL")
installed: $(date -Iseconds)
by:        $REPO/tools/install-to-game.sh
EOF
        echo >&2
        echo "interrupted after $(grep -c . "$JOURNAL") edit(s), all of them journalled." >&2
        echo "  undo them with: tools/install-to-game.sh --restore" >&2
    else
        rm -f "$tmpj"
    fi
    exit "$rc"
}
trap rescue_journal INT TERM HUP EXIT

for f in "${FILES[@]}"; do
    rel="${f#"$GAMEDATA/"}"
    tmp="$f.swbf-fix.$$"
    current_tmp="$tmp"
    before=$(wc -l < "$tmpj")
    if ! out=$(perl "$REPO/tools/patch-camera.pl" --quiet "${OVERRIDE[@]+${OVERRIDE[@]}}" \
                 --journal "$tmpj" --label "$rel" "$f" "$tmp" "$VARIANT" 2>&1); then
        rm -f "$tmp"
        # The patcher journals as it goes and can die after recording some edits - on a
        # failed write of its output, say - so the journal has to be wound back too.
        rewind_journal "$before"
        echo "  ! $rel: patcher refused, left untouched"
        printf '%s\n' "$out" | sed 's/^/      /'
        continue
    fi
    n=$(printf '%s\n' "$out" | sed -n 's/.*: \([0-9]*\) properties.*/\1/p' | head -1)
    n="${n:-0}"
    if [ "$n" -eq 0 ]; then
        rm -f "$tmp"
        rewind_journal "$before"
        continue
    fi
    # Same length in, same length out - a size change means the patcher misparsed.
    if [ "$(stat -c%s "$f")" != "$(stat -c%s "$tmp")" ]; then
        rm -f "$tmp"
        rewind_journal "$before"
        echo "  ! $rel: size changed, discarded"
        continue
    fi
    # An edit that was not journalled is an edit that cannot be reverted, so insist the two
    # counts agree rather than installing something only partly undoable.
    journalled=$(( $(wc -l < "$tmpj") - before ))
    if [ "$journalled" -ne "$n" ]; then
        rm -f "$tmp"
        rewind_journal "$before"
        echo "  ! $rel: $n edits but $journalled journalled, discarded"
        continue
    fi
    # rename, never an in-place write: the playable test instance hardlinks these files to
    # the reference tree, and writing through a shared inode would edit the reference too.
    mv -f "$tmp" "$f"
    current_tmp=""
    patched_files=$((patched_files + 1))
    patched_props=$((patched_props + n))
    # A section the patcher could not fit keeps its authored offset, so that unit's postures
    # no longer agree with each other. Rare (a left shoulder needs a byte for the minus sign
    # that a few authored offsets do not have) but never silent.
    s=$(printf '%s\n' "$out" | sed -n 's/.*- \([0-9]*\) SKIPPED.*/\1/p' | head -1)
    skipped_props=$((skipped_props + ${s:-0}))
    if [ -n "${s:-}" ]; then
        printf '  %-44s %3d properties, %s section(s) would not fit\n' "$rel" "$n" "$s"
        printf '%s\n' "$out" | sed -n 's/^  ! /      /p'
    else
        printf '  %-44s %3d properties\n' "$rel" "$n"
    fi
done
current_tmp=""

# A run that changed nothing is not an install: writing the marker and an empty journal
# would have --status report a fix that is not in the files - which is what happens when
# every section was refused.
if [ "$patched_files" -eq 0 ]; then
    trap - INT TERM HUP EXIT
    rm -f "$tmpj"
    echo
    echo "nothing was patched (variant=$VARIANT); no install recorded" >&2
    exit 1
fi

mv -f "$tmpj" "$JOURNAL"
trap - INT TERM HUP EXIT

cat > "$INSTALLED" <<EOF
variant:   $VARIANT
overrides: ${OVERRIDE[*]+${OVERRIDE[*]}}
files:     $patched_files
edits:     $patched_props
unfitted:  $skipped_props
installed: $(date -Iseconds)
by:        $REPO/tools/install-to-game.sh
EOF

echo
echo "installed: $VARIANT ${OVERRIDE[*]+${OVERRIDE[*]}}"
echo "  $patched_files file(s), $patched_props property values"
[ "$skipped_props" -gt 0 ] && \
  echo "  $skipped_props section(s) kept their authored offset - no room for the value in the file"
echo "  revert:  tools/install-to-game.sh --restore"
echo "  status:  tools/install-to-game.sh --status"
