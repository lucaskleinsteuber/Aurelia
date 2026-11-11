using System.Collections.Concurrent;

namespace Aurelia.Server.Services;

/// <summary>
/// How fast this server really converts each quality, learned while titles play. On a slow
/// processor the x264 preset gets faster before a picture would stall, and a quality that is too
/// slow even then is no longer offered. Kept in memory only; a restart learns it again.
/// </summary>
public sealed class EncodingPace
{
    /// <summary>x264's presets from best picture to fastest; Aurelia starts at veryfast.</summary>
    public static readonly string[] Presets = ["veryfast", "superfast", "ultrafast"];

    /// <summary>Below this speed against real time the next segment would arrive late.</summary>
    public const double RealTime = 1.0;
    /// <summary>Below this the preset gets faster before playback catches up with conversion.</summary>
    public const double Margin = 1.15;
    /// <summary>Above this a faster preset is no longer needed and the picture gets better again.</summary>
    public const double Comfortable = 2.2;

    public sealed record Measure(string Preset, double Speed);

    private readonly ConcurrentDictionary<(LiveVideoEncoder Kind, string Step), Measure> measures = new();

    /// <summary>Remembers a conversion's speed, smoothed with the earlier ones at the same preset.</summary>
    public void Record(LiveVideoEncoder kind, string step, string? preset, double speed)
    {
        if (!double.IsFinite(speed) || speed <= 0) return;
        var used = preset ?? Presets[0];
        measures.AddOrUpdate((kind, step), new Measure(used, speed),
            (_, earlier) => earlier.Preset == used ? new Measure(used, earlier.Speed * 0.5 + speed * 0.5) : new Measure(used, speed));
    }

    public Measure? Last(LiveVideoEncoder kind, string step) => measures.GetValueOrDefault((kind, step));

    /// <summary>The qualities measured with an encoder, such as "1080p".</summary>
    public IReadOnlyList<string> Measured(LiveVideoEncoder kind) =>
        measures.Keys.Where(key => key.Kind == kind).Select(key => key.Step).Order(StringComparer.Ordinal).ToList();

    /// <summary>The x264 preset for the next conversion of this quality; other encoders have none.</summary>
    public string? Preset(LiveVideoEncoder kind, string step) =>
        kind == LiveVideoEncoder.Libx264 ? NextPreset(Last(kind, step)) : null;

    /// <summary>
    /// One step faster when the last run had no margin, one step better when it had plenty,
    /// otherwise the same preset again.
    /// </summary>
    public static string NextPreset(Measure? last)
    {
        if (last is null) return Presets[0];
        var index = Math.Max(0, Array.IndexOf(Presets, last.Preset));
        if (last.Speed < Margin) index = Math.Min(Presets.Length - 1, index + 1);
        else if (last.Speed > Comfortable) index = Math.Max(0, index - 1);
        return Presets[index];
    }

    /// <summary>
    /// Whether a quality keeps up: not measured yet, or at least real time; for x264 a run below
    /// real time counts only once the fastest preset was tried.
    /// </summary>
    public static bool KeepsUp(LiveVideoEncoder kind, Measure? last) =>
        last is null || last.Speed >= RealTime || (kind == LiveVideoEncoder.Libx264 && last.Preset != Presets[^1]);

    /// <summary>The qualities worth offering with this encoder: those that keep up, and always the smallest.</summary>
    public IReadOnlyList<StreamingStep> Offered(LiveVideoEncoder? kind, IReadOnlyList<StreamingStep> steps)
    {
        if (kind is not { } encoder || steps.Count <= 1) return steps;
        var kept = steps.Where(step => KeepsUp(encoder, Last(encoder, step.Id))).ToList();
        return kept.Count > 0 ? kept : [steps[^1]];
    }
}
