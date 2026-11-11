using System;
using System.Collections.Generic;
using Godot;

namespace SlayPerf;

/// <summary>
/// Spine skeletons are skinned on the CPU every frame. This switches every SpineSprite to
/// Manual update mode and steps it at a reduced rate, passing the accumulated delta so
/// animations keep their real-time length (events and "animation complete" still fire,
/// just quantised to the update rate). Sprites are phase-staggered so they don't all
/// update on the same frame.
/// </summary>
internal sealed class SpineThrottle
{
    private static readonly StringName SetUpdateMode = "set_update_mode";
    private static readonly StringName UpdateSkeleton = "update_skeleton";
    private const int UpdateModeManual = 2;

    private sealed class Entry
    {
        public required Node Node;
        public required ulong Id;
        public double Acc;
        public double Phase;
    }

    // Frame deltas are never exact (2 x 33.33 ms < 1/15 s), so without a little slack a 15 Hz
    // throttle at 30 FPS waits a third frame and actually runs at 10 Hz.
    private const double Slack = 0.004;

    private readonly double _interval;
    private readonly List<Entry> _sprites = new();
    private readonly HashSet<ulong> _ids = new();
    private int _registered;

    public int Count => _sprites.Count;
    public int UpdatesLastFrame { get; private set; }
    public long TotalUpdates { get; private set; }

    public SpineThrottle(int hz) => _interval = 1.0 / hz;

    public void Register(Node node)
    {
        ulong id = node.GetInstanceId();
        if (!_ids.Add(id)) return;
        node.Call(SetUpdateMode, UpdateModeManual);
        // Golden-ratio phase offsets spread sprites evenly across frames for any rate and count,
        // so they don't all skin on the same frame.
        double phase = (_registered++ * 0.6180339887) % 1.0;
        _sprites.Add(new Entry { Node = node, Id = id, Acc = phase * _interval, Phase = phase });
    }

    public void Tick(double delta)
    {
        int updates = 0;
        for (int i = _sprites.Count - 1; i >= 0; i--)
        {
            Entry e = _sprites[i];
            if (!GodotObject.IsInstanceValid(e.Node))
            {
                _ids.Remove(e.Id);
                _sprites.RemoveAt(i);
                continue;
            }
            if (!e.Node.IsInsideTree()) continue;
            e.Acc += delta;
            if (e.Acc < _interval - Slack) continue;
            e.Node.Call(UpdateSkeleton, (float)e.Acc);
            // After a slow frame every sprite is overdue at once; resetting all to 0 would keep
            // them in lockstep forever. Restore each sprite's own phase offset instead.
            e.Acc = e.Acc > 2 * _interval ? e.Phase * _interval : 0;
            updates++;
        }
        UpdatesLastFrame = updates;
        TotalUpdates += updates;
    }
}
