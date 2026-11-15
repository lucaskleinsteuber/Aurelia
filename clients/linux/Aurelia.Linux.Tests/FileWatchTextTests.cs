using Aurelia.Contracts;
using Aurelia.Linux.Core.Management;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>The file watch's words on Linux, the same as on the Mac and in the browser.</summary>
public sealed class FileWatchTextTests
{
    private static FileCheckSettingsResponse Settings(bool enabled = true, int total = 120, int pending = 0, int problems = 0, bool paused = false, int? remaining = null) =>
        new(enabled, FileCheckDepth.Container, 90, true, total, total - pending, pending, problems, pending > 0, paused, EstimatedSecondsRemaining: remaining);

    [Fact]
    public void TheStatusSaysOffDoneOrHowFarTheWatchIs()
    {
        Assert.Equal("Off", FileWatchText.Status(Settings(enabled: false, pending: 120)));
        Assert.Equal("All 120 files examined", FileWatchText.Status(Settings()));
        Assert.Equal("All 1 file examined · 1 problem", FileWatchText.Status(Settings(total: 1, problems: 1)));
        Assert.Equal("40 of 120 files · 2 problems · paused while someone watches · About 3 h 20 min left",
            FileWatchText.Status(Settings(pending: 80, problems: 2, paused: true, remaining: 12_000)));
        Assert.Equal("About 3 days left", FileWatchText.Remaining(3 * 86_400));
        Assert.Equal(0.75, FileWatchText.Progress(Settings(pending: 30)));
        Assert.Equal("Now: Show · S01E02 · Reading every byte (40 %)",
            FileWatchText.Current(Settings(pending: 1) with { CurrentTitle = "Show · S01E02", CurrentStep = "Reading every byte", CurrentFraction = 0.4 }));
    }

    [Fact]
    public void AProblemAndADriveSayWhatTheyAre()
    {
        var problem = new FileProblemSummary(Guid.NewGuid(), "Invented", MediaKind.Movie, "Invented.mkv", "Movies", FileCheckState.Damaged, 3,
            3730, 6300, "3 errors", FileCheckDepth.Container, DateTimeOffset.UtcNow, false);
        Assert.Equal("At about 1:02:10 of 1:45:00 · 3 errors · Movies", FileWatchText.Facts(problem));
        Assert.Equal("Changed by Itself", FileWatchText.ProblemTitle(FileCheckState.ChangedUnexpectedly));
        Assert.Equal("4:05", FileWatchText.Clock(245));
        var drive = new DriveHealthSummary("WD Red", ["Movies"], DriveHealthState.Warning, 35.4, 10_000, 12, null);
        Assert.Equal("35 °C · 10,000 hours · 12 bad sectors", FileWatchText.DriveFacts(drive));
        Assert.Equal("Failing", FileWatchText.DriveTitle(DriveHealthState.Failing));
    }
}
