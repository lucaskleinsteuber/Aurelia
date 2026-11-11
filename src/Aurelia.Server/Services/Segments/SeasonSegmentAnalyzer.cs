using System.Text.RegularExpressions;
using Aurelia.Contracts;

namespace Aurelia.Server.Services.Segments;

public enum SegmentKind
{
    Intro,
    Credits,
}

/// <summary>
/// The part of one episode's sound that is compared: its fingerprint and loudness, in memory only.
/// </summary>
/// <param name="StartSeconds">Where the window begins in the file.</param>
public sealed record SegmentWindow(uint[] Fingerprint, float[] Energy, double StartSeconds)
{
    public double LengthSeconds => Energy.Length * AudioFingerprint.HopSeconds;

    /// <summary>Fingerprints mono 16-bit PCM at <see cref="AudioFingerprint.SampleRate"/>; the samples are not kept.</summary>
    public static SegmentWindow FromPcm(short[] samples, double startSeconds)
    {
        var result = AudioFingerprint.Compute(samples);
        return new SegmentWindow(result.Values, result.Energy, startSeconds);
    }
}

public sealed record SegmentChapter(double StartSeconds, double EndSeconds, string? Title);

public sealed record SegmentEpisode(double DurationSeconds, IReadOnlyList<SegmentChapter> Chapters);

/// <summary>Times in seconds from the start of the file; null where nothing certain was found.</summary>
public sealed record DetectedSegments(
    double? IntroStart,
    double? IntroEnd,
    MediaSegmentSource IntroSource,
    double IntroConfidence,
    double? CreditsStart,
    MediaSegmentSource CreditsSource,
    double CreditsConfidence)
{
    public static DetectedSegments Nothing { get; } = new(null, null, MediaSegmentSource.None, 0, null, MediaSegmentSource.None, 0);
}

/// <summary>The limits a result must keep. Anything outside them is discarded rather than guessed.</summary>
public static partial class SegmentRules
{
    public const double MinimumIntroSeconds = 10;
    public const double MaximumIntroSeconds = 150;
    public const double MinimumCreditsSeconds = 15;
    public const double CreditsRegionSeconds = 600;
    public const double SnapSeconds = 1.5;

    /// <summary>Results less certain than this are not stored.</summary>
    public const double MinimumConfidence = 0.6;

    /// <summary>The start of an episode that is searched for an intro: 12 minutes or 40 %, whichever is shorter.</summary>
    public static double IntroWindowSeconds(double duration) => Math.Min(720, duration * 0.4);

    /// <summary>The end of an episode that is searched for credits: 10 minutes or 25 %, whichever is shorter.</summary>
    public static double CreditsWindowSeconds(double duration) => Math.Min(CreditsRegionSeconds, duration * 0.25);

    public static bool IsPlausibleIntro(double start, double end, double duration) =>
        start >= 0 && end - start is >= MinimumIntroSeconds and <= MaximumIntroSeconds && end <= IntroWindowSeconds(duration) + SnapSeconds;

    /// <summary>
    /// Credits may end well before the file does (a scene after them); they only have to begin in
    /// the last ten minutes and last long enough.
    /// </summary>
    public static bool IsPlausibleCredits(double start, double end, double duration) =>
        start > 0 && start < duration && start >= duration - CreditsRegionSeconds && end - start >= MinimumCreditsSeconds;

    /// <summary>An intro named by a chapter, when its length is believable.</summary>
    public static (double Start, double End)? IntroChapter(SegmentEpisode episode)
    {
        ArgumentNullException.ThrowIfNull(episode);
        foreach (var chapter in episode.Chapters)
        {
            if (chapter.Title is { } title && IntroName().IsMatch(title.Trim())
                && IsPlausibleIntro(chapter.StartSeconds, chapter.EndSeconds, episode.DurationSeconds))
            {
                return (chapter.StartSeconds, chapter.EndSeconds);
            }
        }
        return null;
    }

    /// <summary>The start of credits named by a chapter, when it lies in the last ten minutes.</summary>
    public static double? CreditsChapter(SegmentEpisode episode)
    {
        ArgumentNullException.ThrowIfNull(episode);
        foreach (var chapter in episode.Chapters)
        {
            if (chapter.Title is { } title && CreditsName().IsMatch(title.Trim())
                && IsPlausibleCredits(chapter.StartSeconds, chapter.EndSeconds, episode.DurationSeconds))
            {
                return chapter.StartSeconds;
            }
        }
        return null;
    }

    [GeneratedRegex(@"^(intro|introduction|opening|opening\s+credits|opening\s+theme|op|title\s+sequence|main\s+titles?)\s*\d{0,2}$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex IntroName();

    [GeneratedRegex(@"^(credits|end\s+credits|closing\s+credits|ending|ending\s+credits|ending\s+theme|ed|outro|end\s+titles?)\s*\d{0,2}$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex CreditsName();

    /// <summary>
    /// Moves a boundary to the quietest moment within ±1.5 s, so a skip does not land in the middle
    /// of a sound. It stays where it is when no moment there is clearly quieter than the rest.
    /// </summary>
    public static double SnapToSilence(SegmentWindow window, double seconds)
    {
        ArgumentNullException.ThrowIfNull(window);
        var energy = window.Energy;
        var center = (int)Math.Round((seconds - window.StartSeconds) / AudioFingerprint.HopSeconds);
        var radius = (int)Math.Round(SnapSeconds / AudioFingerprint.HopSeconds);
        var low = Math.Max(0, center - radius);
        var high = Math.Min(energy.Length - 1, center + radius);
        if (high - low < 8) return seconds;

        // Loudness over about 60 ms, so one quiet sample between two notes does not count.
        const int Smooth = 2;
        var smoothed = new double[high - low + 1];
        double total = 0, minimum = double.MaxValue;
        for (var index = low; index <= high; index++)
        {
            double sum = 0;
            var count = 0;
            for (var near = Math.Max(0, index - Smooth); near <= Math.Min(energy.Length - 1, index + Smooth); near++)
            {
                sum += energy[near];
                count++;
            }
            var value = sum / count;
            smoothed[index - low] = value;
            total += value;
            minimum = Math.Min(minimum, value);
        }
        var mean = total / smoothed.Length;
        if (mean <= 0 || minimum > mean * 0.1) return seconds;

        // Of all moments about as quiet as the quietest, take the one nearest to the boundary.
        var quiet = Math.Max(minimum * 2, 1e-9);
        var best = -1;
        for (var index = low; index <= high; index++)
        {
            if (smoothed[index - low] <= quiet && (best < 0 || Math.Abs(index - center) < Math.Abs(best - center))) best = index;
        }
        return best < 0 ? seconds : window.StartSeconds + (best + 0.5) * AudioFingerprint.HopSeconds;
    }
}

/// <summary>
/// Combines the comparisons of one episode with several others. The real intro is shared by all
/// of them; a recap clip matches only the episode it came from, so it never gathers two partners.
/// </summary>
public static class SegmentConsensus
{
    public readonly record struct Candidate(int Partner, double Start, double End, double Density, int Votes);

    public readonly record struct Agreement(double Start, double End, int Partners, double Density, int Votes);

    public static Agreement? Choose(IReadOnlyList<Candidate> candidates)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        List<Candidate>? best = null;
        double bestLength = 0;
        foreach (var seed in candidates)
        {
            var group = new Dictionary<int, (Candidate Candidate, double Overlap)>();
            foreach (var candidate in candidates)
            {
                var overlap = Overlap(seed, candidate);
                if (overlap < 0.6) continue;
                if (!group.TryGetValue(candidate.Partner, out var current) || overlap > current.Overlap)
                {
                    group[candidate.Partner] = (candidate, overlap);
                }
            }
            var length = group.Values.Sum(member => member.Candidate.End - member.Candidate.Start);
            if (best is null || group.Count > best.Count || (group.Count == best.Count && length > bestLength))
            {
                best = [.. group.Values.Select(member => member.Candidate)];
                bestLength = length;
            }
        }
        if (best is null) return null;
        return new Agreement(
            Median(best.Select(member => member.Start)),
            Median(best.Select(member => member.End)),
            best.Count,
            Median(best.Select(member => member.Density)),
            best.Min(member => member.Votes));
    }

    /// <summary>Shared time divided by the time either covers.</summary>
    private static double Overlap(Candidate first, Candidate second)
    {
        var intersection = Math.Max(0, Math.Min(first.End, second.End) - Math.Max(first.Start, second.Start));
        var union = Math.Max(first.End, second.End) - Math.Min(first.Start, second.Start);
        return union > 0 ? intersection / union : 0;
    }

    private static double Median(IEnumerable<double> values)
    {
        var sorted = values.Order().ToArray();
        return sorted.Length % 2 == 1 ? sorted[sorted.Length / 2] : (sorted[sorted.Length / 2 - 1] + sorted[sorted.Length / 2]) / 2;
    }
}

/// <summary>
/// Finds intro and credits for the episodes of one season by comparing each with up to four
/// others, nearest first. Windows are loaded on demand and dropped again; nothing leaves memory.
/// </summary>
public sealed class SeasonSegmentAnalyzer(
    IReadOnlyList<SegmentEpisode> episodes,
    Func<int, SegmentKind, CancellationToken, Task<SegmentWindow?>> load)
{
    public const int MaximumPartners = 4;
    private const int MaximumDistance = 8;

    private readonly Dictionary<(int Index, SegmentKind Kind), SegmentWindow?> windows = [];
    private readonly Dictionary<(int Low, int High, SegmentKind Kind), IReadOnlyList<SegmentMatcher.Match>> pairs = [];

    public async Task<DetectedSegments> AnalyzeAsync(int index, CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(index);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(index, episodes.Count);
        foreach (var key in windows.Keys.Where(key => Math.Abs(key.Index - index) > MaximumDistance).ToArray()) windows.Remove(key);
        foreach (var key in pairs.Keys.Where(key => Math.Abs(key.Low - index) > MaximumDistance * 2).ToArray()) pairs.Remove(key);

        var episode = episodes[index];
        double? introStart = null, introEnd = null, creditsStart = null;
        var introSource = MediaSegmentSource.None;
        var creditsSource = MediaSegmentSource.None;
        double introConfidence = 0, creditsConfidence = 0;

        // A chapter that names the intro or the credits is exact; nothing is compared then.
        if (SegmentRules.IntroChapter(episode) is { } chapter)
        {
            (introStart, introEnd, introSource, introConfidence) = (chapter.Start, chapter.End, MediaSegmentSource.Chapters, 1);
        }
        else if (await DetectAsync(index, SegmentKind.Intro, cancellationToken) is { } intro
            && SegmentRules.IsPlausibleIntro(intro.Start, intro.End, episode.DurationSeconds))
        {
            (introStart, introEnd, introSource, introConfidence) = (intro.Start, intro.End, MediaSegmentSource.Detected, intro.Confidence);
        }

        if (SegmentRules.CreditsChapter(episode) is { } creditsChapter)
        {
            (creditsStart, creditsSource, creditsConfidence) = (creditsChapter, MediaSegmentSource.Chapters, 1);
        }
        else if (await DetectAsync(index, SegmentKind.Credits, cancellationToken) is { } credits
            && SegmentRules.IsPlausibleCredits(credits.Start, credits.End, episode.DurationSeconds))
        {
            (creditsStart, creditsSource, creditsConfidence) = (credits.Start, MediaSegmentSource.Detected, credits.Confidence);
        }

        return new DetectedSegments(introStart, introEnd, introSource, introConfidence, creditsStart, creditsSource, creditsConfidence);
    }

    private async Task<(double Start, double End, double Confidence)?> DetectAsync(int index, SegmentKind kind, CancellationToken cancellationToken)
    {
        if (await WindowAsync(index, kind, cancellationToken) is not { Fingerprint.Length: > 0 } own) return null;

        var candidates = new List<SegmentConsensus.Candidate>();
        var compared = 0;
        for (var distance = 1; distance <= MaximumDistance && compared < MaximumPartners; distance++)
        {
            foreach (var partner in new[] { index - distance, index + distance })
            {
                if (partner < 0 || partner >= episodes.Count || compared >= MaximumPartners) continue;
                if (await WindowAsync(partner, kind, cancellationToken) is not { Fingerprint.Length: > 0 } other) continue;
                compared++;
                foreach (var match in Pair(index, own, partner, other, kind))
                {
                    var (start, end) = index < partner ? (match.FirstStart, match.FirstEnd) : (match.SecondStart, match.SecondEnd);
                    candidates.Add(new(partner, own.StartSeconds + start, own.StartSeconds + end, match.Density, match.Votes));
                }
            }
        }
        if (SegmentConsensus.Choose(candidates) is not { } agreement) return null;

        double share;
        if (agreement.Partners >= 2)
        {
            share = Math.Min(1, (double)agreement.Partners / Math.Max(2, compared - 1));
        }
        else if (episodes.Count == 2 && compared == 1)
        {
            // Two episodes give a single comparison; it only counts when it is unusually clear.
            var frames = (agreement.End - agreement.Start) / AudioFingerprint.HopSeconds;
            if (agreement.Density < 0.5 || agreement.Votes < frames * 0.05) return null;
            share = 0.75;
        }
        else
        {
            return null;
        }
        var confidence = share * Math.Min(1, agreement.Density / 0.5);
        if (confidence < SegmentRules.MinimumConfidence) return null;

        var snappedStart = Math.Max(0, SegmentRules.SnapToSilence(own, agreement.Start));
        var snappedEnd = SegmentRules.SnapToSilence(own, agreement.End);
        return (snappedStart, snappedEnd, Math.Round(confidence, 3));
    }

    private IReadOnlyList<SegmentMatcher.Match> Pair(int index, SegmentWindow own, int partner, SegmentWindow other, SegmentKind kind)
    {
        var key = (Math.Min(index, partner), Math.Max(index, partner), kind);
        if (pairs.TryGetValue(key, out var cached)) return cached;
        var (first, second) = index < partner ? (own, other) : (other, own);
        var (minimum, maximum) = kind == SegmentKind.Intro
            ? (SegmentRules.MinimumIntroSeconds, SegmentRules.MaximumIntroSeconds + 2 * SegmentRules.SnapSeconds)
            : (SegmentRules.MinimumCreditsSeconds, SegmentRules.CreditsRegionSeconds + 1);
        var matches = SegmentMatcher.CommonPassages(first.Fingerprint, second.Fingerprint, minimum, maximum);
        pairs[key] = matches;
        return matches;
    }

    private async Task<SegmentWindow?> WindowAsync(int index, SegmentKind kind, CancellationToken cancellationToken)
    {
        if (windows.TryGetValue((index, kind), out var cached)) return cached;
        var window = await load(index, kind, cancellationToken);
        windows[(index, kind)] = window;
        return window;
    }
}
