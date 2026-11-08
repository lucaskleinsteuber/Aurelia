using Aurelia.Contracts;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class LibraryLogicTests
{
    private static CatalogItemSummary Item(string title, MediaKind kind = MediaKind.Movie, string[]? genres = null, int? year = 2020,
        CatalogWatchState state = CatalogWatchState.Unplayed, MediaAvailability availability = MediaAvailability.Available, bool favorite = false) =>
        new(Guid.NewGuid(), kind, title, null, year, null, genres ?? [], null, null, availability, favorite, null, DateTimeOffset.UtcNow, WatchState: state);

    [Fact]
    public void BrowseQueriesUseTheServersParameterNames()
    {
        var query = new BrowseQuery(MediaKind.Movie, FavoritesOnly: true, Genre: "Science Fiction", YearFrom: 2000, YearTo: 2010,
            WatchState: CatalogWatchState.InProgress, Sort: BrowseSort.LastWatched, Descending: true);
        Assert.Equal(
            ["query=orbit", "kind=movie", "favorite=true", "genre=Science Fiction", "yearFrom=2000", "yearTo=2010", "watchState=inProgress", "sort=lastPlayed", "direction=descending"],
            query.Parameters(" orbit ").Select(p => $"{p.Key}={p.Value}"));
        Assert.Empty(new BrowseQuery().Parameters(null));
    }

    [Fact]
    public void PagesKeepTheirKindAndRecentlyAddedSortsNewestFirst()
    {
        Assert.Equal(MediaKind.Series, new BrowseQuery(Kind: MediaKind.Movie).ConstrainedTo(BrowseSection.TvShows).Kind);
        Assert.Null(new BrowseQuery().ConstrainedTo(BrowseSection.Library).Kind);
        var recent = BrowseQuery.DefaultFor(BrowseSection.RecentlyAdded);
        Assert.Equal(BrowseSort.DateAdded, recent.Sort);
        Assert.True(recent.Descending);
    }

    [Fact]
    public void GenreRowsAreTheFirstThreeGenresAlphabetically()
    {
        var rows = LibraryPresentation.GenreRows(
        [
            Item("A", genres: ["Drama", " Comedy "]),
            Item("B", genres: ["Action", "drama"]),
            Item("C", genres: ["Western"]),
        ]);
        Assert.Equal(["Action", "Comedy", "Drama"], rows.Select(r => r.Title));
        Assert.Equal(2, rows.Single(r => r.Title == "Drama").Items.Count);
    }

    [Fact]
    public void RowsHideWatchedAndOfflineTitlesByTheSettings()
    {
        var watched = Item("Watched", state: CatalogWatchState.Completed);
        var offline = Item("Offline", availability: MediaAvailability.Missing);
        var offlineSeries = Item("Show", MediaKind.Series, availability: MediaAvailability.Missing);
        var items = new[] { watched, offline, offlineSeries };
        Assert.Equal(3, LibraryPresentation.Visible(items, keepWatched: false, showWatched: true, hideOffline: false).Count);
        Assert.DoesNotContain(watched, LibraryPresentation.Visible(items, keepWatched: false, showWatched: false, hideOffline: false));
        Assert.Contains(watched, LibraryPresentation.Visible(items, keepWatched: true, showWatched: false, hideOffline: false));
        var hidden = LibraryPresentation.Visible(items, keepWatched: true, showWatched: true, hideOffline: true);
        Assert.DoesNotContain(offline, hidden);
        Assert.Contains(offlineSeries, hidden);
    }

    [Fact]
    public void CardsSayWhatKindOfTitleItIs()
    {
        Assert.Equal("MOVIE · 2020", LibraryPresentation.Eyebrow(Item("A")));
        Assert.Equal("TV SHOW", LibraryPresentation.Eyebrow(Item("B", MediaKind.Series, year: null)));
        var episode = Item("Pilot", MediaKind.Episode) with { ParentTitle = "Cobalt Station", SeasonNumber = 2, EpisodeNumber = 5 };
        Assert.Equal("Cobalt Station · S2 E5", LibraryPresentation.Eyebrow(episode));
        Assert.False(LibraryPresentation.IsPlayable(Item("Show", MediaKind.Series)));
        Assert.False(LibraryPresentation.IsPlayable(Item("Gone", availability: MediaAvailability.Missing)));
    }

    [Theory]
    [InlineData(0.5, "0 min")]
    [InlineData(30, "1 min")]
    [InlineData(45 * 60, "45 min")]
    [InlineData(3 * 3600, "3 h")]
    [InlineData(3 * 3600 + 20 * 60, "3 h 20 min")]
    [InlineData(2 * 86400 + 4 * 3600, "2 d 4 h")]
    public void DurationsUseMinutesHoursAndDays(double seconds, string expected) =>
        Assert.Equal(expected, ActivityFormat.Duration(TimeSpan.FromSeconds(seconds)));

    [Fact]
    public void HistoryGroupsByDay()
    {
        var now = new DateTimeOffset(2026, 11, 1, 20, 0, 0, TimeSpan.Zero);
        Assert.Equal("Today", ActivityFormat.Day(now.AddHours(-1), now));
        Assert.Equal("Yesterday", ActivityFormat.Day(now.AddDays(-1), now));
        Assert.Equal("72 %", ActivityFormat.Percent(0.72));
    }

    [Fact]
    public void TheWeekChartShowsTwelveWeeksWithEmptyOnes()
    {
        var weeks = ActivityFormat.LastWeeks([new PeriodHours("2026-W44", 2), new PeriodHours("2026-W45", 5)], new DateTime(2026, 11, 8));
        Assert.Equal(12, weeks.Count);
        Assert.Equal("2026-W34", weeks[0].Period);
        Assert.Equal(["2026-W44", "2026-W45"], weeks[^2..].Select(week => week.Period));
        Assert.Equal(5, weeks[^1].Hours);
        Assert.Equal(0, weeks[0].Hours);
        Assert.Equal("Nov 2", ActivityFormat.WeekStart("2026-W45"));
        Assert.Equal("November 1, 2026", ActivityFormat.LongDay("2026-11-01"));
    }

    [Fact]
    public void SmartListRulesUseTheServersCanonicalSpelling()
    {
        var model = new CollectionEditorModel([Item("Orbit", genres: ["Science Fiction"], year: 2024), Item("Harbor", genres: ["Drama"], year: 2019, favorite: true)], null, null, canShare: false)
        {
            Name = " Late Night ",
            IsSmart = true,
            Kind = "movie",
            Genres = "Science Fiction, Drama",
            YearMin = "2020",
            Watched = "unwatched",
        };
        var request = model.Request();
        Assert.Equal("Late Night", request.Name);
        Assert.True(request.IsSmart);
        Assert.False(request.IsShared);
        Assert.Empty(request.MediaIds);
        Assert.Equal("""{"kind":"movie","genres":["Science Fiction","Drama"],"yearMin":2020,"watchedState":"unwatched","combination":"and"}""", request.RulesJson);
        Assert.Equal(1, model.MatchingCount);
        model.MatchAny = true;
        Assert.Equal(2, model.MatchingCount);
        Assert.Contains("\"combination\":\"or\"", model.Request().RulesJson, StringComparison.Ordinal);
    }

    [Fact]
    public void AnExistingSmartListOpensWithItsRules()
    {
        var existing = new CollectionSummary(Guid.NewGuid(), "Recent Favorites", null, [], IsSmart: true,
            RulesJson: """{"kind":"series","favoritesOnly":true,"addedWithinDays":90,"combination":"or"}""");
        var model = new CollectionEditorModel([], existing, null, canShare: true);
        Assert.Equal("series", model.Kind);
        Assert.True(model.FavoritesOnly);
        Assert.Equal(90, model.AddedWithinDays);
        Assert.True(model.MatchAny);
    }

    [Fact]
    public void ArtworkAsksForTheSmallestSharpSize()
    {
        Assert.Equal(320, ArtworkCache.WidthFor(180));
        Assert.Equal(640, ArtworkCache.WidthFor(360));
        Assert.Equal(1920, ArtworkCache.WidthFor(1500));
        Assert.Equal(1920, ArtworkCache.WidthFor(5000));
    }

    [Fact]
    public void TheArtworkFolderShrinksOldestFirst()
    {
        var folder = Path.Combine(Path.GetTempPath(), "aurelia-artwork-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            for (var index = 0; index < 10; index++)
            {
                var path = Path.Combine(folder, $"{index}.img");
                File.WriteAllBytes(path, new byte[100]);
                File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(index));
            }
            ArtworkCache.Prune(folder, 500);
            var left = Directory.GetFiles(folder).Select(Path.GetFileNameWithoutExtension).Order().ToList();
            Assert.Equal(["6", "7", "8", "9"], left);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void PreferencesRememberPagesPerServerAndProfile()
    {
        var prefs = new GeneralPreferences(new MemorySettingsStore());
        var server = Guid.NewGuid();
        var user = Guid.NewGuid();
        Assert.Equal(BrowseQuery.DefaultFor(BrowseSection.Movies), prefs.BrowseQuery(server, user, BrowseSection.Movies));
        prefs.SaveBrowseQuery(server, user, BrowseSection.Movies, new BrowseQuery(Kind: MediaKind.Series, FavoritesOnly: true));
        var restored = prefs.BrowseQuery(server, user, BrowseSection.Movies);
        Assert.True(restored.FavoritesOnly);
        Assert.Equal(MediaKind.Movie, restored.Kind);
        Assert.Equal(BrowseQuery.DefaultFor(BrowseSection.Movies), prefs.BrowseQuery(server, Guid.NewGuid(), BrowseSection.Movies));
        prefs.SaveLastDestination(server, user, LibraryDestination.Collections);
        Assert.Equal(LibraryDestination.Collections, prefs.LastDestination(server, user));
        Assert.Equal(180, prefs.PosterWidth);
        prefs.PosterSize = PosterSize.Large;
        Assert.Equal(220, prefs.PosterWidth);
    }

    [Fact]
    public void TheSidebarLayoutIsSavedAndReset()
    {
        var prefs = new GeneralPreferences(new MemorySettingsStore());
        Assert.Equal(SidebarLayout.HiddenByDefault, prefs.Sidebar().Hidden);
        var order = SidebarLayout.ParseOrder("movies,home");
        prefs.SaveSidebar(new SidebarLayout(order, new HashSet<LibraryDestination> { LibraryDestination.Collections }));
        var saved = prefs.Sidebar();
        Assert.Equal(LibraryDestination.Movies, saved.Order[0]);
        Assert.Contains(LibraryDestination.Collections, saved.Hidden);
        Assert.DoesNotContain(LibraryDestination.History, saved.Hidden);
        prefs.ResetSidebar();
        Assert.Equal(SidebarLayout.DefaultOrder, prefs.Sidebar().Order);
    }
}
