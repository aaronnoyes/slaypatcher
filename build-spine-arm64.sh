#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
SPINE_DIR="$SCRIPT_DIR/spine-runtimes/spine-godot"
LINUX_PY="$SPINE_DIR/godot-cpp/tools/linux.py"

if [ ! -f "$LINUX_PY" ]; then
    echo "$LINUX_PY not found, running setup script"
    $SPINE_DIR/build/setup-extension.sh 4.5.1-stable false true
fi

if grep -q "aarch64-linux-gnu-gcc" "$LINUX_PY"; then
    echo "Cross-compiler patch already applied, skipping."
else
    echo "Applying arm64 cross-compiler patch to godot-cpp/tools/linux.py..."
    sed -i 's/    elif env\["arch"\] == "arm64":/    elif env["arch"] == "arm64":\n        env["CC"] = "aarch64-linux-gnu-gcc"\n        env["CXX"] = "aarch64-linux-gnu-g++"\n        env["AR"] = "aarch64-linux-gnu-ar"\n        env["LINK"] = "aarch64-linux-gnu-g++"/' "$LINUX_PY"
    echo "Patch applied."
fi

if ! command -v aarch64-linux-gnu-g++ &>/dev/null; then
    echo "Error: aarch64-linux-gnu-g++ not found. Install with:"
    echo "  sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu"
    exit 1
fi

SPINE_GODOT_DIR="$SCRIPT_DIR/spine-runtimes/spine-godot"
CPUS=$(grep -c ^processor /proc/cpuinfo)

echo "Building Spine GDExtension for linux arm64 ($CPUS cores)..."

cd "$SPINE_GODOT_DIR"

scons -j$CPUS platform=linux arch=arm64 target=template_debug
scons -j$CPUS platform=linux arch=arm64 target=template_release

echo "Done! Output in $SPINE_GODOT_DIR/bin/linux/"
