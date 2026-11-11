#!/usr/bin/env bash
# Download a specific (e.g. older) Slay the Spire 2 build from Steam with your own account.
#
#   tools/fetch-game-build.sh <manifest-id> [out-dir]
#   tools/fetch-game-build.sh tested            # the manifest recorded in game-version.json
#
# Manifest IDs per date: https://steamdb.info/depot/2868843/manifests/ (Linux depot 2868843).
# Uses DepotDownloader (https://github.com/SteamRE/DepotDownloader) if it's on PATH. Otherwise
# prints the equivalent Steam console command (built into Steam, no extra tools).
# Then build the port from it:  ./repack.sh <out-dir>/SlayTheSpire2.pck
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=2868840
DEPOT=2868843

manifest="${1:?usage: fetch-game-build.sh <manifest-id>|tested [out-dir]}"
if [[ "$manifest" == "tested" ]]; then
    manifest=$(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1]))["tested"]["steam"]["manifest_id"]; print(m or "")' "$ROOT/game-version.json")
    [[ -n "$manifest" ]] || { echo "game-version.json has no manifest_id for the tested build yet (see its _manifest_note)"; exit 1; }
fi
[[ "$manifest" =~ ^[0-9]+$ ]] || { echo "manifest id must be numeric"; exit 1; }
out="${2:-$ROOT/game-builds/$manifest}"

dd=$(command -v DepotDownloader || command -v depotdownloader || true)
if [[ -n "$dd" ]]; then
    : "${STEAM_USER:?set STEAM_USER to your Steam login (you will be prompted for the password and Steam Guard)}"
    mkdir -p "$out"
    "$dd" -app "$APP" -depot "$DEPOT" -manifest "$manifest" -username "$STEAM_USER" -remember-password -dir "$out"
    echo "Downloaded to $out"
    [[ -f "$out/release_info.json" ]] && cat "$out/release_info.json"
else
    cat <<EOF
DepotDownloader isn't installed. Either install it (https://github.com/SteamRE/DepotDownloader),
or use Steam's built-in console:

  1. Open steam://open/console in a browser (or run: steam steam://open/console)
  2. Enter:  download_depot $APP $DEPOT $manifest
  3. Steam prints where it saved the files, usually:
       ~/.steam/debian-installation/steamapps/content/app_$APP/depot_$DEPOT/
  4. Build the port from it:  ./repack.sh <that folder>/SlayTheSpire2.pck
EOF
fi
