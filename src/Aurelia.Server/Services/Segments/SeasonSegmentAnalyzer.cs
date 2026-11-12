using System.Text.RegularExpressions;
using Aurelia.Contracts;

namespace Aurelia.Server.Services.Segments;

public enum SegmentKind
{
    Intro,
    Credits,

    /// <summary>
    /// The rest of the first half after the intro window, searched only when no intro was found
    /// there: some episodes run a long story before their titles.
    /// </summary>
    LateIntro,
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

    /// <summary>Where the later search for an intro begins: shortly before the end of the first window.</summary>
    public static double LateIntroStartSeconds(double duration) => Math.Max(0, IntroWindowSeconds(duration) - 30);

    /// <summary>The later search covers the episode up to its middle.</summary>
    public static double LateIntroLengthSeconds(double duration) => Math.Max(0, duration / 2 - LateIntroStartSeconds(duration));

    /// <summary>A late intro: as long as an intro and before the middle of the episode.</summary>
    public static bool IsPlausibleLateIntro(double start, double end, double duration) =>
        start >= 0 && end - start is >= MinimumIntroSeconds and <= MaximumIntroSeconds && end <= duration / 2 + SnapSeconds;

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

    /// <summary>The first chapter named like credits, wherever it lies.</summary>
    public static (double Start, double End)? NamedCreditsChapter(SegmentEpisode episode)
    {
        ArgumentNullException.ThrowIfNull(episode);
        foreach (var chapter in episode.Chapters)
        {
            if (chapter.Title is { } title && CreditsName().IsMatch(title.Trim())) return (chapter.StartSeconds, chapter.EndSeconds);
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
    Func<int, SegmentKind, CancellationToken, Task<SegmentWindow?>> load,
    Func<int, double, double, CancellationToken, Task<PictureWindow?>>? loadPictures = null)
{
    public const int MaximumPartners = 4;
    private const int MaximumDistance = 8;

    private readonly Dictionary<(int Index, SegmentKind Kind), SegmentWindow?> windows = [];
    private readonly Dictionary<(int Index, long Start), PictureWindow?> pictures = [];
    private readonly Dictionary<(int Low, int High, SegmentKind Kind), IReadOnlyList<SegmentMatcher.Match>> pairs = [];

    public async Task<DetectedSegments> AnalyzeAsync(int index, CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(index);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(index, episodes.Count);
        foreach (var key in windows.Keys.Where(key => Math.Abs(key.Index - index) > MaximumDistance).ToArray()) windows.Remove(key);
        foreach (var key in pictures.Keys.Where(key => Math.Abs(key.Index - index) > MaximumDistance).ToArray()) pictures.Remove(key);
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
        else if (await LateIntroAsync(index, cancellationToken) is { } late
            && SegmentRules.IsPlausibleLateIntro(late.Start, late.End, episode.DurationSeconds))
        {
            (introStart, introEnd, introSource, introConfidence) = (late.Start, late.End, MediaSegmentSource.Detected, late.Confidence);
        }
        else if (await PictureIntroAsync(index, cancellationToken) is { } seen
            && SegmentRules.IsPlausibleIntro(seen.Start, seen.End, episode.DurationSeconds))
        {
            (introStart, introEnd, introSource, introConfidence) = (seen.Start, seen.End, MediaSegmentSource.Detected, seen.Confidence);
        }

        if (SegmentRules.CreditsChapter(episode) is { } creditsChapter)
        {
            (creditsStart, creditsSource, creditsConfidence) = (creditsChapter, MediaSegmentSource.Chapters, 1);
        }
        else
        {
            var heard = await DetectAsync(index, SegmentKind.Credits, cancellationToken) is { } sound
                && SegmentRules.IsPlausibleCredits(sound.Start, sound.End, episode.DurationSeconds)
                ? sound : ((double, double, double)?)null;
            var seen = await PictureCreditsAsync(index, cancellationToken) is { } picture
                && SegmentRules.IsPlausibleCredits(picture.Start, picture.End, episode.DurationSeconds)
                ? (picture.Start, picture.End, picture.Confidence) : ((double, double, double)?)null;
            if (ChooseCredits(heard, seen) is { } credits)
            {
                (creditsStart, creditsSource, creditsConfidence) = (credits.Start, MediaSegmentSource.Detected, credits.Confidence);
            }
        }

        return new DetectedSegments(introStart, introEnd, introSource, introConfidence, creditsStart, creditsSource, creditsConfidence);
    }

    /// <summary>
    /// Credits found in sound and in pictures. Pictures miss names over moving footage, sound misses
    /// credits whose music differs per episode or that begin in silence, so the earlier start wins,
    /// as long as both describe the same credits: credits seen in pictures last to the end, and
    /// shared music only counts when it reaches the pictures' credits.
    /// </summary>
    public static (double Start, double End, double Confidence)? ChooseCredits(
        (double Start, double End, double Confidence)? heard, (double Start, double End, double Confidence)? seen)
    {
        if (heard is not { } sound) return seen;
        if (seen is not { } picture) return sound;
        if (picture.Start <= sound.Start) return (picture.Start, picture.End, Math.Max(picture.Confidence, sound.Confidence));
        return sound.End >= picture.Start - 15
            ? (sound.Start, picture.End, Math.Max(picture.Confidence, sound.Confidence))
            : picture;
    }

    private async Task<CreditsPictures.Result?> PictureCreditsAsync(int index, CancellationToken cancellationToken)
    {
        if (loadPictures is null || await EndingAsync(index, cancellationToken) is not { Kinds.Length: > 0 } own) return null;
        var partners = new List<PictureWindow>();
        for (var distance = 1; distance <= MaximumDistance && partners.Count < MaximumPartners; distance++)
        {
            foreach (var partner in new[] { index - distance, index + distance })
            {
                if (partner < 0 || partner >= episodes.Count || partners.Count >= MaximumPartners) continue;
                if (await EndingAsync(partner, cancellationToken) is { Kinds.Length: > 0 } other) partners.Add(other);
            }
        }
        return CreditsPictures.Find(own, CreditsPictures.Shared(own, partners), episodes[index].DurationSeconds);
    }

    private Task<PictureWindow?> EndingAsync(int index, CancellationToken cancellationToken)
    {
        var duration = episodes[index].DurationSeconds;
        var length = CreditsPictures.WindowSeconds(duration);
        return PicturesAsync(index, Math.Max(0, duration - length), length, cancellationToken);
    }

    private async Task<PictureWindow?> PicturesAsync(int index, double start, double length, CancellationToken cancellationToken)
    {
        var key = (index, (long)Math.Round(start * 10));
        if (pictures.TryGetValue(key, out var cached)) return cached;
        var window = await loadPictures!(index, start, length, cancellationToken);
        pictures[key] = window;
        return window;
    }

    /// <summary>
    /// The intro found in pictures, for an episode whose intro has other sound (someone speaks
    /// over it, a different mix): the beginning's pictures are compared with the intros the other
    /// episodes have by sound. Two of them must show the same pictures at the same place. Only
    /// such episodes have their beginning decoded, so this costs time only where it helps.
    /// </summary>
    private async Task<(double Start, double End, double Confidence)?> PictureIntroAsync(int index, CancellationToken cancellationToken)
    {
        if (loadPictures is null) return null;
        var references = new List<(int Index, double Start, double End)>();
        for (var distance = 1; distance <= MaximumDistance && references.Count < MaximumPartners; distance++)
        {
            foreach (var partner in new[] { index - distance, index + distance })
            {
                if (partner < 0 || partner >= episodes.Count || references.Count >= MaximumPartners) continue;
                if (SegmentRules.IntroChapter(episodes[partner]) is { } chapter)
                {
                    references.Add((partner, chapter.Start, chapter.End));
                }
                else if (await DetectAsync(partner, SegmentKind.Intro, cancellationToken) is { } intro
                    && SegmentRules.IsPlausibleIntro(intro.Start, intro.End, episodes[partner].DurationSeconds))
                {
                    references.Add((partner, intro.Start, intro.End));
                }
            }
        }
        if (references.Count < 2) return null;
        var duration = episodes[index].DurationSeconds;
        if (await PicturesAsync(index, 0, SegmentRules.IntroWindowSeconds(duration), cancellationToken) is not { Kinds.Length: > 0 } own) return null;

        var candidates = new List<SegmentConsensus.Candidate>();
        foreach (var (partner, start, end) in references)
        {
            if (await PicturesAsync(partner, start, end - start, cancellationToken) is not { Kinds.Length: > 0 } theirs) continue;
            if (CreditsPictures.Align(own, theirs) is { Share: >= 0.6 } alignment)
            {
                candidates.Add(new(partner, start + alignment.Offset, end + alignment.Offset, alignment.Share, 0));
            }
        }
        if (SegmentConsensus.Choose(candidates) is not { Partners: >= 2 } agreement) return null;
        var confidence = Math.Round(Math.Min(1, (double)agreement.Partners / references.Count) * Math.Min(1, agreement.Density / 0.6), 3);
        return confidence < SegmentRules.MinimumConfidence ? null : (Math.Max(0, agreement.Start), agreement.End, confidence);
    }

    /// <summary>
    /// The intro further into an episode: the other episodes' intros, as found in their own first
    /// minutes, searched up to this episode's middle. Searching longer finds more music that recurs
    /// by chance, so three other episodes must agree (or every other one in a small season), and
    /// clearly.
    /// </summary>
    private async Task<(double Start, double End, double Confidence)?> LateIntroAsync(int index, CancellationToken cancellationToken)
    {
        if (SegmentRules.LateIntroLengthSeconds(episodes[index].DurationSeconds) < SegmentRules.MinimumIntroSeconds * 2) return null;
        var partners = new List<(int Index, SegmentWindow Window)>();
        for (var distance = 1; distance <= MaximumDistance && partners.Count < MaximumPartners; distance++)
        {
            foreach (var partner in new[] { index - distance, index + distance })
            {
                if (partner < 0 || partner >= episodes.Count || partners.Count >= MaximumPartners) continue;
                if (await WindowAsync(partner, SegmentKind.Intro, cancellationToken) is { Fingerprint.Length: > 0 } other) partners.Add((partner, other));
            }
        }
        var needed = Math.Min(3, partners.Count);
        if (needed < 2) return null;
        if (await WindowAsync(index, SegmentKind.LateIntro, cancellationToken) is not { Fingerprint.Length: > 0 } own) return null;

        var candidates = new List<SegmentConsensus.Candidate>();
        foreach (var (partner, other) in partners)
        {
            foreach (var match in SegmentMatcher.CommonPassages(own.Fingerprint, other.Fingerprint,
                         SegmentRules.MinimumIntroSeconds, SegmentRules.MaximumIntroSeconds + 2 * SegmentRules.SnapSeconds))
            {
                candidates.Add(new(partner, own.StartSeconds + match.FirstStart, own.StartSeconds + match.FirstEnd, match.Density, match.Votes));
            }
        }
        if (SegmentConsensus.Choose(candidates) is not { } agreement || agreement.Partners < needed || agreement.Density < 0.6) return null;
        var confidence = Math.Round(Math.Min(1, (double)agreement.Partners / partners.Count) * Math.Min(1, agreement.Density / 0.5), 3);
        if (confidence < SegmentRules.MinimumConfidence) return null;
        return (Math.Max(0, SegmentRules.SnapToSilence(own, agreement.Start)), SegmentRules.SnapToSilence(own, agreement.End), confidence);
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
