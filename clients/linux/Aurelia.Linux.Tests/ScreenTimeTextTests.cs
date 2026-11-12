using Aurelia.Contracts;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Playback;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>What the Linux app shows for a children's profile's screen time (docs/SCREEN_TIME.md).</summary>
public sealed class ScreenTimeTextTests
{
    private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;
    private static readonly DateTimeOffset Opens = new(2027, 11, 10, 7, 0, 0, TimeSpan.Zero);

    private static ScreenTimeStatus Status(ScreenTimeState state, ScreenTimeReason reason = ScreenTimeReason.Bedtime, bool oneMore = false) =>
        new(state, reason, 60, 60, 0, Opens.AddHours(-11.5), null, Opens, ScreenTimeLockScope.PlaybackOnly, ScreenTimeEnding.FinishTitle, oneMore);

    [Fact]
    public void GoodNightNamesTheProfileAndWhenAureliaOpens()
    {
        Assert.Equal(("Good night, Robin", "See you at 07:00."), ScreenTimeText.GoodNight(Status(ScreenTimeState.Closed), "Robin", Utc));
        Assert.Equal(("That's all for today, Robin", "See you tomorrow at 07:00."),
            ScreenTimeText.GoodNight(Status(ScreenTimeState.Closed, ScreenTimeReason.Limit), "Robin", Utc));
        Assert.Equal("Good night", ScreenTimeText.GoodNight(null, null).Title);
    }

    [Fact]
    public void OnlyAnOpenProfileGetsTheNextTitle()
    {
        Assert.False(Status(ScreenTimeState.Open).NoMoreTitles);
        Assert.True(Status(ScreenTimeState.LastTitle).NoMoreTitles);
        Assert.True(Status(ScreenTimeState.Closed).NoMoreTitles);
        Assert.True(ScreenTimeText.IsScreenTimeCode(ScreenTimeCodes.Limit));
        Assert.False(ScreenTimeText.IsScreenTimeCode("media_not_found"));
    }

    [Fact]
    public void PickerAndTodayLines()
    {
        Assert.Equal("Good night · back at 07:00", ScreenTimeText.ClosedLabel(Opens, Utc));
        Assert.Null(ScreenTimeText.ClosedLabel(null));
        Assert.Equal("60 of 60 min watched today · Time is up, opens at 07:00 · One more title allowed",
            ScreenTimeText.TodaySummary(Status(ScreenTimeState.Closed, ScreenTimeReason.Limit, oneMore: true), Utc));
        Assert.False(ProfilePickerModel.CanChoose(new WatchingProfile(Guid.NewGuid(), "Robin", UserRole.User, false, ClosedUntil: Opens)));
        Assert.True(ProfilePickerModel.CanChoose(new WatchingProfile(Guid.NewGuid(), "Robin", UserRole.User, false)));
    }

    [Fact]
    public void EditedRulesAreCheckedBeforeSaving()
    {
        Assert.Null(ScreenTimeText.Problem(ScreenTimeRules.Default));
        Assert.Equal("Enter the school-night bedtime like 19:30.",
            ScreenTimeText.Problem(ScreenTimeRules.Default with { SchoolNight = new("25:00", "07:00", null) }));
        Assert.Equal("The weekend daily limit is 5 to 1440 minutes.",
            ScreenTimeText.Problem(ScreenTimeRules.Default with { Weekend = new(null, "08:00", 2) }));
    }
}
