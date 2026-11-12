using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Playback;

namespace Aurelia.Linux.Core.Management;

/// <summary>Which part the trim editor edits.</summary>
public enum SegmentPart
{
    Intro,
    Credits,
}

/// <summary>Edit Metadata › Intro and Credits and the trim editor, with the Mac app's rules (MediaSegmentViews.swift).</summary>
public static class SegmentEditing
{
    public const long Nudge = 100;

    /// <summary>"1:24" for a time field (whole seconds), "" for none.</summary>
    public static string Text(long? milliseconds) => milliseconds is { } value ? PlayerPolicy.TimeLabel(value / 1000 * 1000) : "";

    /// <summary>True with null for an empty field; false when the text is no time like 1:24 or 1:02:30.</summary>
    public static bool TryParse(string? text, out long? milliseconds)
    {
        milliseconds = null;
        var trimmed = (text ?? "").Trim();
        if (trimmed.Length == 0) return true;
        var parts = trimmed.Split(':');
        if (parts.Length > 3 || parts.Any(part => part.Length == 0 || !part.All(char.IsAsciiDigit))) return false;
        long total = 0;
        for (var index = 0; index < parts.Length; index++)
        {
            if (!long.TryParse(parts[index], NumberStyles.None, CultureInfo.InvariantCulture, out var value)) return false;
            if (index > 0 && value >= 60) return false;
            total = total * 60 + value;
        }
        milliseconds = total * 1000;
        return true;
    }

    /// <summary>The request for the three fields, or null when one isn't a time. An intro without a start begins at 0.</summary>
    public static SetMediaSegmentsRequest? Request(string introStart, string introEnd, string creditsStart)
    {
        if (!TryParse(introStart, out var start) || !TryParse(introEnd, out var end) || !TryParse(creditsStart, out var credits)) return null;
        return new SetMediaSegmentsRequest(end is null ? null : start ?? 0, end, credits);
    }

    /// <summary>A field that still shows the stored time keeps its exact value, so only real changes become corrections.</summary>
    public static SetMediaSegmentsRequest KeepUnchanged(SetMediaSegmentsRequest request, MediaSegmentsResponse stored)
    {
        static long? Keep(long? typed, long? stored) => stored is { } exact && typed == exact / 1000 * 1000 ? exact : typed;
        return new SetMediaSegmentsRequest(Keep(request.IntroStartMilliseconds, stored.IntroStartMilliseconds),
            Keep(request.IntroEndMilliseconds, stored.IntroEndMilliseconds), Keep(request.CreditsStartMilliseconds, stored.CreditsStartMilliseconds));
    }

    public static string Origin(MediaSegmentSource source, double confidence) => source switch
    {
        MediaSegmentSource.Detected => $"Detected ({Math.Round(confidence * 100).ToString(CultureInfo.InvariantCulture)} % sure)",
        MediaSegmentSource.Chapters => "From chapters",
        MediaSegmentSource.Manual => "Set by hand",
        _ => "Not found",
    };

    /// <summary>The stretch of the episode the film strip shows: the first 12 minutes (at most 40 %) or the last ten.</summary>
    public static (long Lower, long Upper) Span(SegmentPart part, long duration, long? start, long? end)
    {
        if (duration <= 0) return (0, 1);
        if (part == SegmentPart.Intro)
        {
            var window = Math.Min(720_000, duration * 2 / 5);
            return (0, Math.Max(1, Math.Min(duration, Math.Max(window, (end ?? 0) + 60_000))));
        }
        return (Math.Max(0, Math.Min(duration - 600_000, (start ?? duration) - 60_000)), duration);
    }

    /// <summary>Where a new intro or credits begins when none is known yet.</summary>
    public static (long Start, long End) Initial(SegmentPart part, (long Lower, long Upper) span) => part == SegmentPart.Intro
        ? (span.Lower, Math.Min(span.Upper, span.Lower + 30_000))
        : (Math.Max(span.Lower, span.Upper - 60_000), span.Upper);

    /// <summary>Keeps the start at least a second before the end and both inside the strip.</summary>
    public static (long Start, long End) Clamp(long start, long end, (long Lower, long Upper) span)
    {
        var e = Math.Min(Math.Max(end, span.Lower + 1000), span.Upper);
        return (Math.Min(Math.Max(start, span.Lower), e - 1000), e);
    }

    /// <summary>"4:15.3"</summary>
    public static string Label(long milliseconds)
    {
        var tenths = Math.Max(0, milliseconds) / 100;
        return $"{PlayerPolicy.TimeLabel(tenths / 10 * 1000)}.{(tenths % 10).ToString(CultureInfo.InvariantCulture)}";
    }

    /// <summary>Share of the episodes the server has examined, 0 to 1.</summary>
    public static double Progress(MediaSegmentSettingsResponse settings)
    {
        var total = Math.Max(settings.TotalCount, settings.PendingCount + settings.AnalyzedCount + settings.NoResultCount);
        return total == 0 ? 1 : (double)(total - settings.PendingCount) / total;
    }

    /// <summary>"About 3 h 20 min left", or null without an estimate.</summary>
    public static string? Remaining(int? seconds)
    {
        if (seconds is not > 0) return null;
        var minutes = Math.Max(1, (int)Math.Round(seconds.Value / 60.0));
        if (minutes < 60) return $"About {minutes} min left";
        return minutes % 60 == 0 ? $"About {minutes / 60} h left" : $"About {minutes / 60} h {minutes % 60} min left";
    }

    /// <summary>"Movies: 12 of 40 with credits · 3 to examine", or null for a server without movies.</summary>
    public static string? MovieStatus(MediaSegmentSettingsResponse settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (settings.MovieCount <= 0) return null;
        var text = $"Movies: {settings.MoviesWithCredits} of {settings.MovieCount} with credits";
        return settings.MoviesPendingCount > 0 ? $"{text} · {settings.MoviesPendingCount} to examine" : text;
    }

    /// <summary>The detection's state line for the server settings.</summary>
    public static string Status(MediaSegmentSettingsResponse settings)
    {
        if (!settings.Available) return "Not available on this server";
        if (!settings.Enabled) return "Off";
        var done = settings.AnalyzedCount + settings.NoResultCount;
        var total = Math.Max(settings.TotalCount, done + settings.PendingCount);
        if (settings.PendingCount == 0) return $"All {total} episodes examined";
        var parts = new List<string> { $"{done} of {total} episodes" };
        if (settings.PausedForPlayback) parts.Add("paused while someone watches");
        if (Remaining(settings.EstimatedSecondsRemaining) is { } left) parts.Add(left);
        return string.Join(" · ", parts);
    }
}
