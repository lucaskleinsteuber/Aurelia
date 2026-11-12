using System.Globalization;
using System.Text;

namespace Aurelia.Server.Services.Speech;

/// <summary>A recognized word with its time in seconds.</summary>
public sealed record SpeechWord(string Text, double Start, double End);

/// <summary>One subtitle: at most two lines shown from <see cref="Start"/> to <see cref="End"/> seconds.</summary>
public sealed record SubtitleCue(double Start, double End, IReadOnlyList<string> Lines);

/// <summary>
/// Turns recognized words into subtitles with the Mac app's rules (SpeechSubtitles.swift): at most
/// two lines of 42 characters, a new subtitle after a sentence, a pause or six seconds, and each
/// shown at least a second and a little after its last word.
/// </summary>
public static class SubtitleCueBuilder
{
    public const int LineLength = 42;
    public const double LongestCue = 6.0;
    public const double ShortestCue = 1.0;
    public const double PauseBreak = 0.8;
    public const double Lingering = 0.4;

    public static IReadOnlyList<SubtitleCue> Cues(IEnumerable<SpeechWord> words)
    {
        static int Characters(List<SpeechWord> group) => group.Sum(word => word.Text.Length) + Math.Max(0, group.Count - 1);
        var groups = new List<List<SpeechWord>>();
        var current = new List<SpeechWord>();
        foreach (var word in words.Select(Clean).OfType<SpeechWord>())
        {
            if (current.Count > 0)
            {
                var last = current[^1];
                var pause = word.Start - last.End;
                var tooLong = word.End - current[0].Start > LongestCue;
                var tooWide = Characters([.. current, word]) > LineLength * 2;
                var longClause = last.Text.EndsWith(',') && Characters(current) > LineLength;
                if (pause >= PauseBreak || tooLong || tooWide || EndsSentence(last.Text) || longClause)
                {
                    groups.Add(current);
                    current = [];
                }
            }
            current.Add(word);
        }
        if (current.Count > 0) groups.Add(current);

        var cues = new List<SubtitleCue>();
        for (var index = 0; index < groups.Count; index++)
        {
            var group = groups[index];
            var first = group[0];
            var last = group[^1];
            var limit = index + 1 < groups.Count ? groups[index + 1][0].Start - 0.05 : double.PositiveInfinity;
            var end = Math.Min(last.End + Lingering, limit);
            if (end - first.Start < ShortestCue) end = Math.Min(first.Start + ShortestCue, limit);
            end = Math.Max(end, last.End);
            cues.Add(new SubtitleCue(first.Start, end, Lines(string.Join(' ', group.Select(word => word.Text)))));
        }
        return cues;
    }

    /// <summary>Text longer than a line is split at the space nearest the middle, preferring one after a comma.</summary>
    public static IReadOnlyList<string> Lines(string text)
    {
        if (text.Length <= LineLength) return [text];
        var middle = text.Length / 2;
        var best = -1;
        var bestScore = int.MaxValue;
        for (var index = 0; index < text.Length; index++)
        {
            if (text[index] != ' ') continue;
            var score = Math.Abs(index - middle);
            if (index > 0 && ",;:".Contains(text[index - 1], StringComparison.Ordinal)) score -= 8;
            if (score < bestScore)
            {
                bestScore = score;
                best = index;
            }
        }
        return best < 0 ? [text] : [text[..best].Trim(), text[(best + 1)..].Trim()];
    }

    public static bool EndsSentence(string text) => text.Length > 0 && ".?!…".Contains(text[^1], StringComparison.Ordinal);

    private static SpeechWord? Clean(SpeechWord word)
    {
        var text = word.Text.Trim();
        if (text.Length == 0 || word.End < word.Start || !double.IsFinite(word.Start) || !double.IsFinite(word.End)) return null;
        return new SpeechWord(text, Math.Max(0, word.Start), word.End);
    }

    public static string SubRip(IReadOnlyList<SubtitleCue> cues)
    {
        var builder = new StringBuilder();
        for (var index = 0; index < cues.Count; index++)
        {
            if (index > 0) builder.Append('\n');
            builder.Append((index + 1).ToString(CultureInfo.InvariantCulture)).Append('\n')
                .Append(Timestamp(cues[index].Start)).Append(" --> ").Append(Timestamp(cues[index].End)).Append('\n')
                .Append(string.Join('\n', cues[index].Lines)).Append('\n');
        }
        return builder.ToString();
    }

    public static string Timestamp(double seconds)
    {
        var total = (long)Math.Round(Math.Max(0, seconds) * 1000);
        return string.Create(CultureInfo.InvariantCulture,
            $"{total / 3_600_000:00}:{total / 60_000 % 60:00}:{total / 1000 % 60:00},{total % 1000:000}");
    }
}

/// <summary>Word starts moved off the silence a recognizer sometimes puts before a word (as on the Mac).</summary>
public static class SpeechTiming
{
    /// <summary>One loudness value per 20 ms.</summary>
    public const double Frame = 0.02;

    /// <summary>Root mean square of each 20 ms of 16 kHz samples.</summary>
    public static float[] Levels(ReadOnlySpan<short> samples, int sampleRate = 16_000)
    {
        var size = (int)(sampleRate * Frame);
        var levels = new float[samples.Length / size];
        for (var frame = 0; frame < levels.Length; frame++)
        {
            double sum = 0;
            for (var index = frame * size; index < (frame + 1) * size; index++)
            {
                var value = samples[index] / 32768.0;
                sum += value * value;
            }
            levels[frame] = (float)Math.Sqrt(sum / size);
        }
        return levels;
    }

    public static IReadOnlyList<SpeechWord> TrimmingSilence(IReadOnlyList<SpeechWord> words, IReadOnlyList<float> levels)
    {
        if (levels.Count <= 50) return words;
        var sorted = levels.Order().ToArray();
        var floor = sorted[sorted.Length / 10];
        var loud = sorted[sorted.Length * 9 / 10];
        var threshold = Math.Max(Math.Max(floor * 4, floor + (loud - floor) * 0.12f), 1e-4f);
        return [.. words.Select(word =>
        {
            if (word.End - word.Start <= 0.3) return word;
            var first = Math.Max(0, (int)(word.Start / Frame));
            var last = Math.Min(levels.Count, (int)(word.End / Frame));
            if (first >= last || levels[first] >= threshold) return word;
            var loudFrame = -1;
            for (var index = first; index < last; index++)
            {
                if (levels[index] >= threshold)
                {
                    loudFrame = index;
                    break;
                }
            }
            if (loudFrame < 0) return word;
            var start = Math.Min(loudFrame * Frame, word.End - 0.1);
            return start > word.Start ? word with { Start = start } : word;
        })];
    }
}

/// <summary>Reads the WebVTT the server makes of every subtitle track into cues (SubtitleSync.swift's SubtitleText).</summary>
public static class SubtitleText
{
    public static IReadOnlyList<SubtitleCue> Cues(string webVtt)
    {
        var normalized = webVtt.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
        var cues = new List<SubtitleCue>();
        foreach (var block in normalized.Split("\n\n"))
        {
            var lines = block.Split('\n');
            var timing = Array.FindIndex(lines, line => line.Contains("-->", StringComparison.Ordinal));
            if (timing < 0) continue;
            var parts = lines[timing].Split("-->");
            if (parts.Length != 2 || Seconds(parts[0]) is not { } start) continue;
            var endText = parts[1].Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
            if (Seconds(endText) is not { } end || end <= start) continue;
            var text = lines.Skip(timing + 1).Select(Clean).Where(line => line.Length > 0).ToList();
            if (text.Count == 0) continue;
            cues.Add(new SubtitleCue(start, end, text));
        }
        return [.. cues.OrderBy(cue => cue.Start)];
    }

    /// <summary>"01:02:03.450", "02:03.450" or "01:02:03,450".</summary>
    public static double? Seconds(string text)
    {
        var fields = text.Trim().Replace(',', '.').Split(':');
        if (fields.Length is < 2 or > 3) return null;
        if (!double.TryParse(fields[^1], NumberStyles.Float, CultureInfo.InvariantCulture, out var last)) return null;
        double whole = 0;
        foreach (var field in fields[..^1])
        {
            if (!int.TryParse(field, NumberStyles.None, CultureInfo.InvariantCulture, out var value)) return null;
            whole = whole * 60 + value;
        }
        return whole * 60 + last;
    }

    /// <summary>Keeps &lt;i&gt;, &lt;b&gt; and &lt;u&gt;; drops other tags such as voice or class tags.</summary>
    private static string Clean(string line)
    {
        var output = new StringBuilder();
        StringBuilder? tag = null;
        foreach (var character in line)
        {
            if (character == '<') tag = new StringBuilder();
            else if (character == '>' && tag is not null)
            {
                var name = tag.ToString().Trim().ToLowerInvariant();
                if (name is "i" or "/i" or "b" or "/b" or "u" or "/u") output.Append('<').Append(name).Append('>');
                tag = null;
            }
            else if (tag is not null) tag.Append(character);
            else output.Append(character);
        }
        return output.ToString().Replace("&amp;", "&", StringComparison.Ordinal).Replace("&lt;", "<", StringComparison.Ordinal)
            .Replace("&gt;", ">", StringComparison.Ordinal).Replace("&nbsp;", " ", StringComparison.Ordinal).Trim();
    }
}
