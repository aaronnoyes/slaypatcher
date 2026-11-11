using System;
using System.IO;
using Godot;
using MegaCrit.Sts2.Core.Modding;

namespace SlayPerf;

[ModInitializer(nameof(Init))]
public static class SlayPerfMod
{
    public static string ModDir { get; private set; } = ".";
    public static Config Cfg { get; private set; } = new();

    private static PerfMonitor? _monitor;
    private static SpineThrottle? _spine;
    private static NodeTweaks? _tweaks;
    private static SceneTree? _tree;

    public static void Log(string msg) => GD.Print("[SlayPerf] " + msg);

    // Called by the game's ModManager very early in NGame startup, before atlases and the
    // main menu load.
    public static void Init()
    {
        ModDir = Path.GetDirectoryName(typeof(SlayPerfMod).Assembly.Location) ?? ".";
        Cfg = Config.Load(Path.Combine(ModDir, "slayperf.cfg"));
        Log("config: " + Cfg.Describe());
        foreach (string k in Cfg.UnknownKeys()) Log($"warning: unknown config key '{k}'");

        Patches.Apply(Cfg);

        _tree = (SceneTree)Engine.GetMainLoop();
        _spine = Cfg.SpineHz > 0 ? new SpineThrottle(Cfg.SpineHz) : null;
        _tweaks = new NodeTweaks(Cfg, _spine);
        _tree.NodeAdded += _tweaks.OnNodeAdded;
        _tweaks.ApplyRecursive(_tree.Root);

        _monitor = new PerfMonitor(Cfg, _tree, _tweaks, _spine);
        _tree.ProcessFrame += OnProcessFrame;
    }

    private static void OnProcessFrame()
    {
        try
        {
            double delta = _tree!.Root.GetProcessDeltaTime();
            _spine?.Tick(delta);
            _monitor?.Tick(delta);
            if (Cfg.MaxFps > 0 && Engine.MaxFps != Cfg.MaxFps) Engine.MaxFps = Cfg.MaxFps;
        }
        catch (Exception ex)
        {
            Log("frame hook error: " + ex);
        }
    }
}
