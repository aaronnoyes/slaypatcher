# slaypatcher
Tools for patching Slay the Spire 2 to run on arm64 embedded Linux.
This is meant to be run on Linux, I don't have a Windows PC to test on. Feel free to open PRs.
Right now this is quite slow and music does not work. See [Performance work](#performance-work).

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

## Performance work
The game has a built-in mod loader (`<game dir>/mods/<id>/<id>.json` + `<id>.dll` / `<id>.pck`),
so performance experiments don't need a re-export: build the port once, then iterate on small mods.

### Iterating without pulling the SD card
`deploy.sh` pushes over SSH (muOS: Configuration > Web Services > SSH, user `root`):
```
export DEVICE=root@192.168.1.50                 # REMOTE_GAMEDIR defaults to /mnt/sdcard/ports/slaythespire2
./deploy.sh game                                # once (~1.7 GB, skipped per file if unchanged)
./deploy.sh mod                                 # SlayPerf DLL, ~30 KB
./deploy.sh perfenv SLAYPERF_LABEL=spine15 SLAYPERF_SPINE_HZ=15   # pick the experiment
# ...play on the device...
./deploy.sh pull && tools/perfreport.py --last 3
```

### SlayPerf (`perfmod/`)
Diagnostics plus independent knobs, so you can change one thing per run. Build with
`perfmod/build.sh` (needs the .NET 9 SDK and an existing build to compile against).
- On-screen HUD and a CSV per session in `mods/slayperf/logs/`: FPS, frame times, hitches, draw calls,
  texture memory, RSS, available memory, swap use and swap-in/out pages, major faults, process CPU %,
  iowait, CPU/GPU clock, temperature, and markers for the game's preload phases. The sampler runs on its
  own thread, so it keeps recording during long loading stalls.
- Knobs (`slayperf.cfg`, or `SLAYPERF_<KEY>` env vars): `particles=on|half|off`, `spine_hz=N`
  (throttle Spine skeleton updates), `shaders=passthrough` (no-op every ShaderMaterial to measure shader cost),
  `preload_vfx=false` (skip VFX in the preload screens), `max_fps`.
- `share_saves=true` (default) keeps your normal save profile. Modded sessions otherwise use `modded/profileN`.

### SlayLowRes (`tools/make-lowres.sh`)
Most textures are authored for 1080p+, many as lossless PNG/WebP (uncompressed RGBA8 in memory), and
the device draws them at roughly 1/3 scale. This builds an override PCK with downscaled payloads, by
default half size, and converts lossless textures to ASTC:
```
./tools/make-lowres.sh --dry-run        # estimate
./tools/make-lowres.sh                  # ~45 s on a desktop, writes mods/slaylowres/
./tools/make-lowres.sh --scale 0.35 --exclude 'res://images/ui/*'
```
Godot's `.ctex` header stores a texture's logical size separately from its pixel payload and always
applies it as a size override, so the tool keeps the header and shrinks only the payload. Sprites,
atlas regions, Spine attachments and layouts are unaffected. Remove the mod (`./deploy.sh nolowres`)
to compare against full-res textures.

### Launcher knobs
`Slay the Spire 2.sh` reads `perf.env` from the game dir (see `perf.env.example`): `SLAY_MODS=0` for a
vanilla baseline, `SLAY_GOVERNOR=performance`, `SLAY_DOTNET_TWEAKS=1`, and any `SLAYPERF_*` key.

The launcher no longer passes `--force-sentry off`. The game only checks whether that flag is present, so
it was turning Sentry on in debug mode, which logged and uploaded every warning.

### Testing on PC
The x86_64 export runs the same mods. Put them in `export/Linux-x86_64/mods/`, enable mods in
`settings.save` (`"mod_settings": {"mods_enabled": true}`) and run `./game --force-steam off`.
