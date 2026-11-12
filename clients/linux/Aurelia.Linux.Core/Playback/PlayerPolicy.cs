using Aurelia.Contracts;
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

    /// <summary>
    /// The Up Next card: for titles of at least five minutes, when the credits begin or in the last seconds of the
    /// countdown (Mac: UpNextPolicy).
    /// </summary>
    public static bool ShowsUpNext(long position, long duration, bool hasNext, bool autoplay, bool stopsAtEnd, bool dismissed, int countdownSeconds = 20,
        long? creditsStart = null)
    {
        if (!hasNext || !autoplay || stopsAtEnd || dismissed || duration < 300_000 || position <= 0) return false;
        if (Credits(creditsStart, duration) is { } credits && position >= credits) return true;
        return duration - position <= countdownSeconds * 1000L;
    }

    /// <summary>Seconds until the next episode: to the end, or the countdown from where the card appeared in the credits.</summary>
    public static int UpNextSeconds(long position, long duration, long? creditsAnchor = null, int countdownSeconds = 20)
    {
        var deadline = creditsAnchor is { } anchor ? Math.Min(duration, anchor + countdownSeconds * 1000L) : duration;
        return (int)((Math.Max(0, deadline - position) + 999) / 1000);
    }

    /// <summary>A credits time is only trusted in the second half of the title and before its end.</summary>
    public static long? Credits(long? creditsStart, long duration) =>
        creditsStart is { } start && duration > 0 && start >= duration / 2 && start < duration - 1000 ? start : null;

    /// <summary>Whether the card shows because the credits began (rather than in the last seconds).</summary>
    public static bool ShowsForCredits(long position, long duration, long? creditsStart) =>
        Credits(creditsStart, duration) is { } credits && position >= credits;

    /// <summary>Next Episode counts this one as watched from the credits on, while Up Next shows, or in its last tenth.</summary>
    public static bool NextFinishesCurrent(long position, long duration, bool upNextShown, long? creditsStart = null)
    {
        if (duration <= 0 || position < 0) return false;
        if (Credits(creditsStart, duration) is { } credits && position >= credits) return true;
        return upNextShown || position >= duration - duration / 10;
    }

    /// <summary>Titles shorter than ten minutes (a short film, an extra) get no suggestions.</summary>
    public const long SuggestionMinimumDuration = 600_000;

    /// <summary>Suggestions are asked for once a title without a next episode is half watched (Mac: SuggestionPolicy).</summary>
    public static bool WantsSuggestions(long position, long duration, bool hasNext) =>
        !hasNext && duration >= SuggestionMinimumDuration && position >= duration / 2;

    /// <summary>The suggestion card after a movie or a series' last episode: from the credits on, else the last seconds; no countdown.</summary>
    public static bool ShowsSuggestion(long position, long duration, bool hasNext, bool hasSuggestion, bool dismissed, long? creditsStart,
        int countdownSeconds = 20)
    {
        if (hasNext || !hasSuggestion || dismissed || duration < SuggestionMinimumDuration || position <= 0) return false;
        if (Credits(creditsStart, duration) is { } credits) return position >= credits;
        return duration - position <= countdownSeconds * 1000L;
    }

    /// <summary>"Next in the Toy Story Collection · 2010"</summary>
    public static string SuggestionCaption(MediaSuggestion suggestion)
    {
        ArgumentNullException.ThrowIfNull(suggestion);
        return string.Join(" · ", new[] { suggestion.Reason, suggestion.Item.Year?.ToString(CultureInfo.InvariantCulture) }
            .Where(part => !string.IsNullOrWhiteSpace(part)));
    }

    /// <summary>The intro when both ends are known and in order.</summary>
    public static (long Start, long End)? Intro(MediaSegmentsDto? segments) =>
        segments is { IntroStartMilliseconds: { } start, IntroEndMilliseconds: { } end } && start >= 0 && end > start ? (start, end) : null;

    /// <summary>"Skip Intro" appears a second before the intro and leaves two seconds before its end (Mac: SkipIntroPolicy).</summary>
    public static bool ShowsSkipIntro(long position, long introStart, long introEnd) =>
        introEnd > introStart && position >= introStart - 1000 && position < introEnd - 2000;

    /// <summary>The intro is skipped on its own once per episode, never after the person moved into it themselves.</summary>
    public static bool SkipsIntroAutomatically(IntroSkipping setting, bool alreadySkipped, bool movedIntoIntro, bool buttonShown) =>
        setting == IntroSkipping.Automatic && buttonShown && !alreadySkipped && !movedIntoIntro;

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
