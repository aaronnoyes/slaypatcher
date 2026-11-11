#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

PCK_FILE="${1:?Usage: $0 <pck_file> [preset] [output_dir]}"
PRESET_NAME="${2:-Linux ARM64}"
OUTPUT_DIR="$(realpath "${3:-$SCRIPT_DIR/slaythespire2/slaythespire2}")"

FORCE="${FORCE:-0}"

SPINE_DIR="$SCRIPT_DIR/spine-runtimes/spine-godot"
LINUX_PY="$SPINE_DIR/godot-cpp/tools/linux.py"
SPINE_BIN="$SPINE_DIR/bin/linux"
# RECOVER_DIR can be overridden to build another game version side by side (README "Game versions").
RECOVER_DIR="${RECOVER_DIR:-$SCRIPT_DIR/sts2-recover}"
ADDON_DIR="$RECOVER_DIR/addons/spine/linux"

EDITOR_ZIP="$SCRIPT_DIR/godot-editor-linux-mono.zip"
TEMPLATES_TPZ="$SCRIPT_DIR/spine-godot-templates-4.2-4.5.1-stable-mono.tpz"
EDITOR_URL="https://spine-godot.s3.eu-central-1.amazonaws.com/4.2/4.5.1-stable/godot-editor-linux-mono.zip"
TEMPLATES_URL="https://spine-godot.s3.eu-central-1.amazonaws.com/4.2/4.5.1-stable/spine-godot-templates-4.2-4.5.1-stable-mono.tpz"

GDRE_ZIP="$SCRIPT_DIR/GDRE_tools-v2.5.0-beta.5-linux.zip"
GDRE_URL="https://github.com/GDRETools/gdsdecomp/releases/download/v2.5.0-beta.5/GDRE_tools-v2.5.0-beta.5-linux.zip"
GDRE_BIN="$SCRIPT_DIR/gdre-tools/gdre_tools.x86_64"

GODOT_BIN="$SCRIPT_DIR/godot-editor/godot-4.2-4.5.1-stable-mono"

CPUS=$(grep -c ^processor /proc/cpuinfo)

if [[ "$FORCE" -eq 1 || ! -f "$GDRE_ZIP" ]]; then
    echo "Downloading gdsdecomp"
    curl -L -o "$GDRE_ZIP" "$GDRE_URL"
fi

if [[ "$FORCE" -eq 1 || ! -f "$GDRE_BIN" ]]; then
    echo "Extracting gdsdecomp"
    unzip -q -o "$GDRE_ZIP" -d "$SCRIPT_DIR/gdre-tools"
    chmod +x "$GDRE_BIN"
fi

echo "Checking recovered project"

# Which game build is the input? Steam keeps release_info.json next to the PCK.
INPUT_RELEASE="$(dirname "$PCK_FILE")/release_info.json"
RECORDED_RELEASE="$RECOVER_DIR/.slaypatcher-source-release.json"
input_version=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version","?"))' "$INPUT_RELEASE" 2>/dev/null || echo "unknown")
echo "Input PCK game version: $input_version"

if [[ "$FORCE" -eq 1 || ! -f "$RECOVER_DIR/project.godot" ]]; then
    echo "Recovering PCK"
    if [[ -d "$RECOVER_DIR" && ! -d "$SCRIPT_DIR/snapshots" ]]; then
        echo "WARNING: replacing the recovered project, and there are no snapshots."
        echo "         Consider 'tools/snapshot.sh save' first (see README 'Game versions')."
    fi
    rm -rf "$RECOVER_DIR"
    "$GDRE_BIN" --headless --recover="$PCK_FILE" --output="$RECOVER_DIR"
    if [[ -f "$INPUT_RELEASE" ]]; then
        cp "$INPUT_RELEASE" "$RECORDED_RELEASE"
    else
        echo '{"version": "unknown"}' > "$RECORDED_RELEASE"
    fi
    echo "Recovered game version $input_version. Update game-version.json once it's tested."
else
    echo "Recovery skipped"
    if [[ -f "$RECORDED_RELEASE" ]]; then
        recorded_version=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version","?"))' "$RECORDED_RELEASE")
        echo "Recovered project is game version $recorded_version"
        if [[ "$recorded_version" != "$input_version" ]]; then
            echo "WARNING: the input PCK ($input_version) differs from the recovered project ($recorded_version)."
            echo "         Building from the existing recovery. Use FORCE=1 to re-recover (snapshot first)."
        fi
    else
        echo "NOTE: the recovered project's game version wasn't recorded (recovered before version"
        echo "      tracking). See game-version.json for what it is. The input PCK is $input_version."
    fi
fi

if [[ ! -f "$LINUX_PY" ]]; then
    echo "Running Spine setup"
    "$SPINE_DIR/build/setup-extension.sh" 4.5.1-stable false true
fi

if ! grep -q "aarch64-linux-gnu-gcc" "$LINUX_PY"; then
    echo "Patching linux.py"
    sed -i 's/    elif env\["arch"\] == "arm64":/    elif env["arch"] == "arm64":\n        env["CC"] = "aarch64-linux-gnu-gcc"\n        env["CXX"] = "aarch64-linux-gnu-g++"\n        env["AR"] = "aarch64-linux-gnu-ar"\n        env["LINK"] = "aarch64-linux-gnu-g++"/' "$LINUX_PY"
fi

if ! command -v aarch64-linux-gnu-g++ &>/dev/null; then
    echo "aarch64-linux-gnu-g++ not found"
    exit 1
fi

DEBUG_SO=$(find "$SPINE_BIN" -maxdepth 1 -name "libspine_godot.linux.template_debug*.arm64.so" -print -quit)
RELEASE_SO=$(find "$SPINE_BIN" -maxdepth 1 -name "libspine_godot.linux.template_release*.arm64.so" -print -quit)

if [[ "$FORCE" -eq 1 || -z "$DEBUG_SO" || -z "$RELEASE_SO" ]]; then
    echo "Building Spine"
    cd "$SPINE_DIR"
    [[ -z "$DEBUG_SO" ]]   && scons -j"$CPUS" platform=linux arch=arm64 target=template_debug
    [[ -z "$RELEASE_SO" ]] && scons -j"$CPUS" platform=linux arch=arm64 target=template_release
    cd "$SCRIPT_DIR"
else
    echo "Spine build skipped"
fi

echo "Copying Spine libs"
mkdir -p "$ADDON_DIR"
cp "$SPINE_BIN"/libspine_godot.linux.*.arm64.so "$ADDON_DIR/" 2>/dev/null || true

# Audio: the game ships no Linux arm64 FMOD. If you have the FMOD SDK (needs a free fmod.com
# account), build and wire in the arm64 plugin. See tools/build-fmod-arm64.sh.
if [[ -n "${FMOD_SDK:-}" ]]; then
    echo "Building FMOD for arm64"
    "$SCRIPT_DIR/tools/build-fmod-arm64.sh"
else
    echo "FMOD_SDK not set, skipping audio (the port will run without sound)"
fi

if [[ "$FORCE" -eq 1 || ! -f "$EDITOR_ZIP" ]]; then
    echo "Downloading editor"
    curl -L -o "$EDITOR_ZIP" "$EDITOR_URL"
fi

if [[ "$FORCE" -eq 1 || ! -f "$GODOT_BIN" ]]; then
    echo "Extracting editor"
    unzip -q -o "$EDITOR_ZIP" -d "$SCRIPT_DIR/godot-editor"
    chmod +x "$GODOT_BIN"
fi

if [[ "$FORCE" -eq 1 || ! -f "$TEMPLATES_TPZ" ]]; then
    echo "Downloading templates"
    curl -L -o "$TEMPLATES_TPZ" "$TEMPLATES_URL"
fi

TEMPLATE_VERSION=$("$GODOT_BIN" --version 2>/dev/null | tr -d '\n')
TEMPLATE_DEST="$HOME/.local/share/godot/export_templates/$TEMPLATE_VERSION"

if [[ "$FORCE" -eq 1 || ! -d "$TEMPLATE_DEST" ]]; then
    echo "Installing templates"
    mkdir -p "$TEMPLATE_DEST"
    unzip -q -o "$TEMPLATES_TPZ" -d "$TEMPLATE_DEST"
else
    echo "Templates already installed"
fi

echo "Checking ASTC imports"

if [[ "$FORCE" -eq 1 ]] || ! find "$RECOVER_DIR/.godot/imported" -type f -name "*.astc.ctex" -print -quit 2>/dev/null | grep -q .; then
    echo "Importing project"
    rm -rf "$RECOVER_DIR/.godot"

    "$GODOT_BIN" \
        --headless \
        --path "$RECOVER_DIR" \
        --import \
        --quit
else
    echo "Import skipped"
fi

mkdir -p "$OUTPUT_DIR"

FINAL_BIN="$OUTPUT_DIR/sts2"

if [[ "$FORCE" -eq 1 || ! -f "$FINAL_BIN" ]]; then
    echo "Exporting $PRESET_NAME"
    cp "$SCRIPT_DIR/export_presets.cfg" "$RECOVER_DIR/export_presets.cfg"
    sed -i 's|project/solution_directory=.*|project/solution_directory="./"|' "$RECOVER_DIR/project.godot"

    "$GODOT_BIN" \
        --headless \
        --path "$RECOVER_DIR" \
        --export-release "$PRESET_NAME" \
        "$FINAL_BIN"
else
    echo "Export skipped"
fi

echo "Done"
