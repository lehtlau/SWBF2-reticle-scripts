#!/usr/bin/env bash
# Resolve which installation the tools act on. Sourced, not executed.
#
# The real Steam install comes first in the list, because that is the install being played
# and the one a patch is meant to land in. Any other tree - a GOG or retail copy, or a
# scratch copy kept for testing - is only ever the target when SWBF_GAME names it outright.
# Guessing at one of those by default meant the game that was actually launched stayed
# unpatched.
#
# SWBF_GAME is the install ROOT, with GameData under it, so one value has the same shape
# for Steam, GOG and retail.

# Prints the install root, or returns 1 with nothing on stdout.
swbf_resolve_game() {
    local c
    if [ -n "${SWBF_GAME:-}" ]; then
        printf '%s\n' "${SWBF_GAME%/}"
        return 0
    fi
    for c in \
        "$HOME/.local/share/Steam/steamapps/common/Star Wars Battlefront II Classic" \
        "$HOME/.steam/steam/steamapps/common/Star Wars Battlefront II Classic" \
        "$HOME/Games/Star Wars Battlefront II Classic" \
        "/c/Program Files (x86)/Steam/steamapps/common/Star Wars Battlefront II Classic"; do
        # ingame.lvl, not just the directory: a GameData left behind by an uninstall or a
        # half-built instance is not something to silently patch.
        [ -f "$c/GameData/data/_lvl_pc/ingame.lvl" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# Same, but reports the failure. Callers run it as GAME="$(swbf_require_game)" || exit 1:
# the exit status crosses the command substitution, an exit inside one would not.
swbf_require_game() {
    swbf_resolve_game && return 0
    echo "error: no game install found; set SWBF_GAME=/path/to/install-root" >&2
    return 1
}
