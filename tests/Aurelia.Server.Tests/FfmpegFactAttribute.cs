using System.Diagnostics;
using System.Globalization;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// A test that needs an installed <c>ffmpeg</c> and <c>ffprobe</c>: skipped explicitly when
/// neither is installed locally (instead of returning silently green), and enforced when
/// <c>AURELIA_REQUIRE_FFMPEG=1</c> is set (such as on CI) (audit SRV-PLAY-010).
/// </summary>
public sealed class FfmpegFactAttribute : FactAttribute
{
    public FfmpegFactAttribute(bool skipOnWindows = false)
    {
        if (skipOnWindows && OperatingSystem.IsWindows())
        {
            Skip = "This ffmpeg test requires POSIX file semantics.";
            return;
        }
        if (FfmpegTestTools.Installed() is null && !FfmpegTestTools.Required)
        {
            Skip = FfmpegTestTools.SkipReason;
        }
    }
}

/// <inheritdoc cref="FfmpegFactAttribute"/>
public sealed class FfmpegTheoryAttribute : TheoryAttribute
{
    public FfmpegTheoryAttribute(bool skipOnWindows = false)
    {
        if (skipOnWindows && OperatingSystem.IsWindows())
        {
            Skip = "This ffmpeg test requires POSIX file semantics.";
            return;
        }
        if (FfmpegTestTools.Installed() is null && !FfmpegTestTools.Required)
        {
            Skip = FfmpegTestTools.SkipReason;
        }
    }
}

internal static class FfmpegTestTools
{
    public const string SkipReason = "ffmpeg and ffprobe are not installed.";

    public static bool Required => Environment.GetEnvironmentVariable("AURELIA_REQUIRE_FFMPEG") == "1";

    public static string? Installed()
    {
        var directories = (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(Path.PathSeparator)
            .Concat(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]);
        return directories.Where(directory => directory.Length > 0)
            .Select(directory => Path.Combine(directory, "ffmpeg"))
            .FirstOrDefault(candidate => File.Exists(candidate) && File.Exists(Path.Combine(Path.GetDirectoryName(candidate)!, "ffprobe")));
    }

    public static string RequireInstalled() =>
        Installed() ?? throw new InvalidOperationException("ffmpeg and ffprobe are required when AURELIA_REQUIRE_FFMPEG=1.");

    /// <summary>Counts live child ffmpeg processes of the current test process on macOS/Linux.</summary>
    public static int ChildFfmpegProcessCount()
    {
        if (OperatingSystem.IsWindows()) return 0;
        var myPid = Environment.ProcessId;
        var start = new ProcessStartInfo("/bin/ps")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add("-eo");
        start.ArgumentList.Add("ppid=,comm=");
        using var ps = Process.Start(start);
        if (ps is null) return 0;
        var output = ps.StandardOutput.ReadToEnd();
        ps.WaitForExit(3000);
        var count = 0;
        foreach (var raw in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = raw.Trim();
            var space = trimmed.IndexOfAny([' ', '\t']);
            if (space <= 0) continue;
            if (!int.TryParse(trimmed.AsSpan(0, space), NumberStyles.None, CultureInfo.InvariantCulture, out var ppid) || ppid != myPid)
                continue;
            var comm = trimmed[(space + 1)..].Trim();
            if (Path.GetFileName(comm).Equals("ffmpeg", StringComparison.OrdinalIgnoreCase))
                count++;
        }
        return count;
    }
}
