using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using HarmonyLib;
using MegaCrit.Sts2.Core.Assets;
using MegaCrit.Sts2.Core.Saves;

namespace SlayPerf;

/// <summary>
/// The only places the mod patches game code. Each patch is optional and isolated so a
/// game update that breaks one doesn't take the others (or the game) down.
/// </summary>
internal static class Patches
{
    private static FieldInfo? _vfxScenes;
    public static int VfxSkipped;

    [DllImport("libc", EntryPoint = "dlopen")]
    private static extern IntPtr DlOpen(string file, int mode);

    /// <summary>
    /// The exported Godot binaries link libgcc statically, so libgcc_s is never loaded and
    /// MonoMod's native exception helper (used by Harmony) fails with
    /// "undefined symbol: _Unwind_RaiseException". Load it globally before patching.
    /// </summary>
    private static void EnsureLibgccLoaded()
    {
        const int RTLD_NOW = 2, RTLD_GLOBAL = 0x100;
        try
        {
            if (DlOpen("libgcc_s.so.1", RTLD_NOW | RTLD_GLOBAL) == IntPtr.Zero)
                SlayPerfMod.Log("warning: could not dlopen libgcc_s.so.1; Harmony patches may fail");
        }
        catch (Exception ex)
        {
            SlayPerfMod.Log("warning: dlopen unavailable: " + ex.Message);
        }
    }

    public static void Apply(Config cfg)
    {
        if (!cfg.ShareSaves && cfg.PreloadVfx) return;
        EnsureLibgccLoaded();
        var harmony = new Harmony("slaypatcher.slayperf");

        if (cfg.ShareSaves)
        {
            // Modded sessions normally save to "modded/profileN". This mod doesn't touch
            // gameplay, so keep using the normal profile.
            Try("share_saves", () => harmony.Patch(
                AccessTools.Method(typeof(UserDataPathProvider), nameof(UserDataPathProvider.GetProfileDir)),
                prefix: new HarmonyMethod(typeof(Patches), nameof(GetProfileDirPrefix))));
        }

        if (!cfg.PreloadVfx)
        {
            // Drop VFX scenes from the preload queues so we can measure how much of the
            // loading time they account for. They then load lazily on first use.
            Try("preload_vfx", () =>
            {
                _vfxScenes = AccessTools.Field(typeof(AssetLoadingSession), "_vfxScenes")
                             ?? throw new MissingFieldException("AssetLoadingSession._vfxScenes");
                ConstructorInfo ctor = AccessTools.Constructor(typeof(AssetLoadingSession), new[]
                {
                    typeof(string), typeof(IEnumerable<string>),
                    typeof(System.Collections.Concurrent.ConcurrentDictionary<string, Godot.Resource>),
                    typeof(AssetCache),
                }) ?? throw new MissingMethodException("AssetLoadingSession(string, ...)");
                harmony.Patch(ctor, postfix: new HarmonyMethod(typeof(Patches), nameof(AssetSessionPostfix)));
            });
        }
    }

    private static void Try(string name, Action a)
    {
        try
        {
            a();
            SlayPerfMod.Log($"patch '{name}' applied");
        }
        catch (Exception ex)
        {
            SlayPerfMod.Log($"patch '{name}' FAILED, continuing without it: {ex}");
        }
    }

    private static bool GetProfileDirPrefix(int profileId, ref string __result)
    {
        __result = $"profile{profileId}";
        return false;
    }

    private static void AssetSessionPostfix(AssetLoadingSession __instance, string name)
    {
        if (_vfxScenes?.GetValue(__instance) is Queue<string> q && q.Count > 0)
        {
            VfxSkipped += q.Count;
            SlayPerfMod.Log($"preload '{name}': skipped {q.Count} vfx scenes");
            q.Clear();
        }
    }
}
