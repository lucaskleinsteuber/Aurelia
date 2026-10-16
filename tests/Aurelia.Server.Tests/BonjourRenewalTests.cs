using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class BonjourRenewalTests
{
    [Theory]
    [InlineData(0, 3)]
    [InlineData(1, 6)]
    [InlineData(2, 12)]
    [InlineData(3, 30)]
    [InlineData(15, 30)]
    public void PublicationRetriesRemainBounded(int attempt, int seconds)
        => Assert.Equal(TimeSpan.FromSeconds(seconds), BonjourAdvertisementService.RetryDelay(attempt));

    [Theory]
    [InlineData(15, false)]
    [InlineData(40, false)]
    [InlineData(41, true)]
    [InlineData(3600, true)]
    public void ResumeAfterSuspensionRenewsAnnouncement(int seconds, bool expected)
    {
        var previous = DateTimeOffset.Parse("2026-01-01T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture);
        Assert.Equal(expected, BonjourAdvertisementService.ShouldRenewAfterPause(previous, previous.AddSeconds(seconds)));
    }
}
