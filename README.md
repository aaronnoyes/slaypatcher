# slaypatcher
Tools for patching Slay the Spire 2 to run on arm64 embedded Linux.
This is meant to be run on Linux, I don't have a Windows PC to test on. Feel free to open PRs.
Status (tested on an H700 / muOS handheld): playable at a mostly steady 30 FPS with the
[recommended performance setup](#recommended-setup). Some stutter remains. Audio works once
you build the arm64 FMOD plugin (see [Audio](#audio)). Measurements and findings are in [PERF_NOTES.md](PERF_NOTES.md).
Contributor/agent notes (layout, workflow, gotchas) are in [CLAUDE.md](CLAUDE.md).

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
Over SSH (recommended, see [deploy.sh](#iterating-without-pulling-the-sd-card)):
```
export DEVICE=root@<device-ip> REMOTE_LAUNCHER_DIR=/mnt/sdcard/ROMS/PORTS
./deploy.sh install mod launcher
```

Or by hand: copy `./slaythespire2/slaythespire2` to `<sd>/ports/slaythespire2` and
`./slaythespire2/Slay the Spire 2.sh` to your ports roms folder (muOS: `/mnt/sdcard/ROMS/PORTS`).

The `slaythespire2/conf` directory contains a default settings config (with mod loading pre-accepted)
and will be created on first run if absent. The launcher needs PortMaster's `weston_pkg_0.2` runtime. If
PortMaster says it's unknown, refresh it first (`harbourmaster update`).

**Settings menu:** every launch opens a small menu first (a LÖVE app using PortMaster's bundled
runtime, same pattern as the Binding of Isaac port). **A/Start** launches, **Left/Right** changes a
row, and **B** goes back to the frontend. Rows: preset (Recommended / Battery / Quality, or Custom),
low-res textures, animation rate, particles, fewer GC pauses, CPU at full speed, performance overlay.
Each row's help line gives the measured effect. Choices are saved in `conf/love/sts2launcher/settings.cfg`.
`perf.env` still applies on top (for experiments). Put `SLAY_SKIP_MENU=1` in it to skip the menu.

**Quitting:** Select+Start. (Menu+Start does nothing.) The launcher watches PortMaster's gptokeyb and
asks the game to quit when the hotkey fires. SlayPerf turns that into the game's own save-and-quit.

## Audio
The game uses FMOD 2.03.06 through fmod-gdextension 6.1.0, and only ships native libraries for
Windows, macOS, Linux x86_64 and Android. The Android arm64 ones are bionic builds and can't load on
glibc. `tools/build-fmod-arm64.sh` cross-compiles the plugin for Linux arm64 and adds it to the
recovered project. GDExtensions load before mods, so this needs a re-export.

1. Download **FMOD Engine 2.03.06 for Linux** from https://www.fmod.com/download (free account,
   under older versions). The Linux package includes arm64 libraries. FMOD's license doesn't allow
   redistributing it, so it isn't fetched automatically.
2. Build and re-export. `repack.sh` only re-runs steps whose outputs are missing:
   ```
   FMOD_SDK=/path/to/fmodstudioapi20306linux.tar.gz ./tools/build-fmod-arm64.sh
   rm slaythespire2/slaythespire2/sts2 && ./repack.sh /path/to/SlayTheSpire2.pck
   ./deploy.sh game
   ```
   (`FMOD_SDK=... ./repack.sh ...` also runs the FMOD step as part of a full build.)

The plugin built with the Ubuntu cross toolchain needs glibc >= 2.38 on the device (muOS 2601 has
2.44). FMOD's own libraries only need 2.17. Older firmware would need an older cross toolchain.

## Performance work
The game has a built-in mod loader (`<game dir>/mods/<id>/<id>.json` + `<id>.dll` / `<id>.pck`),
so performance experiments don't need a re-export: build the port once, then iterate on small mods.

### Recommended setup
What the measurements so far support (H700, 973 MB RAM, no swap). Details in [PERF_NOTES.md](PERF_NOTES.md).
```
./tools/make-lowres.sh                       # build the half-size texture mod
./deploy.sh mod lowres lowres-on launcher
./deploy.sh perfenv SLAYPERF_SPINE_HZ=15 SLAY_DOTNET_TWEAKS=1 SLAY_GOVERNOR=performance
```
- **Low-res textures** are the big one. Without them, the game runs out of RAM in combat and thrashes
  the SD card (~0.1 FPS). With them: ~320 MB free, 30 FPS, main menu in ~27 s instead of ~48 s.
- **`spine_hz=15`** removes the sustained 17-18 FPS dips caused by Spine CPU skinning.
- **`SLAY_DOTNET_TWEAKS=1`** cuts gen0 GCs from ~170 to ~10 per session (small hitches -2/3).
- **`SLAY_GOVERNOR=performance`** keeps the CPU at full clock while the game runs (under `schedutil` it fell
  to 288 MHz between bursts). Peak temperature in testing was 66 C. The launcher restores the old governor on exit.
- The first time each effect is drawn, its shaders compile (2-10 s freeze). They're cached in
  `conf/SlayTheSpire2/shader_cache`, so each one only happens once per install.

**Game version caveat:** this was built from an older game build. Rebuild the low-res PCK whenever the
game PCK changes. Godot names imported textures by source path, not content, so a stale low-res PCK
silently replaces updated art with old art.

### Iterating without pulling the SD card
`deploy.sh` pushes over SSH (muOS: Configuration > Web Services > SSH, user `root`, password `root`):
```
export DEVICE=root@<device-ip>      # REMOTE_GAMEDIR defaults to /mnt/sdcard/ports/slaythespire2
./deploy.sh install                 # once: game files (~1.7 GB, skipped per file if unchanged) + default conf
./deploy.sh mod                     # SlayPerf DLL, ~30 KB (keeps the device's slayperf.cfg)
./deploy.sh lowres                  # texture mod, ~430 MB, skipped if unchanged
./deploy.sh lowres-off              # park it outside mods/ (no re-upload to turn it back on: lowres-on)
./deploy.sh perfenv SLAYPERF_LABEL=spine15 SLAYPERF_SPINE_HZ=15   # settings for the next launch
# ...play on the device...
./deploy.sh shot                    # screenshot from the framebuffer into device-logs/shots/
./deploy.sh pull && tools/perfreport.py --last 3
```
To watch a session live: `ssh root@<ip> 'tail -F /mnt/sdcard/ports/slaythespire2/mods/slayperf/logs/<csv>'`.
For several commands without retyping the password, open a shared connection and pass it in
`SSH_OPTS="-o ControlPath=..."`.

### SlayPerf (`perfmod/`)
Diagnostics plus independent knobs, so you can change one thing per run. Build with
`perfmod/build.sh` (needs the .NET 9 SDK and an existing build to compile against).
- A CSV per session in `mods/slayperf/logs/` (plus an optional on-screen HUD, `hud=true`, off by
  default): FPS, frame times, hitches, draw calls,
  texture memory, RSS, available memory, swap use and swap-in/out pages, major faults, process CPU %,
  iowait, CPU/GPU clock, temperature, and markers for the game's preload phases. The sampler runs on its
  own thread, so it keeps recording during long loading stalls. A second file, `<csv>-hitches.csv`, gets one
  line per frame slower than `hitch_log_ms` (default 100): GC runs and nodes added during that frame,
  Spine updates, CPU clock and the game's last log line, so individual stutters can be attributed.
- Knobs (`slayperf.cfg`, or `SLAYPERF_<KEY>` env vars): `particles=on|half|off`, `spine_hz=N`
  (throttle Spine skeleton updates), `shaders=passthrough` (no-op every ShaderMaterial to measure shader cost),
  `preload_vfx=false` (skip VFX in the preload screens), `max_fps`.
- `share_saves=true` (default) keeps your normal save profile. Modded sessions otherwise use `modded/profileN`.
- Handles SIGTERM/SIGINT by running the game's own `NGame.Quit()` (saves progress). Without it the game
  ignores SIGTERM entirely.
- Harmony patches need `libgcc_s` loaded globally, because the exported Godot binaries link libgcc statically.
  SlayPerf does this before patching. Other Harmony mods on this port would hit the same error
  (`undefined symbol: _Unwind_RaiseException`).

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
atlas regions, Spine attachments and layouts are unaffected. Use `./deploy.sh lowres-off` to compare
against full-res textures. Very small scales (e.g. `--scale 0.01`) are useful as a "no textures"
diagnostic, but they break soft glows (they turn into offset solid rectangles).

### Launcher knobs
The settings menu covers the everyday options. For experiments, `Slay the Spire 2.sh` also reads
`perf.env` from the game dir, applied *after* the menu, so it wins (see `perf.env.example`): `SLAY_MODS=0` for a
vanilla baseline, `SLAY_GOVERNOR=performance`, `SLAY_DOTNET_TWEAKS=1`, and any `SLAYPERF_*` key.

Values in `perf.env` can't contain spaces (they're passed through westonwrap as `VAR=value` words).

The launcher no longer passes `--force-sentry off`. The game only checks whether that flag is present, so
it was turning Sentry on in debug mode, which logged and uploaded every warning.

### Testing on PC
The x86_64 export runs the same mods. Put them in `export/Linux-x86_64/mods/`, enable mods in
`settings.save` (`"mod_settings": {"mods_enabled": true}`) and run `./game --force-steam off`.

## Game versions
The port is built from one specific game build, recorded in [`game-version.json`](game-version.json)
together with checksums of the built port. Currently that's the Early Access main build recovered on
2026-05-02 (newest bundled patch notes: 2026-04-15). Newer builds (e.g. v0.107.1) haven't been tried.

- `repack.sh` prints the input PCK's version (from Steam's `release_info.json`). After a recovery it
  records it in `sts2-recover/.slaypatcher-source-release.json`, and it warns when you build from a
  PCK whose version differs from the recovered project.
- **Before moving to a new game build, save a snapshot.** `tools/snapshot.sh save` archives the
  recovered project and the built port (~5 GB compressed) into `snapshots/` (local, gitignored).
  `tools/snapshot.sh restore <name>` brings back exactly what was tested, without needing Steam.
- **Old builds from Steam:** `tools/fetch-game-build.sh <manifest-id>` downloads a specific build
  of depot 2868843 with your own account (DepotDownloader, or prints the `download_depot` command
  for Steam's built-in console). Manifest IDs per date are listed at
  https://steamdb.info/depot/2868843/manifests/. The tested build is manifest `5980382945911826237`
  (published 2026-04-17), so `tools/fetch-game-build.sh tested` downloads it.
- **Trying a new build side by side:** set `RECOVER_DIR` to recover it into a separate project and
  export somewhere else, leaving the tested build untouched:
  ```
  RECOVER_DIR=$PWD/sts2-recover-latest ./repack.sh /path/to/new/SlayTheSpire2.pck "Linux x86_64" export/latest-x86_64
  ```
  (`tools/build-fmod-arm64.sh` honours `RECOVER_DIR` too.)
- When moving to a new build, also rebuild the low-res PCK and re-run the FMOD build, re-test, then
  update `game-version.json`.

## Licensing
This repo only contains build scripts, tooling and the SlayPerf source. Nothing from the game, FMOD
or other proprietary SDKs is committed.

- **Slay the Spire 2** (game data, `sts2.pck`, the recovered `sts2-recover/` project) belongs to Mega
  Crit. You need your own copy. The port is built from your own Steam install.
- **FMOD Engine** is proprietary (Firelight Technologies, FMOD EULA). Each user downloads the SDK
  themselves from fmod.com. It is never fetched or committed by these scripts.
- **fmod-gdextension** (utopia-rise) and **godot-cpp** are MIT-licensed. They're cloned at build
  time, not vendored. `build-fmod-arm64.sh` applies two small local build patches.
- **Spine runtimes** are under the Spine Runtimes License (Esoteric Software). They're a git
  submodule, used as the game itself uses them.
- **Godot** export templates and editor binaries are downloaded at build time (MIT).

A built port folder (`slaythespire2/slaythespire2/` with `sts2.pck`, FMOD libraries and the
generated low-res PCK), `snapshots/` and `game-builds/` contain Mega Crit and Firelight material. Keep it for your own device and
**don't redistribute it** (that includes zipping it per `port.json`). Share the scripts instead.
