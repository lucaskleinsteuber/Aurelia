using Aurelia.Linux.Core.Management;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class PerformanceTextTests
{
    [Theory]
    [InlineData(0.4, "0 ms")]
    [InlineData(12.6, "13 ms")]
    [InlineData(999, "999 ms")]
    [InlineData(1460, "1.5 s")]
    public void DurationsReadLikeTheMac(double milliseconds, string expected) =>
        Assert.Equal(expected, PerformanceText.Duration(milliseconds));

    [Theory]
    [InlineData("/api/v1/catalog/items/{mediaId:guid}", "/catalog/items/‹mediaId›")]
    [InlineData("/api/v1/home", "/home")]
    [InlineData("/api/v1", "/")]
    [InlineData("/web/{**file}", "/web/‹file›")]
    public void RoutesHideTheirConstraints(string route, string expected) =>
        Assert.Equal(expected, PerformanceText.Route(route));
}
