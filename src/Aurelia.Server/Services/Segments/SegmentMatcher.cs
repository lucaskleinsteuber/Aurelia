using System.Numerics;

namespace Aurelia.Server.Services.Segments;

/// <summary>
/// Finds the passages two fingerprints share, wherever they sit in each of them. This is how an
/// intro is found even when the scene before it has a different length in every episode.
/// </summary>
public static class SegmentMatcher
{
    /// <param name="FirstStart">Seconds from the start of the first window.</param>
    /// <param name="Density">Share of the passage's frames that agree, 0 to 1.</param>
    public readonly record struct Match(double FirstStart, double FirstEnd, double SecondStart, double SecondEnd, double Density, int Votes)
    {
        public double Length => FirstEnd - FirstStart;
    }

    /// <summary>Bits of 32 that may differ for a frame to count as the same sound.</summary>
    public const int FrameTolerance = 10;
    private const int CommonValueLimit = 64;
    private const int CandidateCount = 5;
    private static readonly int Second = (int)Math.Round(1.0 / AudioFingerprint.HopSeconds);
    private static readonly int MaximumGap = (int)Math.Round(1.5 / AudioFingerprint.HopSeconds);

    /// <summary>
    /// Every shared passage between <paramref name="minimum"/> and <paramref name="maximum"/>
    /// seconds, one per alignment, longest first.
    /// </summary>
    public static IReadOnlyList<Match> CommonPassages(uint[] first, uint[] second, double minimum, double maximum)
    {
        ArgumentNullException.ThrowIfNull(first);
        ArgumentNullException.ThrowIfNull(second);
        if (first.Length == 0 || second.Length == 0) return [];

        // Offsets at which identical values line up vote for an alignment. Each half of a value
        // votes on its own, so a few bits changed by another encoding do not silence a frame.
        var positions = new Dictionary<uint, List<int>>();
        for (var index = 0; index < second.Length; index++)
        {
            var value = second[index];
            if (value is 0 or uint.MaxValue) continue;
            foreach (var key in Halves(value))
            {
                if (!positions.TryGetValue(key, out var list)) positions[key] = list = [];
                if (list.Count <= CommonValueLimit) list.Add(index);
            }
        }
        var votes = new Dictionary<int, int>();
        for (var index = 0; index < first.Length; index++)
        {
            var value = first[index];
            if (value is 0 or uint.MaxValue) continue;
            foreach (var key in Halves(value))
            {
                if (!positions.TryGetValue(key, out var list) || list.Count > CommonValueLimit) continue;
                foreach (var position in list)
                {
                    var offset = position - index;
                    votes[offset] = votes.GetValueOrDefault(offset) + 1;
                }
            }
        }

        // The same alignment spreads over neighbouring offsets, so count them together and keep
        // only alignments that are clearly apart.
        var minimumVotes = Math.Max(24, (int)(minimum / AudioFingerprint.HopSeconds) / 16);
        var scored = new List<(int Offset, int Score)>();
        foreach (var (offset, count) in votes)
        {
            var score = count;
            for (var near = 1; near <= 2; near++)
            {
                score += votes.GetValueOrDefault(offset - near) + votes.GetValueOrDefault(offset + near);
            }
            if (score >= minimumVotes) scored.Add((offset, score));
        }
        scored.Sort((left, right) => left.Score == right.Score ? left.Offset.CompareTo(right.Offset) : right.Score.CompareTo(left.Score));

        var chosen = new List<(int Offset, int Score)>();
        foreach (var candidate in scored)
        {
            if (chosen.Count == CandidateCount) break;
            if (chosen.TrueForAll(other => Math.Abs(other.Offset - candidate.Offset) >= Second / 2)) chosen.Add(candidate);
        }

        var matches = new List<Match>();
        foreach (var (offset, score) in chosen)
        {
            if (Run(first, second, offset, score) is { } match && match.Length >= minimum && match.Length <= maximum)
            {
                matches.Add(match);
            }
        }
        matches.Sort((left, right) => right.Length.CompareTo(left.Length));
        return matches;
    }

    /// <summary>The longest stretch at <paramref name="offset"/> where most frames agree, tolerating short dropouts.</summary>
    private static Match? Run(uint[] first, uint[] second, int offset, int votes)
    {
        var start = Math.Max(0, -offset);
        var end = Math.Min(first.Length, second.Length - offset);
        if (end - start <= 0) return null;
        var matched = new bool[end - start];
        for (var index = start; index < end; index++)
        {
            var left = first[index];
            var right = second[index + offset];
            matched[index - start] = left != 0 && right != 0 && BitOperations.PopCount(left ^ right) <= FrameTolerance;
        }
        var prefix = new int[matched.Length + 1];
        for (var index = 0; index < matched.Length; index++) prefix[index + 1] = prefix[index] + (matched[index] ? 1 : 0);

        // A frame belongs to the passage when at least a third of the surrounding second agrees.
        int bestStart = -1, bestEnd = -1, runStart = -1, lastActive = -1;
        for (var index = 0; index < matched.Length; index++)
        {
            var low = Math.Max(0, index - Second / 2);
            var high = Math.Min(matched.Length, index + Second / 2 + 1);
            if ((prefix[high] - prefix[low]) * 3 < high - low) continue;
            if (runStart < 0 || index - lastActive > MaximumGap) runStart = index;
            lastActive = index;
            if (index - runStart > bestEnd - bestStart)
            {
                bestStart = runStart;
                bestEnd = index;
            }
        }
        if (bestStart < 0) return null;

        // The smoothing above is coarse and a chance match nearby can stretch it. The passage
        // really begins where agreement jumps from rare to common, and ends at the opposite jump.
        var edgeStart = Edge(prefix, Math.Max(0, bestStart - Second / 2), Math.Min(bestEnd, bestStart + 3 * Second), rising: true);
        var edgeEnd = Edge(prefix, Math.Max(edgeStart + 1, bestEnd + 1 - 3 * Second), Math.Min(matched.Length, bestEnd + 1 + Second / 2), rising: false) - 1;
        bestStart = edgeStart;
        bestEnd = edgeEnd;
        while (bestStart < bestEnd && !matched[bestStart]) bestStart++;
        while (bestEnd > bestStart && !matched[bestEnd]) bestEnd--;
        if (bestEnd <= bestStart) return null;

        var density = (double)(prefix[bestEnd + 1] - prefix[bestStart]) / (bestEnd + 1 - bestStart);
        var firstStart = (bestStart + start) * AudioFingerprint.HopSeconds + AudioFingerprint.CenterSeconds;
        var firstEnd = (bestEnd + start) * AudioFingerprint.HopSeconds + AudioFingerprint.CenterSeconds;
        var shift = offset * AudioFingerprint.HopSeconds;
        return new Match(firstStart, firstEnd, firstStart + shift, firstEnd + shift, density, votes);
    }

    private static ReadOnlySpan<uint> Halves(uint value) => new uint[] { value & 0xFFFF, 0x1_0000 | (value >> 16) };

    /// <summary>
    /// The position between <paramref name="from"/> and <paramref name="to"/> where the half second
    /// after it agrees most and the half second before it least (or the reverse for an end).
    /// </summary>
    private static int Edge(int[] prefix, int from, int to, bool rising)
    {
        var frames = prefix.Length - 1;
        var span = Second / 2;
        var best = from;
        var bestContrast = int.MinValue;
        for (var position = from; position <= to; position++)
        {
            var before = prefix[position] - prefix[Math.Max(0, position - span)];
            var after = prefix[Math.Min(frames, position + span)] - prefix[position];
            var contrast = rising ? after - before : before - after;
            if (contrast > bestContrast)
            {
                best = position;
                bestContrast = contrast;
            }
        }
        return best;
    }
}
