using System.Globalization;
using Tarven.Contracts;

namespace Tarven.Linux.Core.Management;

/// <summary>The words the file watch ("file-checks-v1") shows, the same as on the Mac and in the browser.</summary>
public static class FileWatchText
{
    public static readonly IReadOnlyList<(FileCheckDepth Value, string Label)> Depths =
    [
        (FileCheckDepth.Read, "Read Every Byte"),
        (FileCheckDepth.Container, "Read Every Packet"),
        (FileCheckDepth.Decode, "Decode Everything"),
    ];

    public static readonly IReadOnlyList<(int Value, string Label)> Rhythms =
    [
        (0, "Never"),
        (30, "Every 30 Days"),
        (90, "Every 90 Days"),
        (180, "Every 180 Days"),
    ];

    public static string DepthDetail(FileCheckDepth depth) => depth switch
    {
        FileCheckDepth.Read => "Finds places the drive can't read and, later, files that changed by themselves. Fast.",
        FileCheckDepth.Container => "Also finds files that are cut off or have damaged packets. Recommended.",
        _ => "Also finds damage inside pictures and sound. Takes about as long as playing them on a small computer.",
    };

    public static double Progress(FileCheckSettingsResponse settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return settings.TotalCount == 0 ? 1 : Math.Clamp((double)(settings.TotalCount - settings.PendingCount) / settings.TotalCount, 0, 1);
    }

    /// <summary>"Off", "All 120 files examined", "40 of 120 files · 2 problems · paused while someone watches · About 3 h left".</summary>
    public static string Status(FileCheckSettingsResponse settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (!settings.Enabled) return "Off";
        var total = settings.TotalCount;
        var problems = settings.ProblemCount > 0 ? $" · {settings.ProblemCount} {(settings.ProblemCount == 1 ? "problem" : "problems")}" : "";
        if (settings.PendingCount == 0) return $"All {total} {(total == 1 ? "file" : "files")} examined{problems}";
        var parts = new List<string> { $"{Math.Max(0, total - settings.PendingCount)} of {total} files{problems}" };
        if (settings.PausedForPlayback) parts.Add("paused while someone watches");
        if (settings.EstimatedSecondsRemaining is { } seconds && Remaining(seconds) is { } left) parts.Add(left);
        return string.Join(" · ", parts);
    }

    /// <summary>"Now: Movie · Reading every byte (40 %)", or "".</summary>
    public static string Current(FileCheckSettingsResponse settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (!settings.Running || settings.CurrentTitle is not { } title) return "";
        if (settings.CurrentStep is not { } step) return $"Now: {title}";
        var share = settings.CurrentFraction is { } fraction ? $" ({Math.Round(fraction * 100).ToString(CultureInfo.InvariantCulture)} %)" : "";
        return $"Now: {title} · {step}{share}";
    }

    public static string? Remaining(int seconds)
    {
        if (seconds <= 0) return null;
        var minutes = Math.Max(1, (int)Math.Round(seconds / 60.0));
        if (minutes < 60) return $"About {minutes} min left";
        var hours = minutes / 60;
        if (hours >= 48) return $"About {(int)Math.Round(hours / 24.0)} days left";
        var rest = minutes % 60;
        return $"About {hours} h{(rest > 0 ? $" {rest} min" : "")} left";
    }

    public static string ProblemTitle(FileCheckState state) => state switch
    {
        FileCheckState.Unreadable => "Unreadable",
        FileCheckState.ChangedUnexpectedly => "Changed by Itself",
        FileCheckState.Damaged => "Damaged",
        FileCheckState.Notice => "Notice",
        _ => "OK",
    };

    /// <summary>"1:02:10" or "4:05".</summary>
    public static string Clock(double seconds)
    {
        var value = TimeSpan.FromSeconds(Math.Max(0, Math.Round(seconds)));
        return value.TotalHours >= 1
            ? string.Create(CultureInfo.InvariantCulture, $"{(int)value.TotalHours}:{value.Minutes:00}:{value.Seconds:00}")
            : string.Create(CultureInfo.InvariantCulture, $"{value.Minutes}:{value.Seconds:00}");
    }

    /// <summary>"At about 1:02:10 of 1:45:00 · 3 errors · Movies".</summary>
    public static string Facts(FileProblemSummary problem)
    {
        ArgumentNullException.ThrowIfNull(problem);
        var parts = new List<string>();
        if (problem.ProblemAtSeconds is { } at)
            parts.Add($"At about {Clock(at)}" + (problem.DurationSeconds is > 0 and var duration ? $" of {Clock(duration)}" : ""));
        if (problem.ErrorCount > 1) parts.Add($"{problem.ErrorCount} errors");
        if (problem.LibraryName.Length > 0) parts.Add(problem.LibraryName);
        return string.Join(" · ", parts);
    }

    public static string DriveTitle(DriveHealthState state) => state switch
    {
        DriveHealthState.Good => "Good",
        DriveHealthState.Warning => "Warning",
        DriveHealthState.Failing => "Failing",
        _ => "Unknown",
    };

    /// <summary>"35 °C · 10,000 hours · 12 bad sectors".</summary>
    public static string DriveFacts(DriveHealthSummary drive)
    {
        ArgumentNullException.ThrowIfNull(drive);
        var parts = new List<string>();
        if (drive.TemperatureCelsius is { } celsius) parts.Add($"{Math.Round(celsius).ToString(CultureInfo.InvariantCulture)} °C");
        if (drive.PowerOnHours is { } hours) parts.Add(hours.ToString("N0", CultureInfo.InvariantCulture) + " hours");
        if (drive.BadSectors is > 0 and var bad) parts.Add(bad.ToString("N0", CultureInfo.InvariantCulture) + " bad sectors");
        return string.Join(" · ", parts);
    }
}
