using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class PlaybackTicketPolicyTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("360")]
    [InlineData("0")]
    [InlineData("invalid")]
    public void ProductionIgnoresTestEnvironmentOverride(string? value)
    {
        Assert.Equal(TimeSpan.FromHours(12), PlaybackTicketPolicy.Resolve(false, value).Lifetime);
    }

    [Fact]
    public void IsolatedHostCanExerciseRealRenewal()
    {
        Assert.Equal(TimeSpan.FromSeconds(360), PlaybackTicketPolicy.Resolve(true, "360").Lifetime);
        Assert.Equal(TimeSpan.FromHours(12), PlaybackTicketPolicy.Resolve(true, null).Lifetime);
    }

    [Theory]
    [InlineData("29")]
    [InlineData("43201")]
    [InlineData("-1")]
    [InlineData("infinity")]
    public void InvalidIsolatedLifetimeFailsClosed(string value)
    {
        Assert.Throws<InvalidOperationException>(() => PlaybackTicketPolicy.Resolve(true, value));
    }
}
