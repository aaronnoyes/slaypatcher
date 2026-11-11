using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using Godot;
using MegaCrit.Sts2.Core.Logging;

namespace SlayPerf;

/// <summary>
/// Frame timing + Godot render stats (main thread) and Linux memory/swap/CPU/thermal stats
/// (background thread). The background sampler keeps logging while the main thread is
/// blocked in a long load, which is exactly when we want to know whether we're swapping,
/// waiting on the SD card, or burning CPU.
/// </summary>
internal sealed class PerfMonitor
{
    private readonly Config _cfg;
    private readonly NodeTweaks _tweaks;
    private readonly SpineThrottle? _spine;
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly object _lock = new();
    private readonly ConcurrentQueue<string> _events = new();

    // Frame stats for the current CSV interval (guarded by _lock).
    private int _frames;
    private double _frameMsSum, _frameMsMax;
    private int _hitches;

    private long _lastFrameTicks;
    private double _hudTimer;

    // Latest main-thread snapshot (guarded by _lock).
    private double _fps, _drawCalls, _objectsDrawn, _texMemMb, _vidMemMb, _nodes, _objects;

    // Latest system snapshot (written by sampler thread, read by HUD).
    private volatile string _sysHud = "";

    private Label? _label;
    private StreamWriter? _csv;

    // Per-hitch log: one line per slow frame with what changed during it, so the
    // remaining stutter can be attributed (GC? scene instancing? low clocks? game action?).
    private readonly SceneTree _tree;
    private readonly ConcurrentQueue<string> _hitchLines = new();
    private StreamWriter? _hitchCsv;
    private volatile string _lastGameLog = "";
    private volatile int _cpuMhz = -1;
    private int _lastGen0, _lastGen2;
    private long _lastNodeCount;

    public PerfMonitor(Config cfg, SceneTree tree, NodeTweaks tweaks, SpineThrottle? spine)
    {
        _cfg = cfg;
        _tweaks = tweaks;
        _spine = spine;
        _tree = tree;
        _lastFrameTicks = _clock.ElapsedTicks;

        Log.LogCallback += OnGameLog;

        if (cfg.Hud) CreateHud(tree);
        if (cfg.Csv) OpenCsv();

        var t = new Thread(SamplerLoop) { IsBackground = true, Name = "slayperf-sampler", Priority = ThreadPriority.BelowNormal };
        t.Start();
    }

    public void MarkEvent(string text) => _events.Enqueue(text);

    private void OnGameLog(LogLevel level, string message, int skipFrames)
    {
        _lastGameLog = message.Length > 140 ? message[..140] : message;
        // Phase markers so CSV rows line up with what the game was doing.
        if (message.StartsWith("Preloading '", StringComparison.Ordinal) ||
            message.StartsWith("[Startup] Time to main menu:", StringComparison.Ordinal) ||
            message.StartsWith("Loading Godot PCK", StringComparison.Ordinal))
        {
            _events.Enqueue(message);
        }
    }

    // ---------------------------------------------------------------- main thread

    public void Tick(double delta)
    {
        long now = _clock.ElapsedTicks;
        double ms = (now - Interlocked.Exchange(ref _lastFrameTicks, now)) * 1000.0 / Stopwatch.Frequency;

        lock (_lock)
        {
            _frames++;
            _frameMsSum += ms;
            if (ms > _frameMsMax) _frameMsMax = ms;
            if (ms > _cfg.HitchMs) _hitches++;
        }

        int gen0 = GC.CollectionCount(0), gen2 = GC.CollectionCount(2);
        long nodes = _tree.GetNodeCount();
        if (_cfg.HitchLogMs > 0 && ms > _cfg.HitchLogMs && _hitchCsv != null)
        {
            _hitchLines.Enqueue(string.Join(",",
                (_clock.Elapsed.TotalSeconds).ToString("0.00", CultureInfo.InvariantCulture),
                ms.ToString("0", CultureInfo.InvariantCulture),
                gen0 - _lastGen0, gen2 - _lastGen2, nodes - _lastNodeCount,
                _spine?.UpdatesLastFrame ?? 0, _cpuMhz,
                "\"" + _lastGameLog.Replace("\"", "'").Replace("\n", " ") + "\""));
        }
        _lastGen0 = gen0;
        _lastGen2 = gen2;
        _lastNodeCount = nodes;

        _hudTimer += delta;
        if (_hudTimer < 0.5) return;
        _hudTimer = 0;

        lock (_lock)
        {
            _fps = Performance.GetMonitor(Performance.Monitor.TimeFps);
            _drawCalls = Performance.GetMonitor(Performance.Monitor.RenderTotalDrawCallsInFrame);
            _objectsDrawn = Performance.GetMonitor(Performance.Monitor.RenderTotalObjectsInFrame);
            _texMemMb = Performance.GetMonitor(Performance.Monitor.RenderTextureMemUsed) / 1048576.0;
            _vidMemMb = Performance.GetMonitor(Performance.Monitor.RenderVideoMemUsed) / 1048576.0;
            _nodes = Performance.GetMonitor(Performance.Monitor.ObjectNodeCount);
            _objects = Performance.GetMonitor(Performance.Monitor.ObjectCount);
        }

        if (_label != null && GodotObject.IsInstanceValid(_label))
        {
            _label.Text =
                $"FPS {_fps:0} | {ms:0}ms | draws {_drawCalls:0} | tex {_texMemMb:0}MB vid {_vidMemMb:0}MB | nodes {_nodes:0}\n" +
                _sysHud +
                $"\nspine {(_spine != null ? $"{_spine.Count}@{_cfg.SpineHz}Hz" : $"{_tweaks.SpineSeen} unthrottled")}" +
                $" | particles {_cfg.Particles.ToString().ToLowerInvariant()} ({_tweaks.GpuParticlesSeen}g/{_tweaks.CpuParticlesSeen}c)" +
                $" | shaders {_cfg.Shaders.ToString().ToLowerInvariant()}" +
                (_cfg.Label.Length > 0 ? $" | {_cfg.Label}" : "");
        }
    }

    private void CreateHud(SceneTree tree)
    {
        var layer = new CanvasLayer { Layer = 128, Name = "SlayPerfHud" };
        _label = new Label
        {
            Name = "SlayPerfLabel",
            Position = new Vector2(8, 4),
            MouseFilter = Control.MouseFilterEnum.Ignore,
        };
        // Base viewport is 1920x1080, so sizes are in those units.
        _label.AddThemeFontSizeOverride("font_size", 26);
        _label.AddThemeColorOverride("font_color", new Color(0.6f, 1f, 0.6f));
        _label.AddThemeColorOverride("font_outline_color", Colors.Black);
        _label.AddThemeConstantOverride("outline_size", 6);
        layer.AddChild(_label);
        tree.Root.CallDeferred(Node.MethodName.AddChild, layer);
    }

    // ---------------------------------------------------------------- CSV / sampler thread

    private void OpenCsv()
    {
        try
        {
            string dir = _cfg.CsvDir.Length > 0 ? _cfg.CsvDir : Path.Combine(SlayPerfMod.ModDir, "logs");
            Directory.CreateDirectory(dir);
            string tag = new string(_cfg.Label.Select(c => char.IsLetterOrDigit(c) || c == '-' ? c : '_').ToArray());
            string stem = $"perf-{DateTime.Now:yyyyMMdd-HHmmss}{(tag.Length > 0 ? "-" + tag : "")}";
            string path = Path.Combine(dir, stem + ".csv");
            for (int i = 1; File.Exists(path); i++) path = Path.Combine(dir, $"{stem}-{i}.csv");

            _csv = new StreamWriter(path, false, new UTF8Encoding(false)) { AutoFlush = true };
            _csv.WriteLine($"# slayperf {DateTime.Now:O} {_cfg.Describe()}");
            _csv.WriteLine(string.Join(",", Columns));

            if (_cfg.HitchLogMs > 0)
            {
                _hitchCsv = new StreamWriter(Path.ChangeExtension(path, null) + "-hitches.csv", false, new UTF8Encoding(false)) { AutoFlush = true };
                _hitchCsv.WriteLine($"# frames slower than {_cfg.HitchLogMs} ms. gc0/gc2/node_delta/spine_updates are what changed during that frame; last_log is the game's most recent log line");
                _hitchCsv.WriteLine("t_s,frame_ms,gc0,gc2,node_delta,spine_updates,cpu_mhz,last_log");
            }
            SlayPerfMod.Log($"writing perf csv to {path}");
        }
        catch (Exception ex)
        {
            SlayPerfMod.Log($"could not open csv: {ex.Message}");
            _csv = null;
        }
    }

    private static readonly string[] Columns =
    {
        "t_s", "frames", "fps", "frame_ms_avg", "frame_ms_max", "hitches", "stall_ms",
        "draw_calls", "objects_drawn", "tex_mem_mb", "vid_mem_mb", "nodes", "objects",
        "managed_mb", "gc_pause_ms", "gc0", "gc1", "gc2",
        "rss_mb", "proc_swap_mb", "mem_avail_mb", "swap_used_mb", "swapin_pages", "swapout_pages", "major_faults",
        "proc_cpu_pct", "sys_busy_pct", "iowait_pct", "cpu_mhz", "gpu_mhz", "temp_c",
        "spine_active", "spine_updates", "event",
    };

    private void SamplerLoop()
    {
        var prev = SysStats.Read();
        double prevGcPause = GC.GetTotalPauseDuration().TotalMilliseconds;
        long prevSpine = 0;
        int intervalMs = (int)(_cfg.SampleInterval * 1000);

        while (true)
        {
            Thread.Sleep(intervalMs);
            try
            {
                var cur = SysStats.Read();
                _cpuMhz = cur.CpuKhz < 0 ? -1 : (int)(cur.CpuKhz / 1000);
                while (_hitchLines.TryDequeue(out string? h)) _hitchCsv?.WriteLine(h);
                double dt = Math.Max(1e-3, (cur.WallTicks - prev.WallTicks) / (double)Stopwatch.Frequency);

                int frames; double avg, max; int hitches;
                double fps, dc, od, tex, vid, nodes, objs;
                lock (_lock)
                {
                    frames = _frames;
                    avg = _frames > 0 ? _frameMsSum / _frames : 0;
                    max = _frameMsMax;
                    hitches = _hitches;
                    _frames = 0; _frameMsSum = 0; _frameMsMax = 0; _hitches = 0;
                    fps = _fps; dc = _drawCalls; od = _objectsDrawn; tex = _texMemMb; vid = _vidMemMb; nodes = _nodes; objs = _objects;
                }
                double stall = (_clock.ElapsedTicks - Interlocked.Read(ref _lastFrameTicks)) * 1000.0 / Stopwatch.Frequency;
                double gcPause = GC.GetTotalPauseDuration().TotalMilliseconds;

                long cpuTotal = cur.CpuTotal - prev.CpuTotal;
                double busy = cpuTotal > 0 ? 100.0 * (cpuTotal - (cur.CpuIdle - prev.CpuIdle) - (cur.CpuIowait - prev.CpuIowait)) / cpuTotal : -1;
                double iowait = cpuTotal > 0 ? 100.0 * (cur.CpuIowait - prev.CpuIowait) / cpuTotal : -1;
                double procCpu = cur.ProcTicks >= 0 ? 100.0 * (cur.ProcTicks - prev.ProcTicks) / SysStats.ClockTicksPerSecond / dt : -1;
                double swapUsed = cur.SwapTotalKb >= 0 ? (cur.SwapTotalKb - cur.SwapFreeKb) / 1024.0 : -1;

                var ev = new StringBuilder();
                while (_events.TryDequeue(out string? e))
                {
                    if (ev.Length > 0) ev.Append(" | ");
                    ev.Append(e);
                }

                _sysHud =
                    $"RSS {cur.RssKb / 1024.0:0}MB | avail {cur.MemAvailKb / 1024.0:0}MB | swap {swapUsed:0}MB" +
                    $" (+{cur.SwapIn - prev.SwapIn}/-{cur.SwapOut - prev.SwapOut}pg)" +
                    $" | cpu {procCpu:0}% io {iowait:0}% | {cur.CpuKhz / 1000}MHz {cur.TempMilliC / 1000.0:0}C";

                if (_csv == null) continue;
                var row = new object[]
                {
                    _clock.Elapsed.TotalSeconds, frames, fps, avg, max, hitches, stall,
                    dc, od, tex, vid, nodes, objs,
                    GC.GetTotalMemory(false) / 1048576.0, gcPause - prevGcPause,
                    GC.CollectionCount(0), GC.CollectionCount(1), GC.CollectionCount(2),
                    cur.RssKb / 1024.0, cur.ProcSwapKb / 1024.0, cur.MemAvailKb / 1024.0, swapUsed,
                    cur.SwapIn - prev.SwapIn, cur.SwapOut - prev.SwapOut, cur.MajFault - prev.MajFault,
                    procCpu, busy, iowait, Scaled(cur.CpuKhz, 1e3), Scaled(cur.GpuHz, 1e6), Scaled(cur.TempMilliC, 1e3),
                    _spine?.Count ?? 0, (_spine?.TotalUpdates ?? 0) - prevSpine, ev.ToString(),
                };
                _csv.WriteLine(string.Join(",", row.Select(Fmt)));

                prev = cur;
                prevGcPause = gcPause;
                prevSpine = _spine?.TotalUpdates ?? 0;
            }
            catch (Exception ex)
            {
                SlayPerfMod.Log($"sampler error: {ex.Message}");
                Thread.Sleep(5000);
            }
        }
    }

    private static double Scaled(long v, double div) => v < 0 ? -1 : v / div;

    private static string Fmt(object o) => o switch
    {
        double d => d.ToString("0.##", CultureInfo.InvariantCulture),
        string s => s.Length == 0 ? "" : "\"" + s.Replace("\"", "'") + "\"",
        _ => Convert.ToString(o, CultureInfo.InvariantCulture) ?? "",
    };
}

/// <summary>Raw counters from /proc and /sys. Missing files (e.g. on a PC) read as -1.</summary>
internal readonly struct SysStats
{
    public const double ClockTicksPerSecond = 100.0; // USER_HZ, 100 on every arm64/x86 Linux we care about

    public long WallTicks { get; init; }
    public long RssKb { get; init; }
    public long ProcSwapKb { get; init; }
    public long MemAvailKb { get; init; }
    public long SwapTotalKb { get; init; }
    public long SwapFreeKb { get; init; }
    public long SwapIn { get; init; }
    public long SwapOut { get; init; }
    public long MajFault { get; init; }
    public long ProcTicks { get; init; }
    public long CpuTotal { get; init; }
    public long CpuIdle { get; init; }
    public long CpuIowait { get; init; }
    public long CpuKhz { get; init; }
    public long GpuHz { get; init; }
    public long TempMilliC { get; init; }

    private static string? _gpuFreqPath;
    private static bool _gpuSearched;

    public static SysStats Read()
    {
        string status = ReadText("/proc/self/status");
        string meminfo = ReadText("/proc/meminfo");
        string vmstat = ReadText("/proc/vmstat");

        long cpuTotal = -1, cpuIdle = -1, cpuIowait = -1;
        string stat = ReadText("/proc/stat");
        if (stat.StartsWith("cpu ", StringComparison.Ordinal))
        {
            long[] f = stat[..stat.IndexOf('\n')].Split(' ', StringSplitOptions.RemoveEmptyEntries).Skip(1).Select(long.Parse).ToArray();
            cpuTotal = f.Take(8).Sum();
            cpuIdle = f[3];
            cpuIowait = f.Length > 4 ? f[4] : 0;
        }

        long procTicks = -1;
        string pstat = ReadText("/proc/self/stat");
        int rp = pstat.LastIndexOf(')');
        if (rp > 0)
        {
            string[] f = pstat[(rp + 2)..].Split(' ');
            // fields after ")" start at field 3 (state); utime=14, stime=15
            if (f.Length > 12) procTicks = long.Parse(f[11]) + long.Parse(f[12]);
        }

        if (!_gpuSearched)
        {
            _gpuSearched = true;
            try
            {
                _gpuFreqPath = Directory.Exists("/sys/class/devfreq")
                    ? Directory.GetDirectories("/sys/class/devfreq")
                        .Where(d => d.Contains("gpu", StringComparison.OrdinalIgnoreCase))
                        .Select(d => Path.Combine(d, "cur_freq")).FirstOrDefault(File.Exists)
                    : null;
            }
            catch { _gpuFreqPath = null; }
        }

        return new SysStats
        {
            WallTicks = Stopwatch.GetTimestamp(),
            RssKb = Field(status, "VmRSS:"),
            ProcSwapKb = Field(status, "VmSwap:"),
            MemAvailKb = Field(meminfo, "MemAvailable:"),
            SwapTotalKb = Field(meminfo, "SwapTotal:"),
            SwapFreeKb = Field(meminfo, "SwapFree:"),
            SwapIn = Field(vmstat, "pswpin "),
            SwapOut = Field(vmstat, "pswpout "),
            MajFault = Field(vmstat, "pgmajfault "),
            ProcTicks = procTicks,
            CpuTotal = cpuTotal,
            CpuIdle = cpuIdle,
            CpuIowait = cpuIowait,
            CpuKhz = ReadLong("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"),
            GpuHz = _gpuFreqPath != null ? ReadLong(_gpuFreqPath) : -1,
            TempMilliC = ReadLong("/sys/class/thermal/thermal_zone0/temp"),
        };
    }

    private static string ReadText(string path)
    {
        try { return File.ReadAllText(path); }
        catch { return ""; }
    }

    private static long ReadLong(string path) =>
        long.TryParse(ReadText(path).Trim(), out long v) ? v : -1;

    private static long Field(string text, string key)
    {
        int i = text.StartsWith(key, StringComparison.Ordinal) ? 0 : text.IndexOf("\n" + key, StringComparison.Ordinal);
        if (i < 0) return -1;
        if (text[i] == '\n') i++;
        i += key.Length;
        while (i < text.Length && (text[i] == ' ' || text[i] == '\t')) i++;
        int j = i;
        while (j < text.Length && char.IsAsciiDigit(text[j])) j++;
        return j > i ? long.Parse(text.AsSpan(i, j - i)) : -1;
    }
}
