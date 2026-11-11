#!/usr/bin/env bash
# Builds the "slaylowres" texture-override mod from the port's PCK.
#
#   ./tools/make-lowres.sh [options passed to lowres.gd]
#
# Common options:
#   --scale 0.5         payload scale relative to the 1920x1080-authored size (default 0.5)
#   --min-size 256      leave textures whose longest side is smaller than this alone
#   --max-size 2048     additionally cap the longest side
#   --lossless astc     what to do with PNG/WebP ("lossless") textures: astc | etc2 | keep
#   --exclude 'res://images/ui/*'   comma-separated globs on source paths to leave untouched
#   --dry-run           just print the estimated savings
#
# Env: PCK=<input pck>  GAMEDIR=<port game folder>  GODOT=<godot editor binary>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAMEDIR="$(realpath "${GAMEDIR:-$ROOT/slaythespire2/slaythespire2}")"
PCK="$(realpath "${PCK:-$GAMEDIR/sts2.pck}")"
GODOT="${GODOT:-$ROOT/godot-editor/godot-4.2-4.5.1-stable-mono}"
OUT_DIR="$GAMEDIR/mods/slaylowres"

[[ -f "$PCK" ]]   || { echo "No PCK at $PCK (set PCK=...)"; exit 1; }
[[ -x "$GODOT" ]] || { echo "No Godot editor at $GODOT (run repack.sh once, or set GODOT=...)"; exit 1; }

mkdir -p "$OUT_DIR"
"$GODOT" --headless --path "$ROOT/tools/lowres" --script lowres.gd -- \
    --pck "$PCK" --out "$OUT_DIR/slaylowres.pck" "$@"

for a in "$@"; do [[ "$a" == "--dry-run" ]] && exit 0; done

cat > "$OUT_DIR/slaylowres.json" <<'EOF'
{
  "id": "slaylowres",
  "name": "SlayLowRes",
  "author": "slaypatcher",
  "description": "Downscaled texture payloads for low-memory handhelds. Logical sizes are unchanged so layouts are unaffected.",
  "version": "0.1.0",
  "has_pck": true,
  "has_dll": false,
  "affects_gameplay": false
}
EOF
echo "Mod ready in $OUT_DIR"
