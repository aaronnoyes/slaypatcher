using System;
using System.Runtime.InteropServices;
using System.Threading;
using Godot;
using MegaCrit.Sts2.Core.Nodes;

namespace SlayPerf;

/// <summary>
/// The game ignores SIGTERM (the .NET runtime embedded in Godot takes over the signal and
/// never exits), so PortMaster's quit hotkey, which sends SIGTERM via gptokeyb, leaves it
/// running with no input device. Handle SIGTERM/SIGINT ourselves: run the game's own quit
/// (which saves progress) on the main thread, and hard-exit if that hasn't finished in time.
/// </summary>
internal static class QuitOnSignal
{
    private static int _quitting;
    private static PosixSignalRegistration? _term, _int;

    [DllImport("libc", EntryPoint = "kill")]
    private static extern int Kill(int pid, int sig);

    public static void Install()
    {
        try
        {
            _term = PosixSignalRegistration.Create(PosixSignal.SIGTERM, OnSignal);
            _int = PosixSignalRegistration.Create(PosixSignal.SIGINT, OnSignal);
            SlayPerfMod.Log("quit-on-SIGTERM handler installed");
        }
        catch (Exception ex)
        {
            SlayPerfMod.Log("could not install signal handler: " + ex.Message);
        }
    }

    private static void OnSignal(PosixSignalContext ctx)
    {
        ctx.Cancel = true;
        if (Interlocked.Exchange(ref _quitting, 1) == 1) return;
        SlayPerfMod.Log($"{ctx.Signal} received, quitting");

        // Godot's deferred-call queue is thread-safe; the quit itself runs on the main thread.
        Callable.From(() =>
        {
            if (NGame.Instance != null) NGame.Instance.Quit();
            else ((SceneTree)Engine.GetMainLoop()).Quit();
        }).CallDeferred();

        new Thread(() =>
        {
            Thread.Sleep(5000);
            SlayPerfMod.Log("quit did not finish in 5 s, killing");
            Kill(System.Environment.ProcessId, 9);
        }) { IsBackground = true }.Start();
    }
}
