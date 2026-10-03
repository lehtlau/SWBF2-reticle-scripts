# SWBF2 reticle fix

A set of scripts for patching the player camera and reticle in Star Wars Battlefront II
(2005).

By default, the player's bolts can overshoot the reticle. These scripts remove the
problematic tilt value from the player camera and provide a set of ready-made camera
options, as well as utilities for creating your own.

## Example usage

Install the reticle fix into a real game installation (Steam, GOG, retail), including
modded ones.

```
bash tools/install-to-game.sh
bash tools/install-to-game.sh --raise +0.3 --shoulder 0 --zoom-shoulder +0.6 --back 1
```
```
tools/install-to-game.sh                        no arguments: asks for the variant
tools/install-to-game.sh --variant recommended  the ready-made preset (see Variants)
tools/install-to-game.sh --list                 show the variants
tools/install-to-game.sh --variant tilt0        no camera lift, only zero the tilt
tools/install-to-game.sh --raise 0.3            override the lift of any variant
tools/install-to-game.sh --shoulder -0.6        override the lateral offset
tools/install-to-game.sh --back 0.8             override the pull-back
tools/install-to-game.sh --include-jet          also patch jet troopers
tools/install-to-game.sh --zoom-shoulder -0.5   ZOOM's shoulder, relative to --shoulder's
tools/install-to-game.sh --zoom-raise -0.3      ZOOM's lift, on top of --raise's
tools/install-to-game.sh --game /path/GameData
tools/install-to-game.sh --status               what is installed right now
tools/install-to-game.sh --restore              put the original values back
tools/install-to-game.sh --dry-run              list what would be patched
tools/install-to-game.sh --help                 print the usage header
```

Which install is acted on comes from `tools/game-path.sh`, or from `--game` or `$SWBF_GAME`.

## Variants

```
recommended    centered-view, ZOOM's shoulder at +0.6 m while hip-fire stays centered -
               the ready-made starting point
centered-view  center shoulder, a 0.175 m lift, 1.0 m further back
shoulder-view  centered-view, shoulder pushed out to +0.6 m
clear          lift 0.4 m, lateral offsets left as authored
tilt0          the aim fix alone, no framing change
```

`recommended`/`centered-view`/`shoulder-view` are just `--shoulder`/`--raise`/`--back`/
`--zoom-shoulder` fixed to specific numbers.
`--raise`, `--shoulder` and `--back` override whatever the variant asked for, and naming one
turns the camera move on even for a variant that would not otherwise do it: `--variant tilt0
--raise 0.3` is the aim fix plus a 30 cm lift and nothing else. Anything you do not name
stays as the unit authored it.

`--zoom-shoulder` and `--zoom-raise` move ZOOM's shoulder/lift by a delta on top of hip-fire's
`--shoulder`/`--raise`, rather than setting ZOOM to an absolute value of its own: `--shoulder
+1 --zoom-shoulder -0.5` puts hip-fire at `1.0` and ZOOM at `0.5`; `--raise 0.4 --zoom-raise
-0.3` lifts hip-fire `0.4` m and ZOOM `0.1` m. Either one works alone too - e.g. a lone
`--zoom-raise -0.3` leaves hip-fire exactly as authored and drops ZOOM 30 cm below it.

## What it touches

Every .lvl in the install that carries a third-person camera block - not just ingame.lvl.
Side .lvl files store each unit's camera fully resolved, inherited values included, so
com_inf_default alone does not reach the jedi, the heroes, or anything a mod ships.

Properties are located by FNV-1a name hash, never by byte offset, and every replacement is
the same byte length as the value it replaces, so no chunk is ever resized. A file whose
camera block does not parse is left untouched rather than half-written.

## Reverting

Each edit is journalled (offset, old bytes, new bytes) under `$GAMEDATA/.swbf-reticle-fix/`,
and `--restore` puts the old bytes back byte for byte. That is why no copies are kept: a
modded install's side files run past 250 MB each.

Steam's "Verify integrity of game files" replaces .lvl files and silently undoes the fix;
re-run the installer afterwards. Installing another mod over the top does the same to
whichever files it replaces - `--status` will show them as stock again.
