#!/usr/bin/env bash
# Builds the SlayPerf mod into <gamedir>/mods/slayperf/.
#   ./perfmod/build.sh [gamedir]
# gamedir defaults to ./slaythespire2/slaythespire2 (the port's game folder).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GAMEDIR="$(realpath "${1:-$ROOT/slaythespire2/slaythespire2}")"
OUT="$GAMEDIR/mods/slayperf"

dotnet build "$HERE/SlayPerf.csproj" -c Release -nologo -v quiet -o "$HERE/bin/out"

mkdir -p "$OUT"
cp "$HERE/bin/out/slayperf.dll" "$HERE/slayperf.json" "$OUT/"
# Don't clobber a config you've been tweaking on the device copy.
[[ -f "$OUT/slayperf.cfg" ]] || cp "$HERE/slayperf.cfg" "$OUT/"

echo "Built $OUT/slayperf.dll ($(stat -c %s "$OUT/slayperf.dll") bytes)"
