# Performance notes

A running log of what was measured on the device, what changed, and why. Newest at the top.
CSV data comes from SlayPerf (`mods/slayperf/logs/`). Compare runs with `tools/perfreport.py`.

Device: H700 (4x Cortex-A53, Mali-G31 MP2), muOS, **973 MB RAM, no swap**. Display 640x480.

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
  On PC, SIGTERM at the main menu now exits in 1.2 s. Before, it never exited.

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
- Menu+Start quit: fixed via SlayPerf's SIGTERM handler, needs confirming on device.
- Audio: FMOD has no arm64 build, so there's still no music.
