using Aurelia.Linux.Core;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class CoreTests
{
    [Theory]
    [InlineData("0.1.0+build.1", "0.1.0 (1)")]
    [InlineData("0.1.0+build.12.5f2c1ab", "0.1.0 (12)")]
    [InlineData("1.2.3", "1.2.3")]
    [InlineData(null, "0.0.0")]
    public void FormatsVersionAndBuild(string? informational, string expected) =>
        Assert.Equal(expected, AppInfo.FormatVersion(informational));

    [Fact]
    public void ThisBuildCarriesItsOwnVersion() => Assert.Matches(@"^\d+\.\d+\.\d+ \(\d+\)$", AppInfo.DisplayVersion);

    [Fact]
    public void IdentifiersMatchTheMacApp()
    {
        Assert.Equal(
            ["home", "library", "collections", "watchlist", "recentlyAdded", "tvShows", "movies", "history", "statistics"],
            SidebarLayout.DefaultOrder.Select(d => d.Identifier()));
        foreach (var destination in Enum.GetValues<LibraryDestination>())
        {
            Assert.Equal(destination, LibraryDestinations.FromIdentifier(destination.Identifier()));
        }
        Assert.Null(LibraryDestinations.FromIdentifier("continueWatching"));
    }

    [Fact]
    public void HistoryAndStatisticsJoinTheSidebarOnlyWhenTurnedOn()
    {
        var visible = SidebarLayout.Default.VisibleItems(supportsWatchlist: true);
        Assert.DoesNotContain(LibraryDestination.History, visible);
        Assert.DoesNotContain(LibraryDestination.Statistics, visible);
        Assert.Equal(LibraryDestination.Home, visible[0]);
    }

    [Fact]
    public void WatchlistNeedsAServerThatSupportsIt() =>
        Assert.DoesNotContain(LibraryDestination.Watchlist, SidebarLayout.Default.VisibleItems(supportsWatchlist: false));

    [Fact]
    public void SavedOrderSkipsUnknownAndRepeatedPagesAndKeepsNewOnes()
    {
        var order = SidebarLayout.ParseOrder("movies, unknown,home,movies");
        Assert.Equal(LibraryDestination.Movies, order[0]);
        Assert.Equal(LibraryDestination.Home, order[1]);
        Assert.Equal(Enum.GetValues<LibraryDestination>().Length, order.Count);
        Assert.Equal(order.Distinct().Count(), order.Count);
        Assert.Equal(order, SidebarLayout.ParseOrder(SidebarLayout.FormatOrder(order)));
    }

    [Fact]
    public void EmptySavedOrderIsTheDefault() => Assert.Equal(SidebarLayout.DefaultOrder, SidebarLayout.ParseOrder(null));
}

public sealed class StartupTests
{
    /// <summary>Checks startup policy without replacing Avalonia's already initialized headless platform.</summary>
    [Theory]
    [InlineData(true, null, DisplayBackendPreference.WaylandWithX11Fallback)]
    [InlineData(true, "x11", DisplayBackendPreference.X11)]
    [InlineData(true, "unknown", DisplayBackendPreference.WaylandWithX11Fallback)]
    [InlineData(false, "x11", DisplayBackendPreference.PlatformDefault)]
    public void ChoosesADisplayBackendWithoutChangingTheRunningPlatform(bool linux, string? backend, DisplayBackendPreference expected) =>
        Assert.Equal(expected, Program.SelectDisplayBackend(linux, backend));
}
