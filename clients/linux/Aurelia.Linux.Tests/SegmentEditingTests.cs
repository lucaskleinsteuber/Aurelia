using Aurelia.Contracts;
using Aurelia.Linux.Core.Management;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class SegmentEditingTests
{
    [Fact]
    public void FieldsReadAndWriteMinutesAndSecondsLikeTheMac()
    {
        Assert.Equal("1:24", SegmentEditing.Text(84_500));
        Assert.Equal("", SegmentEditing.Text(null));
        Assert.True(SegmentEditing.TryParse("", out var none));
        Assert.Null(none);
        Assert.True(SegmentEditing.TryParse("1:02:30", out var long_));
        Assert.Equal(3_750_000, long_);
        Assert.False(SegmentEditing.TryParse("1:75", out _));
        Assert.False(SegmentEditing.TryParse("abc", out _));
        Assert.Equal(new SetMediaSegmentsRequest(0, 90_000, 2_530_000), SegmentEditing.Request("", "1:30", "42:10"));
        Assert.Equal(new SetMediaSegmentsRequest(null, null, null), SegmentEditing.Request("0:10", "", ""));
        Assert.Null(SegmentEditing.Request("x", "", ""));
        Assert.Equal("Detected (87 % sure)", SegmentEditing.Origin(MediaSegmentSource.Detected, 0.874));
    }

    [Fact]
    public void UnchangedFieldsKeepTheExactStoredTimes()
    {
        var stored = new MediaSegmentsResponse(Guid.NewGuid(), true, true, 61_250, 90_700, MediaSegmentSource.Detected, 0.9, 2_500_400, MediaSegmentSource.Detected, 0.8);
        var typed = SegmentEditing.Request("1:01", "1:35", "41:40")!;
        var kept = SegmentEditing.KeepUnchanged(typed, stored);
        Assert.Equal(61_250, kept.IntroStartMilliseconds);
        Assert.Equal(95_000, kept.IntroEndMilliseconds);
        Assert.Equal(2_500_400, kept.CreditsStartMilliseconds);
    }

    [Fact]
    public void TheStripAndHandlesFollowTheMacsRules()
    {
        Assert.Equal((0L, 720_000L), SegmentEditing.Span(SegmentPart.Intro, 2_700_000, null, null));
        Assert.Equal((0L, 960_000L), SegmentEditing.Span(SegmentPart.Intro, 2_700_000, 0, 900_000));
        Assert.Equal((2_100_000L, 2_700_000L), SegmentEditing.Span(SegmentPart.Credits, 2_700_000, 2_500_000, null));
        Assert.Equal((0L, 30_000L), SegmentEditing.Initial(SegmentPart.Intro, (0, 720_000)));
        Assert.Equal((2_640_000L, 2_700_000L), SegmentEditing.Initial(SegmentPart.Credits, (2_100_000, 2_700_000)));
        Assert.Equal((39_000L, 40_000L), SegmentEditing.Clamp(50_000, 40_000, (0, 720_000)));
        Assert.Equal("4:15.3", SegmentEditing.Label(255_340));
    }

    [Fact]
    public void ProgressAndTimeLeftReadLikeTheMac()
    {
        var running = new MediaSegmentSettingsResponse(true, true, 25, 70, 5, true, false, true, 100, "Series · S01E02", "Pictures", 12_000);
        Assert.Equal(0.75, SegmentEditing.Progress(running));
        Assert.Equal("75 of 100 episodes · About 3 h 20 min left", SegmentEditing.Status(running));
        Assert.Equal("Off", SegmentEditing.Status(running with { Enabled = false }));
        Assert.Equal("All 100 episodes examined", SegmentEditing.Status(running with { PendingCount = 0, AnalyzedCount = 95 }));
        Assert.Equal("About 10 min left", SegmentEditing.Remaining(600));
        Assert.Null(SegmentEditing.Remaining(null));
    }
}
