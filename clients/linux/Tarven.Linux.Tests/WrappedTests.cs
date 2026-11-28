using Tarven.Linux.Core.Playback;
using Xunit;

namespace Tarven.Linux.Tests;

/// <summary>Wrapped story rules on Linux with invented dates and numbers; nothing is played.</summary>
public sealed class WrappedTests
{
    [Fact]
    public void WrappedCountsPlainNumbersAndClosesAfterTheLastSlide()
    {
        Assert.Equal(143, WrappedStory.CountTarget("143"));
        Assert.Null(WrappedStory.CountTarget("02:47"));
        Assert.Null(WrappedStory.CountTarget(null));
        Assert.Equal(0, WrappedStory.CountValue(143, 0));
        Assert.Equal(143, WrappedStory.CountValue(143, 1));
        Assert.True(WrappedStory.CountValue(100, 0.5) > 50);
        Assert.Equal(1, WrappedStory.Step(0, 3, forward: true));
        Assert.Null(WrappedStory.Step(2, 3, forward: true));
        Assert.Equal(0, WrappedStory.Step(0, 3, forward: false));
        foreach (var name in new[] { "night", "ember", "violet", "gold", "rose", "mint", "ocean", "lime" })
            Assert.True(WrappedStory.Accents.ContainsKey(name), name);
        Assert.Equal(WrappedStory.Accents["night"], WrappedStory.For("invented"));
    }

    [Fact]
    public void AMonthIsReadyFromTheSecondAndNewOnHomeForAWeek()
    {
        Assert.Equal((2026, 10, "October"), WrappedStory.ReadyMonth(new DateTime(2026, 11, 2)));
        Assert.Equal((2026, 9, "September"), WrappedStory.ReadyMonth(new DateTime(2026, 11, 1)));
        Assert.Equal((2026, 12, "December"), WrappedStory.ReadyMonth(new DateTime(2027, 1, 5)));
        Assert.Equal((2026, 11, "November"), WrappedStory.ReadyMonth(new DateTime(2027, 1, 1)));
        Assert.Equal(Enumerable.Range(1, 10), WrappedStory.ReadyMonths(2026, new DateTime(2026, 11, 12)));
        Assert.Equal(12, WrappedStory.ReadyMonths(2025, new DateTime(2026, 11, 12)).Count);
        Assert.Empty(WrappedStory.ReadyMonths(2027, new DateTime(2026, 11, 12)));
        Assert.Equal([2026, 2024], WrappedStory.WrappedYears([2024, 2026, 2027], new DateTime(2026, 11, 12)));
        Assert.False(WrappedStory.MonthIsNew(new DateTime(2026, 11, 1)));
        Assert.True(WrappedStory.MonthIsNew(new DateTime(2026, 11, 8)));
        Assert.False(WrappedStory.MonthIsNew(new DateTime(2026, 11, 9)));
    }
}
