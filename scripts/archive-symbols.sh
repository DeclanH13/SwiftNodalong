#!/bin/zsh
# Keeps a symbolicatable copy of a build so a MetricKit stack from the field can
# be resolved later: dsymutil the debug dylib, store it under its build UUID.
#   scripts/archive-symbols.sh /path/to/Nodalong.app
# Then:  atos -arch arm64 -o .symbols/<UUID>/Nodalong.debug.dylib.dSYM/Contents/Resources/DWARF/Nodalong.debug.dylib -l <loadAddr> <addr>
set -e
APP="$1"; [ -d "$APP" ] || { echo "usage: $0 Nodalong.app"; exit 1; }
DYLIB="$APP/Nodalong.debug.dylib"; [ -f "$DYLIB" ] || DYLIB="$APP/Nodalong"
UUID=$(dwarfdump --uuid "$DYLIB" | head -1 | awk '{print $2}')
DEST="$(dirname "$0")/../.symbols/$UUID"
mkdir -p "$DEST"
cp -R "$DYLIB" "$DEST/"
dsymutil "$DEST/$(basename "$DYLIB")" -o "$DEST/$(basename "$DYLIB").dSYM" 2>/dev/null || true
echo "archived $UUID -> $DEST"
