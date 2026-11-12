using System.Globalization;
using System.Numerics;

namespace Aurelia.Server.Services.Speech;

/// <summary>A stretch of time in seconds.</summary>
public readonly record struct TimeSpan2(double Start, double End);

/// <summary>How subtitles are moved: corrected = original × scale + offset.</summary>
public readonly record struct SubtitleShift(double Offset, double Scale)
{
    public static readonly SubtitleShift None = new(0, 1);

    public double Apply(double seconds) => Math.Max(0, seconds * Scale + Offset);
}

/// <summary>From <see cref="From"/> (original subtitle time) on, <see cref="Offset"/>.</summary>
public readonly record struct SubtitleSegment(double From, double Offset);

/// <summary>The shift of a whole film, in parts when the subtitles were made for another cut.</summary>
public sealed record SubtitleTiming(double Scale, IReadOnlyList<SubtitleSegment> Segments)
{
    public SubtitleTiming(SubtitleShift shift) : this(shift.Scale, [new SubtitleSegment(0, shift.Offset)]) { }

    public SubtitleShift ShiftAt(double seconds)
    {
        var segment = Segments.LastOrDefault(candidate => candidate.From <= seconds);
        if (segment == default && Segments.Count > 0 && Segments[0].From > seconds) segment = Segments[0];
        return new SubtitleShift(segment.Offset, Scale);
    }

    public double Apply(double seconds) => ShiftAt(seconds).Apply(seconds);

    /// <summary>Moves cues and drops what a part's new place would put over the part before it.</summary>
    public IReadOnlyList<SubtitleCue> Apply(IReadOnlyList<SubtitleCue> cues)
    {
        var moved = new List<SubtitleCue>();
        foreach (var cue in cues)
        {
            var shift = ShiftAt(cue.Start);
            var start = shift.Apply(cue.Start);
            var end = shift.Apply(cue.End);
            if (moved.Count > 0) start = Math.Max(start, moved[^1].End + 0.05);
            if (end - start < 0.3) continue;
            moved.Add(new SubtitleCue(start, end, cue.Lines));
        }
        return moved;
    }
}

public enum SubtitleSyncVerdict
{
    Shifted,
    AlreadyInSync,
    NoMatch,
}

/// <param name="FitBefore">Share of subtitle time that lies on speech before the shift (0…1).</param>
/// <param name="PoorParts">Share of the film's parts that still don't fit, for example after a cut.</param>
public sealed record SubtitleSyncResult(SubtitleSyncVerdict Verdict, SubtitleTiming Timing, double FitBefore, double FitAfter, double PoorParts);

/// <summary>
/// Finds the shift that lays subtitles over the speech of a sound track, as the Mac app does
/// (SubtitleSync.swift): every offset up to ten minutes at once by cross-correlation, the
/// frame-rate mix-ups between 23.976, 24 and 25 frames per second, parts of another cut each with
/// its own offset, and nothing changed unless the result fits clearly better.
/// </summary>
public static class SubtitleSync
{
    public const double Step = 0.02;
    public const double LongestOffset = 600;
    public const double Worthwhile = 0.08;
    public const double Plausible = 0.3;
    public const double PartLength = 600;
    public const double PartReach = 120;

    public static readonly double[] Scales = [1, 25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24, 25.0 / 24, 24.0 / 25];

    /// <summary>The speech of a sound track: words close together become one stretch.</summary>
    public static IReadOnlyList<TimeSpan2> Speech(IEnumerable<SpeechWord> words, double joining = 0.35)
    {
        var spans = new List<TimeSpan2>();
        foreach (var word in words.OrderBy(word => word.Start).Where(word => word.End > word.Start))
        {
            if (spans.Count > 0 && word.Start - spans[^1].End <= joining)
                spans[^1] = new TimeSpan2(spans[^1].Start, Math.Max(spans[^1].End, word.End));
            else spans.Add(new TimeSpan2(word.Start, word.End));
        }
        return spans;
    }

    public static SubtitleSyncResult Find(IReadOnlyList<TimeSpan2> speech, IReadOnlyList<TimeSpan2> cues)
    {
        var usable = cues.Where(cue => cue.End > cue.Start && cue.Start >= 0).OrderBy(cue => cue.Start).ToList();
        if (speech.Count == 0 || usable.Count == 0)
            return new SubtitleSyncResult(SubtitleSyncVerdict.NoMatch, new SubtitleTiming(SubtitleShift.None), 0, 0, 1);
        var before = Score(speech, usable, SubtitleShift.None);
        var best = (Shift: SubtitleShift.None, Fit: before);
        foreach (var scale in Scales)
        {
            if (BestOffset(speech, usable, scale) is not { } found) continue;
            // A frame-rate change has to earn its place over keeping the speed.
            var bonus = scale == 1 ? 0.01 : 0;
            if (found.Fit + bonus > best.Fit + (best.Shift.Scale == 1 ? 0.01 : 0)) best = found;
        }
        best = Refine(speech, usable, best.Shift);
        var timing = new SubtitleTiming(best.Shift);
        var after = best.Fit;
        if (PoorParts(speech, usable, timing) > 0.1 && Segments(speech, usable, best.Shift) is { } parted && parted.Fit >= after + Worthwhile)
        {
            timing = parted.Timing;
        }
        timing = AlignStarts(speech, usable, timing);
        after = Score(speech, usable, timing);
        var poor = PoorParts(speech, usable, timing);
        var shareBefore = Fit(speech, usable, SubtitleShift.None);
        if (after < Plausible)
            return new SubtitleSyncResult(SubtitleSyncVerdict.NoMatch, new SubtitleTiming(SubtitleShift.None), shareBefore, shareBefore, poor);
        var moved = timing.Segments.Count > 1 || Math.Abs(timing.Segments[0].Offset) >= 0.1 || timing.Scale != 1;
        if (!moved || after - before < Worthwhile)
        {
            var none = new SubtitleTiming(SubtitleShift.None);
            return new SubtitleSyncResult(SubtitleSyncVerdict.AlreadyInSync, none, shareBefore, shareBefore, PoorParts(speech, usable, none));
        }
        return new SubtitleSyncResult(SubtitleSyncVerdict.Shifted, timing, shareBefore, Fit(speech, usable, timing), poor);
    }

    /// <summary>"Moved 2.4 s later. Fits 88 % of the speech (was 31 %)." for the job's message.</summary>
    public static string Summary(SubtitleSyncResult result)
    {
        var percent = (double share) => Math.Round(share * 100).ToString(CultureInfo.InvariantCulture);
        var parts = new List<string>();
        if (result.Timing.Segments.Count > 1) parts.Add($"Moved in {result.Timing.Segments.Count} parts for another cut.");
        else
        {
            var offset = result.Timing.Segments[0].Offset;
            if (Math.Abs(offset) >= 0.05)
                parts.Add($"Moved {Math.Abs(offset).ToString("0.0", CultureInfo.InvariantCulture)} s {(offset > 0 ? "later" : "earlier")}.");
        }
        if (result.Timing.Scale != 1) parts.Add("Speed corrected for a different frame rate.");
        parts.Add($"Fits {percent(result.FitAfter)} % of the speech (was {percent(result.FitBefore)} %).");
        return string.Join(' ', parts);
    }

    /// <summary>Moves each part so the typical subtitle start lies where speech starts after a pause.</summary>
    public static SubtitleTiming AlignStarts(IReadOnlyList<TimeSpan2> speech, IReadOnlyList<TimeSpan2> cues, SubtitleTiming timing)
    {
        var onsets = speech.Select(span => span.Start).ToArray();
        if (onsets.Length == 0) return timing;
        var segments = new List<SubtitleSegment>();
        for (var index = 0; index < timing.Segments.Count; index++)
        {
            var segment = timing.Segments[index];
            var until = index + 1 < timing.Segments.Count ? timing.Segments[index + 1].From : double.PositiveInfinity;
            var shift = new SubtitleShift(segment.Offset, timing.Scale);
            var distances = new List<double>();
            var members = 0;
            foreach (var cue in cues.Where(cue => cue.Start >= segment.From && cue.Start < until))
            {
                members++;
                var start = shift.Apply(cue.Start);
                var low = Array.BinarySearch(onsets, start);
                if (low < 0) low = ~low;
                double? near = null;
                foreach (var candidate in new[] { low - 1, low })
                {
                    if (candidate < 0 || candidate >= onsets.Length) continue;
                    var distance = onsets[candidate] - start;
                    if (near is null || Math.Abs(distance) < Math.Abs(near.Value)) near = distance;
                }
                if (near is { } value && Math.Abs(value) <= 0.75) distances.Add(value);
            }
            var offset = segment.Offset;
            if (members > 0 && distances.Count >= Math.Max(5, members * 3 / 10))
            {
                distances.Sort();
                var median = distances[distances.Count / 2];
                if (Math.Abs(median) <= 0.5) offset += median;
            }
            segments.Add(new SubtitleSegment(segment.From, offset));
        }
        var aligned = new SubtitleTiming(timing.Scale, segments);
        return Score(speech, cues, aligned) >= Score(speech, cues, timing) - 0.02 ? aligned : timing;
    }

    private static List<List<TimeSpan2>> Parts(IReadOnlyList<TimeSpan2> cues)
    {
        var parts = new List<List<TimeSpan2>>();
        if (cues.Count == 0) return parts;
        var last = cues[^1].Start;
        for (var start = 0.0; start <= last; start += PartLength)
        {
            var part = cues.Where(cue => cue.Start >= start && cue.Start < start + PartLength).ToList();
            if (part.Count >= 10) parts.Add(part);
            else if (part.Count > 0 && parts.Count > 0) parts[^1].AddRange(part);
            else if (part.Count > 0) parts.Add(part);
        }
        return parts;
    }

    private static (SubtitleTiming Timing, double Fit)? Segments(IReadOnlyList<TimeSpan2> speech, IReadOnlyList<TimeSpan2> cues, SubtitleShift shift)
    {
        var parts = Parts(cues);
        if (parts.Count < 2) return null;
        var offsets = new List<double>();
        foreach (var part in parts)
        {
            var best = (Offset: shift.Offset, Fit: Score(speech, part, shift));
            var global = best.Fit;
            for (var candidate = shift.Offset - PartReach; candidate <= shift.Offset + PartReach; candidate += 0.05)
            {
                var value = Score(speech, part, new SubtitleShift(candidate, shift.Scale));
                if (value > best.Fit) best = (candidate, value);
            }
            offsets.Add(best.Fit >= Plausible && best.Fit - global >= 0.15 ? best.Offset : shift.Offset);
        }
        var groups = new List<(int From, int To, double Offset)>();
        for (var index = 0; index < offsets.Count; index++)
        {
            if (groups.Count > 0 && Math.Abs(groups[^1].Offset - offsets[index]) < 0.3) groups[^1] = (groups[^1].From, index + 1, groups[^1].Offset);
            else groups.Add((index, index + 1, offsets[index]));
        }
        if (groups.Count is < 2 or > 6) return null;
        var exact = groups.Select(group =>
        {
            var members = Enumerable.Range(group.From, group.To - group.From).SelectMany(index => parts[index]).ToList();
            return Refine(speech, members, new SubtitleShift(group.Offset, shift.Scale)).Shift.Offset;
        }).ToList();
        var segments = new List<SubtitleSegment> { new(0, exact[0]) };
        for (var index = 1; index < groups.Count; index++)
        {
            var near = parts[groups[index - 1].To - 1].Concat(parts[groups[index].From]).ToList();
            var best = (From: near[0].Start, Fit: -1.0);
            foreach (var cue in near)
            {
                var trial = new SubtitleTiming(shift.Scale, [.. segments, new SubtitleSegment(cue.Start, exact[index])]);
                var value = Score(speech, near, trial);
                if (value > best.Fit) best = (cue.Start, value);
            }
            segments.Add(new SubtitleSegment(best.From, exact[index]));
        }
        var timing = new SubtitleTiming(shift.Scale, segments);
        return (timing, Score(speech, cues, timing));
    }

    public static double Fit(IReadOnlyList<TimeSpan2> speech, IReadOnlyList<TimeSpan2> cues, SubtitleTiming timing)
    {
        var moved = cues.Select(cue => new TimeSpan2(timing.Apply(cue.Start), timing.Apply(cue.End))).OrderBy(cue => cue.Start).ToList();
        return Fit(speech, moved, SubtitleShift.None);
    }

    public static double Score(IReadOnlyList<TimeSpan2> speech, IReadOnlyList<TimeSpan2> cues, SubtitleShift shift) =>
        Agreement(speech, [.. cues.Select(cue => new TimeSpan2(shift.Apply(cue.Start), shift.Apply(cue.End)))]);

    public static double Score(IReadOnlyList<TimeSpan2> speech, IReadOnlyList<TimeSpan2> cues, SubtitleTiming timing) =>
        Agreement(speech, [.. cues.Select(cue => new TimeSpan2(timing.Apply(cue.Start), timing.Apply(cue.End)))]);

    /// <summary>The correlation of "someone speaks" with "a subtitle shows" over the subtitles' time, −1 to 1.</summary>
    private static double Agreement(IReadOnlyList<TimeSpan2> speech, List<TimeSpan2> moved)
    {
        var shown = Union(moved);
        if (shown.Count == 0) return 0;
        var from = Math.Max(0, shown[0].Start - 2);
        var to = shown[^1].End + 2;
        var spoken = Union([.. speech.Select(span => new TimeSpan2(Math.Max(from, span.Start), Math.Min(to, span.End))).Where(span => span.End > span.Start)]);
        var length = to - from;
        var speaking = Total(spoken) / length;
        var showing = Total(shown) / length;
        var both = Overlap(spoken, shown) / length;
        var spread = Math.Sqrt(speaking * (1 - speaking) * showing * (1 - showing));
        return spread > 1e-9 ? (both - speaking * showing) / spread : 0;
    }

    private static List<TimeSpan2> Union(List<TimeSpan2> spans)
    {
        var joined = new List<TimeSpan2>();
        foreach (var span in spans.OrderBy(span => span.Start).Where(span => span.End > span.Start))
        {
            if (joined.Count > 0 && span.Start <= joined[^1].End) joined[^1] = new TimeSpan2(joined[^1].Start, Math.Max(joined[^1].End, span.End));
            else joined.Add(span);
        }
        return joined;
    }

    private static double Total(List<TimeSpan2> spans) => spans.Sum(span => span.End - span.Start);

    private static double Overlap(List<TimeSpan2> a, List<TimeSpan2> b)
    {
        int i = 0, j = 0;
        var both = 0.0;
        while (i < a.Count && j < b.Count)
        {
            both += Math.Max(0, Math.Min(a[i].End, b[j].End) - Math.Max(a[i].Start, b[j].Start));
            if (a[i].End < b[j].End) i++;
            else j++;
        }
        return both;
    }

    /// <summary>Share of the subtitles' time on speech after <paramref name="shift"/>.</summary>
    public static double Fit(IReadOnlyList<TimeSpan2> speech, IReadOnlyList<TimeSpan2> cues, SubtitleShift shift)
    {
        double total = 0, covered = 0;
        var index = 0;
        foreach (var cue in cues)
        {
            var start = shift.Apply(cue.Start);
            var end = shift.Apply(cue.End);
            if (end <= start) continue;
            total += end - start;
            while (index < speech.Count && speech[index].End <= start) index++;
            for (var probe = index; probe < speech.Count && speech[probe].Start < end; probe++)
                covered += Math.Max(0, Math.Min(end, speech[probe].End) - Math.Max(start, speech[probe].Start));
        }
        return total > 0 ? covered / total : 0;
    }

    private static (SubtitleShift Shift, double Fit)? BestOffset(IReadOnlyList<TimeSpan2> speech, IReadOnlyList<TimeSpan2> cues, double scale)
    {
        var scaled = cues.Select(cue => new TimeSpan2(cue.Start * scale, cue.End * scale)).ToList();
        var latest = Math.Max(speech[^1].End, scaled[^1].End);
        var samples = (int)Math.Ceiling((latest + LongestOffset) / Step);
        var size = 1;
        while (size < samples * 2) size <<= 1;
        if (size > 1 << 24) return null;
        var content = (int)Math.Ceiling(latest / Step);
        var a = Mask(speech, size, content);
        var b = Mask(scaled, size, content);
        var correlation = Correlate(a, b);
        var reach = (int)(LongestOffset / Step);
        var peaks = new List<(int Lag, double Value)>();
        for (var lag = -reach; lag <= reach; lag++)
        {
            var value = correlation[(lag + size) % size];
            if (value > correlation[(lag - 1 + size) % size] && value >= correlation[(lag + 1 + size) % size]) peaks.Add((lag, value));
        }
        (SubtitleShift Shift, double Fit)? best = null;
        foreach (var candidate in peaks.OrderByDescending(peak => peak.Value).Take(8))
        {
            var shift = new SubtitleShift(candidate.Lag * Step, scale);
            var value = Score(speech, cues, shift);
            if (best is null || value > best.Value.Fit) best = (shift, value);
        }
        return best;
    }

    private static (SubtitleShift Shift, double Fit) Refine(IReadOnlyList<TimeSpan2> speech, IReadOnlyList<TimeSpan2> cues, SubtitleShift shift)
    {
        var best = (Shift: shift, Fit: Score(speech, cues, shift));
        for (var hundredth = -50; hundredth <= 50; hundredth++)
        {
            var candidate = new SubtitleShift(shift.Offset + hundredth * 0.01, shift.Scale);
            var value = Score(speech, cues, candidate);
            if (value > best.Fit + 1e-9) best = (candidate, value);
        }
        return best;
    }

    public static double PoorParts(IReadOnlyList<TimeSpan2> speech, IReadOnlyList<TimeSpan2> cues, SubtitleTiming timing)
    {
        var parts = Parts(cues);
        if (parts.Count == 0) return 1;
        return (double)parts.Count(part => Score(speech, part, timing) < Plausible) / parts.Count;
    }

    /// <summary>1 where a span covers the time, 0 elsewhere, less the mean over the film; padding stays 0.</summary>
    private static Complex[] Mask(IReadOnlyList<TimeSpan2> spans, int size, int content)
    {
        var values = new double[size];
        var covered = 0;
        foreach (var span in spans)
        {
            var from = Math.Max(0, (int)(span.Start / Step));
            var to = Math.Min(content, (int)(span.End / Step));
            for (var index = from; index < to; index++)
            {
                if (values[index] != 0) continue;
                values[index] = 1;
                covered++;
            }
        }
        var mean = (double)covered / Math.Max(1, content);
        var result = new Complex[size];
        for (var index = 0; index < size; index++) result[index] = index < content ? values[index] - mean : 0;
        return result;
    }

    /// <summary>corr[k] = Σ a[t + k] · b[t] for every k at once.</summary>
    private static double[] Correlate(Complex[] a, Complex[] b)
    {
        Fft(a, inverse: false);
        Fft(b, inverse: false);
        for (var index = 0; index < a.Length; index++) a[index] *= Complex.Conjugate(b[index]);
        Fft(a, inverse: true);
        return [.. a.Select(value => value.Real / a.Length)];
    }

    /// <summary>An in-place radix-2 FFT.</summary>
    private static void Fft(Complex[] data, bool inverse)
    {
        var n = data.Length;
        for (int i = 1, j = 0; i < n; i++)
        {
            var bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) (data[i], data[j]) = (data[j], data[i]);
        }
        for (var length = 2; length <= n; length <<= 1)
        {
            var angle = 2 * Math.PI / length * (inverse ? 1 : -1);
            var step = new Complex(Math.Cos(angle), Math.Sin(angle));
            for (var start = 0; start < n; start += length)
            {
                var w = Complex.One;
                for (var k = 0; k < length / 2; k++)
                {
                    var even = data[start + k];
                    var odd = data[start + k + length / 2] * w;
                    data[start + k] = even + odd;
                    data[start + k + length / 2] = even - odd;
                    w *= step;
                }
            }
        }
    }
}
