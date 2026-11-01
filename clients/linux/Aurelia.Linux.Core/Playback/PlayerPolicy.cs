using System.Globalization;

namespace Aurelia.Linux.Core.Playback;

/// <summary>The player's small rules, shared with the Mac and Apple TV apps.</summary>
public static class PlayerPolicy
{
    public static readonly double[] Rates = [0.5, 0.75, 1, 1.25, 1.5, 2];
    public const long SkipMilliseconds = 10_000;
    public static readonly TimeSpan ProgressInterval = TimeSpan.FromSeconds(15);

    public static string TimeLabel(long milliseconds)
    {
        var seconds = Math.Max(0, milliseconds) / 1000;
        return seconds >= 3600
            ? string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}:{2:00}", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}", seconds / 60, seconds % 60);
    }

    /// <summary>"Ends at 21:43": when the title finishes if it plays on at this rate.</summary>
    public static string? EndTimeLabel(long position, long duration, double rate, DateTimeOffset now, CultureInfo? culture = null)
    {
        if (duration <= 0 || rate <= 0) return null;
        var remaining = TimeSpan.FromMilliseconds(Math.Max(0, duration - position) / rate);
        var culture1 = culture ?? CultureInfo.CurrentCulture;
        return "Ends at " + now.Add(remaining).ToLocalTime().ToString(culture1.DateTimeFormat.ShortTimePattern, culture1);
    }

    /// <summary>A real end needs a moving clock that reached the title's last seconds.</summary>
    public static bool IsNaturalCompletion(long position, long duration, bool observedPlayback)
    {
        if (!observedPlayback || duration <= 0 || position <= 0) return false;
        // Mac: within the last min(3 s, max(500 ms, 5 % of the duration)).
        return position >= duration - Math.Min(3000, Math.Max(500, duration / 20));
    }

    /// <summary>The Up Next card: for titles of at least five minutes, in the last seconds of the countdown (Mac: UpNextPolicy).</summary>
    public static bool ShowsUpNext(long position, long duration, bool hasNext, bool autoplay, bool stopsAtEnd, bool dismissed, int countdownSeconds = 20) =>
        hasNext && autoplay && !stopsAtEnd && !dismissed && duration >= 300_000 && position > 0 && duration - position <= countdownSeconds * 1000L;

    public static int UpNextSeconds(long position, long duration) => (int)((Math.Max(0, duration - position) + 999) / 1000);

    /// <summary>The decoder opened at the resume position when its first clock lands near it.</summary>
    public static bool OpenedAtResume(long clock, long resume) => Math.Abs(clock - resume) <= 5_000;

    public static long Clamp(long position, long duration) => duration > 0 ? Math.Clamp(position, 0, Math.Max(0, duration - 500)) : Math.Max(0, position);
}

/// <summary>Which timeline frames to prepare, in what order, and where each is taken.</summary>
public static class ScrubPreviewPlan
{
    public const long MinimumInterval = 10_000;
    public const int MaximumFrames = 720;
    public const long StandInReach = 4;
    public const long EndMargin = 3_000;
    public const string ServerFeature = "preview-streams-v1";

    public static long Interval(long duration)
    {
        var spread = (Math.Max(0, duration) + MaximumFrames - 1) / MaximumFrames;
        return Math.Max(MinimumInterval, (spread + 999) / 1000 * 1000);
    }

    public static long Bucket(long milliseconds, long interval) => Math.Max(0, milliseconds) / interval * interval;

    /// <summary>Every step once: first every eighth, then the ones between.</summary>
    public static IReadOnlyList<long> Order(long duration, long interval)
    {
        if (duration <= 0 || interval <= 0) return [];
        var count = (int)((duration + interval - 1) / interval);
        var seen = new bool[count];
        var order = new List<long>(count);
        for (var step = 8; step >= 1; step /= 2)
        {
            for (var index = 0; index < count; index += step)
            {
                if (seen[index]) continue;
                seen[index] = true;
                order.Add(index * interval);
            }
        }
        return order;
    }

    public static long SnapshotPosition(long bucket, long interval, long duration) =>
        Math.Max(0, Math.Min(bucket + interval / 2, duration - EndMargin));

    public static long? Nearest(long bucket, long interval, Func<long, bool> prepared)
    {
        if (prepared(bucket)) return bucket;
        for (long steps = 1; steps <= StandInReach; steps++)
        {
            foreach (var candidate in new[] { bucket - steps * interval, bucket + steps * interval })
                if (candidate >= 0 && prepared(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>Several decoders where the server keeps previews apart, else one.</summary>
    public static int Workers(bool parallel, int? cores = null) =>
        parallel ? Math.Min(6, Math.Max(2, (cores ?? Environment.ProcessorCount) - 4)) : 1;
}
