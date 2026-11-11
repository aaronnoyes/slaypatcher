# Performance notes

A running log of what was measured on the device, what changed, and why. Newest at the top.
CSV data comes from SlayPerf (`mods/slayperf/logs/`). Compare runs with `tools/perfreport.py`.

Device: H700 (4x Cortex-A53, Mali-G31 MP2), muOS, **973 MB RAM, no swap**. Display 640x480.

## Current state (paused 2026-11-10)

**On the device:** game installed at `/mnt/sdcard/ports/slaythespire2`, launcher in `/mnt/sdcard/ROMS/PORTS`.
Active mods: `slayperf` + `slaylowres` (scale 0.5). `slaytiny` (diagnostic) is parked in `mods-disabled/`.
`perf.env`: `SLAYPERF_LABEL=spine15fix-gc SLAYPERF_SPINE_HZ=15 SLAY_DOTNET_TWEAKS=1` (the recommended setup).

**Where it stands:** playable, mostly steady 30 FPS in combat. Hitches: ~19/min over 50 ms, ~4/min
over 100 ms. The 100 ms+ frames are the stutter you notice. First-time effects still freeze 2-10 s once
per install (shader compile, then cached).

**Not yet confirmed on device:** Select+Start quitting through the new launcher watcher. Each half was
tested separately (SIGTERM quits the real game cleanly; the watcher worked with stand-in processes).

**Next steps, roughly in order of expected payoff:**
1. Try the quit hotkey once.
2. `SLAY_GOVERNOR=performance`: the CPU drops to 288 MHz between bursts under `schedutil`, which
   likely feeds the 100 ms+ frames. Watch `temp_c` (already ~75 C).
3. Shader warm-up: instance every VFX scene off-screen on first launch (or during loading) so the
   2-10 s first-use freezes happen once, up front, instead of mid-fight.
4. `particles=half` and `preload_vfx=false` haven't been measured on device yet. On PC,
   `preload_vfx=false` cut the "Common" preload from 6.8 s to 0.5 s.
5. Find what the remaining 100 ms+ frames line up with. The CSV only has 1 s granularity, so a
   per-frame log of hitch frames (with the active scene/action) would help.
6. Updating to a current game build means a full re-port (repack.sh) **and** rebuilding the
   low-res PCK (see the version caveat below).

**Tooling notes for picking this back up:** `./deploy.sh pull` then `tools/perfreport.py` on
`device-logs/**/*.csv`. muOS SSH is `root`/`root`, and device paths are as above. For live viewing,
`tail -F` the newest CSV in `mods/slayperf/logs/` over SSH.

## 2026-11-10: fixed Spine throttle + .NET GC tweak (lowres + spine_hz=15 + SLAY_DOTNET_TWEAKS=1)

Combat period only (t > 60 s). The spine15fix-gc sample is short (~2 min).

| | spine15 | spine15fix-gc |
|---|---|---|
| hitches (>50 ms) per minute | 59 | 19 |
| frames >100 ms per minute | 5.8 | 3.6 |
| GC pause per minute | 572 ms | 138 ms |
| gen0 GCs (session) | 172 | 10 |

- The GC tweak works as intended: gen0 collections nearly disappear and small hitches drop by 2/3.
- Subjectively it "felt the same". The noticeable stutter is probably the >100 ms frames, which
  fell much less. Those are the next target. Candidates: first-use shader compiles that are still
  uncached, the schedutil governor ramping up from 288 MHz, and per-turn work in game code.
- **Quit hotkey, properly diagnosed:** the hotkey is Select+Start (Menu+Start does nothing). gptokeyb2
  with `-X` exits on it, but westonwrap only checks gptokeyb at *startup*, so nothing stopped the game.
  It kept running with no input device ("frozen, animations still playing"). The launcher now watches
  gptokeyb and sends the game SIGTERM when it exits, escalating to SIGKILL after 10 s. Verified on
  device: a plain SIGTERM makes SlayPerf run `NGame.Quit()` and progress is saved. The watcher was
  tested on the device's shell with stand-in processes. The full hotkey path still needs a real try.

## 2026-11-10: Spine throttle (lowres + spine_hz=15)

| | lowres | lowres + spine15 |
|---|---|---|
| hitches (>50 ms) per minute | ~73 | ~61 |
| 17-18 FPS dips in combat | recurring | gone; steady 30 with single 50-135 ms frames |
| median draw calls | 335 | 253 |
| GC pause total | 2.9 s / 6.4 min | 2.4 s / 3.6 min |

- Spine CPU skinning caused the sustained dips. Throttling to 15 Hz removed them.
- The first throttle version had two bugs: float slack (2 x 33.33 ms < 1/15 s, so it really ran at
  10 Hz) and every sprite updating on the same frame. Fixed with a 4 ms slack and golden-ratio phase
  offsets. Verified on PC: 3 sprites at exactly 45 updates/s.
- About half the remaining hitch seconds coincide with a GC pause over 5 ms. The CPU also falls to
  288 MHz between bursts under `schedutil`, and temperature reached 75 C.
- Next runs: `SLAY_DOTNET_TWEAKS=1` (fewer gen0 GCs), then `SLAY_GOVERNOR=performance`.
- Menu+Start didn't quit: the game ignores SIGTERM (the embedded .NET runtime takes over the signal
  and never exits). gptokeyb2 sent it, then exited itself, taking its virtual controller with it, so
  the game kept running with no input and looked frozen. SlayPerf now handles SIGTERM/SIGINT by
  calling the game's own `NGame.Quit()` (saves settings and progress), with a SIGKILL fallback after 5 s.
  On PC, SIGTERM at the main menu now exits in 1.2 s. Before, it never exited. (This alone wasn't enough:
  see the next entry.)

### Game version caveat
This port is built from a months-old game build. The lowres PCK overrides `.ctex` files by path, and
Godot names imported textures by *source path*, not content. A lowres PCK built from an old version
would quietly replace updated art with old art (and old logical sizes). Rebuild it whenever the game
PCK changes. The SlayPerf patches are each wrapped in try/catch, and the node-level knobs don't
depend on game internals.

## 2026-11-10: first measured runs

Same route each run: boot, main menu, continue the Ironclad run, first combat.

| | baseline | tiny textures (diagnostic) | lowres (scale 0.5) |
|---|---|---|---|
| time to main menu | 47.9 s | 35.7 s | 27.2 s |
| texture memory in combat | 360 MB | 53 MB | 102 MB |
| available RAM in combat | ~80 MB | ~345 MB | ~323 MB |
| combat FPS | ~0.1 (one frame per ~10 s) | 30 steady | 30, dipping to 17-18 |
| iowait in combat | 30-55 % | ~0 | ~0 |
| major page faults/s in combat | 20-40 | ~0 | ~0 |

### Findings
1. **Main problem: texture memory.** The baseline sits at ~795 MB RSS with ~80 MB free. With no
   swap, the kernel evicts file-backed pages (game code, PCK data) and re-reads them from the SD
   card constantly. In the CSVs that shows as low CPU, high iowait and a steady stream of major faults.
   The CPU governor then drops to 288 MHz because the CPU is mostly idle. Shrinking textures removes it.
2. **First-use freezes are shader compilation**, 2-10 s each, at ~100 % of one core with no iowait,
   when an effect first appears (e.g. the first Strike or Tremble). Repeats are instant. Godot keeps a
   persistent cache in `conf/SlayTheSpire2/shader_cache`, so each one happens once per install.
   Fix idea: warm the cache by instancing every VFX scene off-screen on first launch.
3. **Remaining stutter with lowres:** recurring dips to 17-18 FPS (~55 ms frames), CPU-bound, no
   I/O. Suspects in order: Spine CPU skinning, particles. Next runs: `spine_hz=15`, `particles=half`.
4. On PC, skipping VFX preloading cut the "Common" preload from 6.8 s to 0.5 s. Not yet tried on device.

### Changes and why
- **Launcher no longer passes `--force-sentry off`.** The game only checks that the flag exists, so it
  forced Sentry on in debug mode (~2k debug lines per session plus uploads).
- **SlayPerf mod** (`perfmod/`): CSV sampler (own thread, so it keeps logging through stalls) and
  independent knobs to isolate costs. HUD is off by default; the CSV is read remotely.
  Harmony needed `libgcc_s` loaded globally (the Godot binaries link libgcc statically).
- **SlayLowRes** (`tools/make-lowres.sh`): override PCK that shrinks texture payloads but keeps the
  logical size in the `.ctex` header, so layouts are unaffected. Lossless textures become ASTC.
  3.8 GB to 433 MB if everything were resident. The tiny variant (`--scale 0.01`) was only a diagnostic
  and causes visible artifacts (glows turn into offset solid rectangles).
- **deploy.sh**: install, push, toggle mods, set per-run env, pull logs and take screenshots over SSH,
  so no SD card swapping.

### Open issues
- Select+Start quit: launcher watcher + SlayPerf SIGTERM handler, needs one real try on device.
- Audio: FMOD has no arm64 build, so there's still no music.
