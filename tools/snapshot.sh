#!/usr/bin/env bash
# Local, untracked snapshots of a known-good port state, so moving to a new game build can be
# undone without needing the old game files from Steam.
#
#   tools/snapshot.sh save [name]      archive sts2-recover/ (recovered project + imports) and the
#                                      built port folder into snapshots/<name>/ (default: dated)
#   tools/snapshot.sh list
#   tools/snapshot.sh restore <name>   put both back (moves the current ones aside first)
#
# Snapshots contain Mega Crit game data and FMOD libraries: they stay local (gitignored) and must
# not be shared. Restoring brings back exactly what was built and tested; push it to the device
# with ./deploy.sh install mod lowres.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPDIR="$ROOT/snapshots"
# Which build to snapshot/restore (relative to the repo). Defaults are the tested build.
# For a side-by-side build: RECOVER_DIR=sts2-recover-latest LOCAL_GAMEDIR=export/latest-arm64
RECOVER="$(realpath -m --relative-to="$ROOT" "${RECOVER_DIR:-$ROOT/sts2-recover}")"
PORT="$(realpath -m --relative-to="$ROOT" "${LOCAL_GAMEDIR:-$ROOT/slaythespire2/slaythespire2}")"

compress() { zstd -T0 -6 -q; }
decompress() { zstd -d -q; }

cmd="${1:-}"; shift || true
case "$cmd" in
    save)
        name="${1:-$(date +%Y%m%d)-$(git -C "$ROOT" rev-parse --short HEAD)}"
        dest="$SNAPDIR/$name"
        [[ -e "$dest" ]] && { echo "snapshot $name already exists"; exit 1; }
        [[ -d "$ROOT/$RECOVER" && -d "$ROOT/$PORT" ]] || { echo "nothing to snapshot (run repack.sh first)"; exit 1; }
        mkdir -p "$dest"
        echo "Archiving $RECOVER (recovered project + imported textures)..."
        tar -C "$ROOT" -cf - "$RECOVER" | compress > "$dest/recover.tar.zst"
        echo "Archiving $PORT (built port, mods, default conf)..."
        tar -C "$ROOT" -cf - "$PORT" | compress > "$dest/port.tar.zst"
        cp "$ROOT/game-version.json" "$dest/"
        printf 'recover=%s\nport=%s\n' "$RECOVER" "$PORT" > "$dest/paths.txt"
        [[ -f "$ROOT/$RECOVER/.slaypatcher-source-release.json" ]] && cp "$ROOT/$RECOVER/.slaypatcher-source-release.json" "$dest/release_info.json"
        git -C "$ROOT" rev-parse HEAD > "$dest/slaypatcher-commit.txt"
        (cd "$dest" && sha256sum recover.tar.zst port.tar.zst > SHA256SUMS)
        du -sh "$dest"
        echo "Saved snapshot: $name"
        ;;
    list)
        [[ -d "$SNAPDIR" ]] || { echo "no snapshots"; exit 0; }
        for d in "$SNAPDIR"/*/; do
            n=$(basename "$d")
            if [[ -f "$d/release_info.json" ]]; then
                label="game $(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version","?"))' "$d/release_info.json")"
            else
                label=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["tested"]["label"])' "$d/game-version.json" 2>/dev/null || echo "?")
            fi
            echo "$n  $(du -sh "$d" | cut -f1)  commit $(cut -c1-7 "$d/slaypatcher-commit.txt" 2>/dev/null)  $label"
        done
        ;;
    restore)
        name="${1:?usage: snapshot.sh restore <name>}"
        src="$SNAPDIR/$name"
        [[ -f "$src/SHA256SUMS" ]] || { echo "no snapshot $name"; exit 1; }
        if [[ -f "$src/paths.txt" ]]; then
            RECOVER=$(sed -n 's/^recover=//p' "$src/paths.txt")
            PORT=$(sed -n 's/^port=//p' "$src/paths.txt")
        fi
        echo "Restoring $RECOVER and $PORT"
        echo "Verifying checksums..."
        (cd "$src" && sha256sum -c --quiet SHA256SUMS)
        aside="$ROOT/snapshots/.replaced-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$aside/$(dirname "$PORT")"
        [[ -e "$ROOT/$RECOVER" ]] && mv "$ROOT/$RECOVER" "$aside/"
        [[ -e "$ROOT/$PORT" ]] && mv "$ROOT/$PORT" "$aside/$PORT"
        echo "Moved the current state aside to $aside (delete it once you're happy)"
        decompress < "$src/recover.tar.zst" | tar -C "$ROOT" -xf -
        decompress < "$src/port.tar.zst" | tar -C "$ROOT" -xf -
        echo "Restored snapshot $name (slaypatcher commit $(cut -c1-7 "$src/slaypatcher-commit.txt"))."
        echo "If the scripts changed since, consider: git checkout $(cut -c1-7 "$src/slaypatcher-commit.txt")"
        echo "Push to the device with: ./deploy.sh install mod lowres"
        ;;
    *)
        sed -n '2,14p' "$0"; exit 1 ;;
esac
