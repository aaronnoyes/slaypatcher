using System;
using Godot;

namespace SlayPerf;

/// <summary>
/// Inspects every node as it enters the scene tree and applies the configured knobs.
/// Done from the outside via SceneTree.node_added so no game code is patched.
/// </summary>
internal sealed class NodeTweaks
{
    private static readonly StringName SpineSpriteClass = "SpineSprite";

    private readonly Config _cfg;
    private readonly SpineThrottle? _spine;
    private ShaderMaterial? _passthrough;

    public int GpuParticlesSeen, CpuParticlesSeen, SpineSeen, ShadersReplaced;

    public NodeTweaks(Config cfg, SpineThrottle? spine)
    {
        _cfg = cfg;
        _spine = spine;
        if (cfg.Shaders == ShaderMode.Passthrough)
        {
            // One shared, trivial material: every replaced item can batch together.
            _passthrough = new ShaderMaterial { Shader = new Shader { Code = "shader_type canvas_item;\n" } };
        }
    }

    public void ApplyRecursive(Node node)
    {
        OnNodeAdded(node);
        foreach (Node child in node.GetChildren(true)) ApplyRecursive(child);
    }

    public void OnNodeAdded(Node node)
    {
        try
        {
            switch (node)
            {
                case GpuParticles2D gp:
                    GpuParticlesSeen++;
                    TweakGpu(gp);
                    break;
                case CpuParticles2D cp:
                    CpuParticlesSeen++;
                    TweakCpu(cp);
                    break;
                default:
                    // GDExtension classes surface in C# as their nearest native base (Node2D),
                    // so only pay for the string class check on plain Node2D wrappers.
                    if (node.GetType() == typeof(Node2D) && node.IsClass(SpineSpriteClass))
                    {
                        SpineSeen++;
                        _spine?.Register(node);
                    }
                    break;
            }

            if (_passthrough != null && node is CanvasItem ci && ci.Material is ShaderMaterial sm && sm != _passthrough)
            {
                ci.Material = _passthrough;
                ShadersReplaced++;
            }
        }
        catch (Exception ex)
        {
            SlayPerfMod.Log($"node tweak failed on {node.Name}: {ex.Message}");
        }
    }

    private void TweakGpu(GpuParticles2D p)
    {
        switch (_cfg.Particles)
        {
            case ParticleMode.Half:
                p.AmountRatio = Math.Min(p.AmountRatio, 0.5f);
                break;
            case ParticleMode.Off:
                // Hidden particles are neither simulated nor drawn, but the node's own
                // emission timer keeps running, so "finished" signals still fire and
                // game code waiting on one-shot VFX doesn't hang.
                p.AmountRatio = 0f;
                KeepHidden(p);
                break;
        }
    }

    private void TweakCpu(CpuParticles2D p)
    {
        switch (_cfg.Particles)
        {
            case ParticleMode.Half:
                p.Amount = Math.Max(1, p.Amount / 2);
                break;
            case ParticleMode.Off:
                KeepHidden(p);
                break;
        }
    }

    private static void KeepHidden(CanvasItem item)
    {
        item.Visible = false;
        item.VisibilityChanged += () =>
        {
            if (GodotObject.IsInstanceValid(item) && item.Visible)
                item.SetDeferred(CanvasItem.PropertyName.Visible, false);
        };
    }
}
