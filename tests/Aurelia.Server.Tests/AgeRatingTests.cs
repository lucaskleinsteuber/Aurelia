using Aurelia.Contracts;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>A US rating counts as the next FSK at or above its age, so a children's profile never sees older titles.</summary>
public sealed class AgeRatingTests
{
    [Theory]
    [InlineData("FSK 12", 12)]
    [InlineData("fsk 16 ", 16)]
    [InlineData("G", 0)]
    [InlineData("PG", 6)]
    [InlineData("TV-Y7", 12)]
    [InlineData("PG-13", 16)]
    [InlineData("TV-14", 16)]
    [InlineData("R", 18)]
    [InlineData("TV-MA", 18)]
    [InlineData("NC-17", 18)]
    public void ARatingAllowsItsAgeRoundedUpToAnFskLevel(string rating, int age) => Assert.Equal(age, AgeRatings.MinimumAge(rating));

    [Fact]
    public void ALimitAllowsNothingRatedForOlderChildrenOrUnrated()
    {
        Assert.DoesNotContain("TV-14", AgeRatings.AllowedFor(12));
        Assert.DoesNotContain("PG-13", AgeRatings.AllowedFor(12));
        Assert.DoesNotContain("R", AgeRatings.AllowedFor(16));
        Assert.DoesNotContain("TV-MA", AgeRatings.AllowedFor(16));
        Assert.Contains("PG-13", AgeRatings.AllowedFor(16));
        Assert.Null(AgeRatings.MinimumAge("Unrated"));
        Assert.Empty(AgeRatings.AllowedFor(null));
    }
}
