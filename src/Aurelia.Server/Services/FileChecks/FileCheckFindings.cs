using System.Globalization;
using System.Text.RegularExpressions;
using Aurelia.Contracts;

namespace Aurelia.Server.Services.FileChecks;

/// <summary>A finding about one file: its state, how many errors, about where the first one is and a short explanation.</summary>
public sealed record FileFinding(FileCheckState State, int ErrorCount, double? ProblemAtSeconds, string? Detail);

/// <summary>
/// Collects what ffmpeg writes while it reads a file with <c>-v error -progress pipe:2</c>: the
/// progress lines tell how far it is in the title, every other line is an error at about that
/// point. Lines never keep a path: the input path is removed and addresses are dropped. Pure, so
/// tests check every decision without ffmpeg.
/// </summary>
public sealed partial class FfmpegCheckOutput
{
    /// <summary>At most this many error lines are kept for the explanation.</summary>
    public const int KeptLines = 5;

    private readonly string? inputPath;
    private readonly List<string> kept = [];

    public FfmpegCheckOutput(string? inputPath = null) => this.inputPath = inputPath;

    /// <summary>How far ffmpeg is in the title, in seconds.</summary>
    public double Seconds { get; private set; }

    /// <summary>How many progress lines arrived, so a run that stops moving can be told apart.</summary>
    public long ProgressLines { get; private set; }

    public int ErrorCount { get; private set; }

    /// <summary>About where the first error was, in seconds of the title.</summary>
    public double? FirstErrorSeconds { get; private set; }

    /// <summary>The latest errors' times, for telling a few errors at the start from errors later on.</summary>
    public double? LastErrorSeconds { get; private set; }

    public IReadOnlyList<string> Lines => kept;

    public void Add(string line)
    {
        ArgumentNullException.ThrowIfNull(line);
        var text = line.Trim();
        if (text.Length == 0) return;
        if (ProgressLine().Match(text) is { Success: true } progress)
        {
            ProgressLines++;
            if (progress.Groups[1].Value == "out_time_us"
                && long.TryParse(progress.Groups[2].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var microseconds)
                && microseconds > 0)
            {
                Seconds = Math.Max(Seconds, microseconds / 1_000_000.0);
            }
            return;
        }
        if (Benign(text)) return;
        ErrorCount++;
        FirstErrorSeconds ??= Seconds;
        LastErrorSeconds = Seconds;
        var clean = Clean(text);
        if (kept.Count < KeptLines && !kept.Contains(clean)) kept.Add(clean);
    }

    /// <summary>A line without the input path, without addresses such as "@ 0x7f…" and at most 200 characters.</summary>
    public string Clean(string line)
    {
        var text = line;
        if (!string.IsNullOrEmpty(inputPath))
        {
            text = text.Replace("file:" + inputPath, "the file", StringComparison.Ordinal);
            text = text.Replace(inputPath, "the file", StringComparison.Ordinal);
        }
        text = Address().Replace(text, string.Empty);
        // Anything else that looks like a path is cut as well: an explanation never names a folder.
        text = PathLike().Replace(text, "the file");
        return text.Length > 200 ? text[..200] : text;
    }

    /// <summary>Messages the muxer writes about timestamps of perfectly good files when packets are only copied.</summary>
    private static bool Benign(string line) =>
        line.Contains("non monotonically increasing dts", StringComparison.OrdinalIgnoreCase)
        || line.Contains("Timestamps are unset", StringComparison.OrdinalIgnoreCase)
        || line.Contains("Application provided invalid", StringComparison.OrdinalIgnoreCase);

    [GeneratedRegex(@"^(frame|fps|stream_\d+_\d+_q|bitrate|total_size|out_time_us|out_time_ms|out_time|dup_frames|drop_frames|speed|progress)=(.*)$")]
    private static partial Regex ProgressLine();

    [GeneratedRegex(@"\s*@\s*0x[0-9a-fA-F]+")]
    private static partial Regex Address();

    [GeneratedRegex(@"(?<![\w])(/[^\s:'""]+)+")]
    private static partial Regex PathLike();
}

/// <summary>Turns what a check saw into a finding. Pure, so tests check every rule.</summary>
public static class FileCheckRules
{
    /// <summary>A file that ends more than this before its length is cut off.</summary>
    public const double MissingEndSeconds = 30;

    /// <summary>Errors only within this many seconds of the start are a notice: many good files begin mid-group.</summary>
    public const double StartSeconds = 5;

    /// <summary>At most this many errors at the start are still only a notice.</summary>
    public const int StartErrors = 10;

    /// <summary>The finding of ffmpeg's look at a file that was read in full.</summary>
    /// <param name="exitCode">ffmpeg's exit status.</param>
    /// <param name="durationSeconds">The title's length from its header, when known.</param>
    public static FileFinding Inspect(FfmpegCheckOutput output, int exitCode, double? durationSeconds)
    {
        ArgumentNullException.ThrowIfNull(output);
        var first = output.Lines.Count > 0 ? output.Lines[0] : null;
        if (exitCode != 0 && output.Seconds <= 0)
            return new FileFinding(FileCheckState.Damaged, Math.Max(1, output.ErrorCount), null,
                "The file could not be read as a video" + (first is null ? "." : $": {first}"));
        if (durationSeconds is > MissingEndSeconds and var duration && output.Seconds < duration - MissingEndSeconds)
            return new FileFinding(FileCheckState.Damaged, Math.Max(1, output.ErrorCount), output.Seconds,
                $"The file ends at {Time(output.Seconds)} of {Time(duration)}: the rest is missing, perhaps from a copy or download that stopped.");
        if (output.ErrorCount == 0) return new FileFinding(FileCheckState.Ok, 0, null, null);
        if (output.ErrorCount <= StartErrors && output.LastErrorSeconds <= StartSeconds)
            return new FileFinding(FileCheckState.Notice, output.ErrorCount, output.FirstErrorSeconds,
                "A few errors right at the start, which many files have and which usually don't show" + (first is null ? "." : $": {first}"));
        return new FileFinding(FileCheckState.Damaged, output.ErrorCount, output.FirstErrorSeconds,
            $"{output.ErrorCount} {(output.ErrorCount == 1 ? "error" : "errors")} while reading the picture and sound"
            + (first is null ? "." : $", the first: {first}"));
    }

    /// <summary>The finding when the drive could not read the file at a byte offset.</summary>
    public static FileFinding Unreadable(long offset, long length, double? durationSeconds, string? reason)
    {
        double? at = durationSeconds is > 0 && length > 0 ? durationSeconds * Math.Clamp((double)offset / length, 0, 1) : null;
        var percent = length > 0 ? (int)Math.Floor(100.0 * offset / length) : 0;
        var where = at is { } seconds ? $"at about {Time(seconds)} ({percent} %)" : $"at {percent} %";
        return new FileFinding(FileCheckState.Unreadable, 1, at,
            $"The drive could not read the file {where}. The drive may be failing" + (reason is { Length: > 0 } ? $" ({reason})." : "."));
    }

    /// <summary>The finding when a file's checksum changed although its size and date stayed the same.</summary>
    public static FileFinding ChangedUnexpectedly() => new(FileCheckState.ChangedUnexpectedly, 1, null,
        "The file's content changed although its size and date stayed the same. Usually the drive damaged it (bit rot); "
        + "a program that edits files and keeps their date can do it too. Play it to check, and replace it from a backup if it's broken.");

    /// <summary>"1:02:10" or "4:05".</summary>
    public static string Time(double seconds)
    {
        var value = TimeSpan.FromSeconds(Math.Max(0, Math.Round(seconds)));
        return value.TotalHours >= 1
            ? string.Create(CultureInfo.InvariantCulture, $"{(int)value.TotalHours}:{value.Minutes:00}:{value.Seconds:00}")
            : string.Create(CultureInfo.InvariantCulture, $"{value.Minutes}:{value.Seconds:00}");
    }
}
