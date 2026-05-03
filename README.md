# slaypatcher
Tools for patching Slay the Spire 2 to run on arm64 embedded Linux.
This is meant to be run on Linux, I don't have a Windows PC to test on. Feel free to open PRs.
Right now this is quite slow and music does not work.

## Requirements
- Python 3
- scons
- g++-aarch64-linux-gnu
- gcc-aarch64-linux-gnu
- dotnet 9.0.303
  - You should be able to modify global.json in the recovered project to use a different version
  - If you don't have this then it is hard to figure out what's broken when it tries to build

### Downloaded via scripts
- [Spine Editor with C# support](https://spine-godot.s3.eu-central-1.amazonaws.com/4.2/4.5.1-stable/godot-editor-linux-mono.zip)
- [Spine release templates](https://spine-godot.s3.eu-central-1.amazonaws.com/4.2/4.5.1-stable/spine-godot-templates-4.2-4.5.1-stable-mono.tpz)
- [gdsdecomp](https://github.com/GDRETools/gdsdecomp)

### Submodules
```
git submodule update --init
```
or clone with `--recurse-submodules`.

## Patching
```
./repack.sh /path/to/SlayTheSpire2.pck [preset] [output_dir]
```

- `preset` — Godot export preset name. Defaults to `Linux ARM64`.
- `output_dir` — Where to write the exported binary. Defaults to `./slaythespire2/slaythespire2`.

The exported files land in `output_dir` as `sts2` (plus any supporting files Godot writes alongside it).

Set `FORCE=1` to re-run all steps even if outputs already exist:
```
FORCE=1 ./repack.sh /path/to/SlayTheSpire2.pck
```

## Deploying
Copy `./slaythespire2` to `/mnt/mmc/ports` on your device:
```
cp -r ./slaythespire2 /mnt/mmc/ports/
```

Copy the launch script to your ports roms directory:
```
cp "Slay the Spire 2.sh" /mnt/mmc/roms/ports/
```

The `slaythespire2/conf` directory contains a default settings config and will be created on first run if absent.
