# slaypatcher

Tools for running Slay the Spire 2 on arm64 embedded Linux.

## Requirements
- scons
- g++-aarch64-linux-gnu
- gcc-aarch64-linux-gnu

### Submodules
`git submodule update --init` OR `git clone --recurse-submodules`

## Cross compile spine
Spine runtimes are needed for animations (I think). This script will download godot-cpp
and build the spine runtime shared objects.

`./build-spine-arm64.sh`

Built shared objects can be found in `./spine-runtimes/spine-godot/bin/linux/`
