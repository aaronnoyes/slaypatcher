# slaypatcher

Tools for running Slay the Spire 2 on arm64 embedded Linux.

## Requirements
- scons
- g++-aarch64-linux-gnu
- gcc-aarch64-linux-gnu
- [Spine Editor with C+ support](https://spine-godot.s3.eu-central-1.amazonaws.com/4.2/4.5.1-stable/godot-editor-linux-mono.zip)
- [gdsdecomp](https://github.com/GDRETools/gdsdecomp)

### Submodules
`git submodule update --init` OR `git clone --recurse-submodules`

## Cross compile spine
Spine runtimes are needed for animations (I think). This script will download godot-cpp
and build the spine runtime shared objects.

`./build-spine-arm64.sh`

Built shared objects can be found in `./spine-runtimes/spine-godot/bin/linux/`
