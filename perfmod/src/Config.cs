using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace SlayPerf;

public enum ParticleMode { On, Half, Off }
public enum ShaderMode { On, Passthrough }

/// <summary>
/// key=value config read from slayperf.cfg next to the DLL. Every key can be
/// overridden by an environment variable SLAYPERF_&lt;KEY&gt; (e.g. SLAYPERF_PARTICLES=off),
/// so the launcher script can flip knobs without editing files on the SD card.
/// </summary>
public sealed class Config
{
    public string Label = "";
    public bool Hud;
    public bool Csv = true;
    public string CsvDir = "";
    public double SampleInterval = 1.0;
    public double HitchMs = 50;

    public ParticleMode Particles = ParticleMode.On;
    public int SpineHz;
    public ShaderMode Shaders = ShaderMode.On;
    public bool PreloadVfx = true;
    public int MaxFps;
    public bool ShareSaves = true;

    private readonly Dictionary<string, string> _raw = new();

    public static Config Load(string path)
    {
        var cfg = new Config();
        if (File.Exists(path))
        {
            foreach (string line in File.ReadAllLines(path))
            {
                string t = line.Trim();
                if (t.Length == 0 || t[0] == '#' || t[0] == ';') continue;
                int eq = t.IndexOf('=');
                if (eq <= 0) continue;
                string key = t[..eq].Trim().ToLowerInvariant();
                string val = t[(eq + 1)..];
                int hash = val.IndexOf(" #", StringComparison.Ordinal);
                if (hash >= 0) val = val[..hash];
                cfg._raw[key] = val.Trim();
            }
        }
        foreach (string key in Keys)
        {
            string? env = Environment.GetEnvironmentVariable("SLAYPERF_" + key.ToUpperInvariant());
            if (!string.IsNullOrEmpty(env)) cfg._raw[key] = env.Trim();
        }
        cfg.Apply();
        return cfg;
    }

    private static readonly string[] Keys =
    {
        "label", "hud", "csv", "csv_dir", "sample_interval", "hitch_ms",
        "particles", "spine_hz", "shaders", "preload_vfx", "max_fps", "share_saves",
    };

    private void Apply()
    {
        Label = Str("label", Label);
        Hud = Bool("hud", Hud);
        Csv = Bool("csv", Csv);
        CsvDir = Str("csv_dir", CsvDir);
        SampleInterval = Math.Max(0.1, Num("sample_interval", SampleInterval));
        HitchMs = Num("hitch_ms", HitchMs);
        Particles = Str("particles", "on").ToLowerInvariant() switch
        {
            "off" or "0" or "false" => ParticleMode.Off,
            "half" => ParticleMode.Half,
            _ => ParticleMode.On,
        };
        SpineHz = Math.Max(0, (int)Num("spine_hz", SpineHz));
        Shaders = Str("shaders", "on").ToLowerInvariant() is "passthrough" or "off" ? ShaderMode.Passthrough : ShaderMode.On;
        PreloadVfx = Bool("preload_vfx", PreloadVfx);
        MaxFps = Math.Max(0, (int)Num("max_fps", MaxFps));
        ShareSaves = Bool("share_saves", ShareSaves);
    }

    /// <summary>One-line summary written into the log and at the top of every CSV.</summary>
    public string Describe() =>
        $"label={Label} particles={Particles.ToString().ToLowerInvariant()} spine_hz={SpineHz} " +
        $"shaders={Shaders.ToString().ToLowerInvariant()} preload_vfx={PreloadVfx} max_fps={MaxFps} " +
        $"share_saves={ShareSaves} hud={Hud}";

    private string Str(string k, string d) => _raw.TryGetValue(k, out var v) ? v : d;

    private bool Bool(string k, bool d) =>
        _raw.TryGetValue(k, out var v)
            ? v.ToLowerInvariant() is "1" or "true" or "yes" or "on"
            : d;

    private double Num(string k, double d) =>
        _raw.TryGetValue(k, out var v) && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) ? n : d;

    public IEnumerable<string> UnknownKeys() => _raw.Keys.Where(k => !Keys.Contains(k));
}
