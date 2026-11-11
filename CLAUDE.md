# CLAUDE.md

Ports Slay the Spire 2 (Godot 4.5.1 + C#/.NET 9 + Spine) to arm64 handhelds via PortMaster, and
makes it run acceptably on an H700 (4x A53, Mali-G31, 973 MB RAM, **no swap**, 640x480).

**Read first:** `PERF_NOTES.md` ("Current state" at the top) for where the performance work stands
and what to test next. `README.md` has user-facing usage.

## Layout
- `repack.sh`: full port build. Recovers the Steam PCK with gdsdecomp into `sts2-recover/` (gitignored,
  decompiled game source), cross-builds Spine for arm64, re-imports textures as ETC2/ASTC and exports
  to `slaythespire2/slaythespire2/` (`sts2`, `sts2.pck`). Slow: avoid re-running it to iterate.
- `slaythespire2/Slay the Spire 2.sh`: PortMaster launcher. Order: settings menu (LÖVE app in
  `slaythespire2/slaythespire2/launcher/`, keys via `launcher.gptk`) -> parse its `settings.cfg`
  (whitelisted keys only) -> `perf.env` overrides -> low-res folder toggle -> Weston + game + quit watcher.
  The menu exits 0 to launch, non-zero to back out. Test its logic headlessly with `luajit` and a
  stubbed `love` table. Its help text quotes measured numbers: update it when PERF_NOTES changes.
- `slaythespire2/slaythespire2/`: the device game folder. Build outputs and `mods/` are gitignored.
- `perfmod/`: **SlayPerf** C# mod (DLL, loaded by the game's own mod loader). CSV + hitch logging,
  perf knobs, SIGTERM-to-clean-quit, save-profile patch. `perfmod/build.sh` builds it into `mods/slayperf/`.
- `tools/lowres/lowres.gd` + `tools/make-lowres.sh`: builds `mods/slaylowres/` (texture override PCK).
- `tools/perfreport.py`: compares SlayPerf CSVs side by side. `tools/fb2png.py`: framebuffer screenshots.
- `tools/build-fmod-arm64.sh`: cross-builds fmod-gdextension 6.1.0 for Linux arm64 against the FMOD
  2.03.06 Linux SDK (user-supplied, needs an fmod.com login; never fetch it from elsewhere) and adds
  `linux.*.arm64` entries to `sts2-recover/addons/fmod/fmod.gdextension`. Clone and SDK are gitignored.
  The script patches upstream for arm64: adds a missing `<cstdio>` include and makes the `-m64`/gold
  link flags x86_64-only.
- `deploy.sh`: everything device-side over SSH (install, mod, lowres on/off, perfenv, shot, pull).
- `export/Linux-x86_64/`: x86_64 build of the same game for PC testing (gitignored). Mods go in
  `export/Linux-x86_64/mods/`. Run headless with `XDG_DATA_HOME=<scratch>` so real saves aren't touched.

## How mods work here
The game scans `<exe dir>/mods/**/<id>.json` and loads `<id>.dll` (into the game's ALC; calls the
`[ModInitializer]` method, otherwise `Harmony.PatchAll`) and `<id>.pck` (`LoadResourcePack`, replaces
files). Mods load in `OneTimeInitialization.ExecuteVeryEarly`, before atlases or the main menu.
Mods only load if `settings.save` has `"mod_settings": {"mods_enabled": true}` (the launcher sets it).
**Any `.json` in a mod folder is treated as a manifest**, so reports go in `.txt`.

## Workflow
- Iterate with mods, not re-exports: `./perfmod/build.sh && ./deploy.sh mod` pushes ~35 KB.
- The device's `perf.env` overrides the settings menu. Clear it (`./deploy.sh perfenv`) when done
  experimenting, or the menu appears to do nothing.
- Experiments: **one knob per run**, set with `./deploy.sh perfenv SLAYPERF_LABEL=<name> ...`, same
  route each run (boot, continue the Ironclad run, first combat). Then `./deploy.sh pull` and compare
  with `tools/perfreport.py`. Record results in `PERF_NOTES.md` (newest first) and update its
  "Current state". Update README's "Recommended setup" when a knob earns a place.
- Test C# changes on PC headless first (catches load/patch errors). Real performance only means
  something on the device.
- Commits: explain *why*, with the measured numbers. Keep docs in sync in the same commit.

## Device access
muOS SSH: `root`/`root` (Configuration > Web Services). Ask the user for the IP; don't commit it.
No key auth is set up. Use `SSH_ASKPASS` with a throwaway script, plus a ControlMaster connection
(ControlPath must be under ~100 chars: use `/tmp/claude-1000/ssh/cm-%h`). Pass it to deploy.sh via
`SSH_OPTS="-o ControlPath=..."`. Paths: game `/mnt/sdcard/ports/slaythespire2`, launchers
`/mnt/sdcard/ROMS/PORTS`, PortMaster `/mnt/mmc/MUOS/PortMaster`. Device shell is busybox (+bash).
Don't launch the game over SSH; the user starts it from the Ports menu.

## Gotchas (all hit for real)
- `--force-sentry <anything>` forces Sentry ON in debug mode (the game only checks the flag exists).
- The game ignores SIGTERM unless SlayPerf is loaded. The quit hotkey is **Select+Start**: gptokeyb2
  `-X` exits on it, and the launcher's watcher then SIGTERMs the game. westonwrap does not do this.
- Killing the game with `kill -9` over SSH often drops the SSH session during launcher cleanup. Reconnect.
- busybox `pgrep -x sts2` doesn't match. Find the PID via `/proc/*/comm` or `ps | grep`.
- Harmony needs `libgcc_s` dlopen'ed with RTLD_GLOBAL (Godot binaries link libgcc statically).
- In the mod, `Environment` is ambiguous (Godot vs System). Use `System.Environment`.
- `perfmod/build.sh | tail -1` hides build failures (an old DLL gets deployed). Grep for `error|Built`.
- GDExtensions (FMOD, Spine, Sentry) load at engine start, before mods, so native-library changes
  always need a re-export (`rm slaythespire2/slaythespire2/sts2 && ./repack.sh <pck>` re-runs just the export).
- A low-res PCK is tied to the game build it was made from (ctex names come from source paths, not
  content). Rebuild it after any game update.
- The GPU is the Mali blob driver (GLES 3.2, compatibility renderer). ASTC and ETC2 are both supported.
  Shader compiles are slow, but they're cached in `conf/SlayTheSpire2/shader_cache`.
- Godot GDScript tools: `WorkerThreadPool.wait_for_group_task_completion`, `Image.compress_from_channels`,
  and don't name a SceneTree script method `_process`.
- Licensing: never commit or redistribute game data, the FMOD SDK/libraries or anything derived from them
  (built port folder, low-res PCK). Only scripts and our own source go in git. See README "Licensing".
- The user's own data never goes into commits (device IP, Tailscale names, `log.txt`, `device-logs/`).
