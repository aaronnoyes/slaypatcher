# slaypatcher

Tools for running Slay the Spire 2 on arm64 embedded Linux.

## Requirements
- Python 3
- scons
- g++-aarch64-linux-gnu
- gcc-aarch64-linux-gnu
- dotnet 9.0.303
  - You should be able to modify global.json in the recovered project to use a different versoin

### Downloaded via scripts
- [Spine Editor with C+ support](https://spine-godot.s3.eu-central-1.amazonaws.com/4.2/4.5.1-stable/godot-editor-linux-mono.zip)
- [Spine release templates](https://spine-godot.s3.eu-central-1.amazonaws.com/4.2/4.5.1-stable/spine-godot-templates-4.2-4.6.1-stable-mono.tpz)
- [gdsdecomp](https://github.com/GDRETools/gdsdecomp)

### Submodules
`git submodule update --init` OR `git clone --recurse-submodules`

## Patching
- Run `./repack.sh /path/to/SlayTheSpire2.pck"
- The exported game will be in `./exports/Linux-ARM64/`

## Running
- Copy the exported game folder and the `Slay\ the\ Spire\ 2.sh` file to the appropriate folders in PortMaster
