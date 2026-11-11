#!/usr/bin/env bash
# Builds the FMOD GDExtension for Linux arm64 and wires it into the recovered project, so the next
# export (repack.sh) includes working audio.
#
#   FMOD_SDK=/path/to/fmodstudioapi20306linux.tar.gz ./tools/build-fmod-arm64.sh
#
# The game ships FMOD for Windows/macOS/Linux x86_64/Android only. It uses FMOD 2.03.06 and
# fmod-gdextension 6.1.0. The FMOD SDK needs a (free) account on fmod.com, so it isn't
# downloaded here: get "FMOD Engine" 2.03.06 for Linux from https://www.fmod.com/download
# (Older versions). The Linux package includes arm64 libraries.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECOVER_DIR="${RECOVER_DIR:-$ROOT/sts2-recover}"
ADDON="$RECOVER_DIR/addons/fmod"
SRC="$ROOT/fmod-gdextension"
SDK_DIR="$ROOT/fmod-sdk"
FMOD_VERSION_WANTED="2.03.06"
GDEXT_TAG="6.1.0-4.5.0"
CPUS=$(nproc)

: "${FMOD_SDK:?set FMOD_SDK to the FMOD Engine $FMOD_VERSION_WANTED Linux .tar.gz (from fmod.com)}"
[[ -f "$ADDON/fmod.gdextension" ]] || { echo "No recovered project at $RECOVER_DIR; run repack.sh first"; exit 1; }
command -v aarch64-linux-gnu-g++ >/dev/null || { echo "aarch64-linux-gnu-g++ not found"; exit 1; }

# ---- FMOD SDK
if [[ ! -d "$SDK_DIR/api" ]]; then
    echo "Extracting FMOD SDK"
    rm -rf "$SDK_DIR" && mkdir -p "$SDK_DIR"
    tar -xzf "$FMOD_SDK" -C "$SDK_DIR" --strip-components=1
fi
core_lib="$SDK_DIR/api/core/lib/arm64"
studio_lib="$SDK_DIR/api/studio/lib/arm64"
[[ -f "$core_lib/libfmod.so" && -f "$studio_lib/libfmodstudio.so" ]] \
    || { echo "SDK has no arm64 libs under $SDK_DIR/api/*/lib/arm64. Is it the Linux package?"; exit 1; }
real_core=$(basename "$(readlink -f "$core_lib/libfmod.so")")
echo "FMOD SDK core lib: $real_core (want $FMOD_VERSION_WANTED, i.e. libfmod.so.14.6)"
[[ "$real_core" == "libfmod.so.14.6" ]] || echo "WARNING: version mismatch; the game's banks were built for $FMOD_VERSION_WANTED"

# The SConstruct expects <fmod_lib_dir>/linux/{core,studio}/{inc,lib/<arch>}; the SDK has api/...
mkdir -p "$SDK_DIR/layout"
ln -sfn "$SDK_DIR/api" "$SDK_DIR/layout/linux"

# ---- plugin source
if [[ ! -d "$SRC/.git" ]]; then
    git clone -q --branch "$GDEXT_TAG" --recurse-submodules --shallow-submodules --depth 1 \
        https://github.com/utopia-rise/fmod-gdextension.git "$SRC"
fi
LINUX_PY="$SRC/godot-cpp/tools/linux.py"
if ! grep -q "aarch64-linux-gnu-gcc" "$LINUX_PY"; then
    echo "Patching godot-cpp linux.py for cross-compiling"
    sed -i 's/    elif env\["arch"\] == "arm64":/    elif env["arch"] == "arm64":\n        env["CC"] = "aarch64-linux-gnu-gcc"\n        env["CXX"] = "aarch64-linux-gnu-g++"\n        env["AR"] = "aarch64-linux-gnu-ar"\n        env["LINK"] = "aarch64-linux-gnu-g++"/' "$LINUX_PY"
fi

# Upstream relies on <cstdio> arriving transitively. The aarch64 cross GCC doesn't provide it.
COMMON_H="$SRC/src/helpers/common.h"
grep -q "#include <cstdio>" "$COMMON_H" || sed -i '0,/^#include/s//#include <cstdio>\n#include/' "$COMMON_H"

# Upstream only builds Linux x86_64: it always adds -m64 and gold, which the aarch64 toolchain rejects.
SCONS_FILE="$SRC/SConstruct"
grep -q 'if env\["arch"\] == "x86_64": env.Append(LINKFLAGS=\["-m64"' "$SCONS_FILE" \
    || sed -i 's/^    env.Append(LINKFLAGS=\["-m64", "-fuse-ld=gold"\])/    if env["arch"] == "x86_64": env.Append(LINKFLAGS=["-m64", "-fuse-ld=gold"])/' "$SCONS_FILE"

# ---- build
OUT="$SRC/out/"
for target in template_release template_debug; do
    echo "Building libGodotFmod.linux.$target.arm64.so"
    (cd "$SRC" && scons -j"$CPUS" platform=linux arch=arm64 target="$target" \
        fmod_lib_dir="$SDK_DIR/layout/" target_path="$OUT")
done
built=$(find "$OUT" -name "libGodotFmod.linux.template_release.arm64.so" -print -quit)
[[ -n "$built" ]] || { echo "build produced no arm64 library"; exit 1; }
aarch64-linux-gnu-readelf -d "$built" | grep -E "NEEDED|RUNPATH|RPATH" || true

# ---- install into the recovered project
DEST="$ADDON/libs/linux/arm64"
mkdir -p "$DEST"
find "$OUT" -name 'libGodotFmod.linux.template_*.arm64.so' -exec cp {} "$DEST/" \;
for d in "$core_lib" "$studio_lib"; do
    cp -P "$d"/libfmod*.so* "$DEST/" 2>/dev/null || true
done
ls -la "$DEST"

python3 -I - "$ADDON/fmod.gdextension" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
if "linux.release.arm64" in s:
    print("fmod.gdextension already has arm64 entries")
    sys.exit(0)
libs = '''linux.debug.arm64 = "res://addons/fmod/libs/linux/arm64/libGodotFmod.linux.template_debug.arm64.so"
linux.release.arm64 = "res://addons/fmod/libs/linux/arm64/libGodotFmod.linux.template_release.arm64.so"
'''
deps = '''linux.debug.arm64 = {
"libs/linux/arm64/libfmodL.so": "",
"libs/linux/arm64/libfmodL.so.14": "",
"libs/linux/arm64/libfmodL.so.14.6": "",
"libs/linux/arm64/libfmodstudioL.so": "",
"libs/linux/arm64/libfmodstudioL.so.14": "",
"libs/linux/arm64/libfmodstudioL.so.14.6": ""
}
linux.release.arm64 = {
"libs/linux/arm64/libfmod.so": "",
"libs/linux/arm64/libfmod.so.14": "",
"libs/linux/arm64/libfmod.so.14.6": "",
"libs/linux/arm64/libfmodstudio.so": "",
"libs/linux/arm64/libfmodstudio.so.14": "",
"libs/linux/arm64/libfmodstudio.so.14.6": ""
}
'''
s = s.replace("\n[icons]", libs + "\n[icons]", 1)
s = s.replace("\n[dependencies]\n", "\n[dependencies]\n" + deps, 1)
open(p, "w").write(s)
print("added linux arm64 entries to fmod.gdextension")
EOF

echo
echo "Done. Re-export the port (only the export step re-runs):"
echo "  rm '$ROOT/slaythespire2/slaythespire2/sts2' && ./repack.sh /path/to/SlayTheSpire2.pck"
