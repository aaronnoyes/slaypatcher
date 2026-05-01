#!/usr/bin/env bash
set -euo pipefail

PRESET_NAME="Linux"
OUTPUT_PCK="./export/game.pck"

EDITOR_ZIP="godot-editor-linux-mono.zip"
TEMPLATES_TPZ="spine-godot-templates-4.2-4.5.1-stable-mono.tpz"
EDITOR_URL="https://spine-godot.s3.eu-central-1.amazonaws.com/4.2/4.5.1-stable/godot-editor-linux-mono.zip"
TEMPLATES_URL="https://spine-godot.s3.eu-central-1.amazonaws.com/4.2/4.5.1-stable/spine-godot-templates-4.2-4.5.1-stable-mono.tpz"

TEMPLATES_DIR="$HOME/.local/share/godot/export_templates"

if [[ ! -f "export_presets.cfg" ]]; then
    echo "Error: export_presets.cfg not found in current directory." >&2
    exit 1
fi

if [[ ! -f "$EDITOR_ZIP" ]]; then
    echo "Downloading Spine editor..."
    curl -L -o "$EDITOR_ZIP" "$EDITOR_URL"
fi

if [[ ! -f "$TEMPLATES_TPZ" ]]; then
    echo "Downloading Spine export templates..."
    curl -L -o "$TEMPLATES_TPZ" "$TEMPLATES_URL"
fi

echo "Extracting editor..."
unzip -q -o "$EDITOR_ZIP" -d ./godot-editor

GODOT_BIN="./godot-editor/godot-4.2-4.5.1-stable-mono"
if [[ ! -f "$GODOT_BIN" ]]; then
    echo "Error: Godot binary not found at $GODOT_BIN" >&2
    exit 1
fi
chmod +x "$GODOT_BIN"

echo "Installing export templates..."
TEMPLATE_VERSION=$("$GODOT_BIN" --version 2>/dev/null | tr -d '\n')
TEMPLATE_DEST="$TEMPLATES_DIR/$TEMPLATE_VERSION"
mkdir -p "$TEMPLATE_DEST"
unzip -q -o "$TEMPLATES_TPZ" -d "$TEMPLATE_DEST"

mkdir -p "$(dirname "$OUTPUT_PCK")"

echo "Exporting PCK..."
"$GODOT_BIN" \
    --headless \
    --path sts2-recover \
    --export-pack "$PRESET_NAME" \
    "$(realpath "$OUTPUT_PCK")"

echo "Done. PCK written to $OUTPUT_PCK"
