#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
SRC="$SCRIPT_DIR/spine-runtimes/spine-godot/bin/linux"
DEST="$SCRIPT_DIR/sts2-recover/addons/spine/linux"

if [[ ! -d "$SRC" ]]; then
    echo "Error: Source directory not found: $SRC" >&2
    exit 1
fi

if [[ ! -d "$DEST" ]]; then
    echo "Error: Destination directory not found: $DEST" >&2
    exit 1
fi

cp "$SRC"/libspine_godot.linux.*.arm64.so "$DEST/"
