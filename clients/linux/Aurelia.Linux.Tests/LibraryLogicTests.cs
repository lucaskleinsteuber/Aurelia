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
        Assert.Empty(request.MediaIds ?? []);
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

    [Fact]
    public void BoxSetEditorSupportsSeasonsReorderAndZeroMembers()
    {
        var movie = Item("Orbit", year: 2024);
        var series = Item("Cobalt Station", MediaKind.Series, year: 2023);
        var model = new CollectionEditorModel([movie, series], null, null, canShare: true)
        {
            Name = "Sci-Fi Saga",
            Overview = " Chronological order ",
            SortMode = "release",
        };
        Assert.True(model.CanSave);
        model.Toggle(movie);
        model.ToggleMember(series.Id, 0, "Cobalt Station · Specials", MediaKind.Series);
        model.ToggleMember(series.Id, 1, "Cobalt Station · Season 1", MediaKind.Series);
        Assert.Equal(3, model.SelectedMembers.Count);
        model.MoveMember(2, -1);
        Assert.Equal(1, model.SelectedMembers[1].SeasonNumber);
        Assert.Equal("custom", model.SortMode);
        model.SortMode = "release";
        model.RemoveMemberAt(0);
        var req = model.Request();
        Assert.Equal("Chronological order", req.Overview);
        Assert.Equal("release", req.SortMode);
        Assert.NotNull(req.Members);
        Assert.Equal([1, 0], req.Members!.Select(m => m.SeasonNumber));
    }

    [Fact]
    public async Task BoxSetPresentationAndArtworkCacheDifferentiateProvidersAndPaths()
    {
        var tmdbBox = new CollectionSummary(Guid.NewGuid(), "Trilogy", null, [], TotalCount: 3, IsShared: true,
            Provider: "tmdb", CanEdit: false, ItemCount: 3, WatchedCount: 1, YearRange: "2020–2024", SortMode: "release");
        var customBox = new CollectionSummary(Guid.NewGuid(), "Mine", null, [], TotalCount: 1, IsShared: false, UserId: FakeLibrary.OwnerId,
            CanEdit: true, ItemCount: 1, WatchedCount: 0);
        Assert.Equal("TMDB Collection", BoxSetPresentation.ProviderLabel(tmdbBox.Provider));

        var ep1 = new CatalogItemSummary(Guid.NewGuid(), MediaKind.Episode, "Ep 1", null, 2024, null, [], null, null,
            MediaAvailability.Available, false, null, DateTimeOffset.UtcNow, "Cobalt Station", 1, 1);
        Assert.Equal("Resume · S01 E01", BoxSetPresentation.PlayLabel(
            new CollectionNextResponse(ep1, Resume: true, 120_000, 0, 3)));

        var server = FakeLibrary.Create(pictures: false);
        var colArtId = Guid.NewGuid();
        server.Image($"/api/v1/artwork/collection/{colArtId}", [1, 2, 3, 4]);
        using var api = new Aurelia.Linux.Core.Api.AureliaApi(server);
        var stored = new Aurelia.Linux.Core.Connection.StoredServer(
            FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
            "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));
        var session = new Aurelia.Linux.Core.Connection.ProfileSession(
            new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow),
            Guid.NewGuid(), "profile-token-synthetic-0000000000000000001", DateTimeOffset.UtcNow.AddHours(12));
        var client = new LibraryClient(api, stored, session, ["collections-v3", "artwork-variants-v1"]);
        var cache = new ArtworkCache(null);
        var store = new LibraryStore(client, cache, new GeneralPreferences(new MemorySettingsStore()), _ => { });

        Assert.False(BoxSetPresentation.CanEditCollection(tmdbBox, store));
        Assert.True(BoxSetPresentation.CanEditCollection(customBox, store));

        var poster = new ArtworkSummary(colArtId, ArtworkKind.Poster, $"/api/v1/artwork/collection/{colArtId}?kind=poster&rev=2", "image/webp", 640, 2);
        var backdrop = new ArtworkSummary(colArtId, ArtworkKind.Backdrop, $"/api/v1/artwork/collection/{colArtId}?kind=backdrop&rev=2", "image/webp", 1280, 2);
        Assert.Equal([1, 2, 3, 4], await cache.GetAsync(client, poster, 320, CancellationToken.None));
        Assert.Equal([1, 2, 3, 4], await cache.GetAsync(client, backdrop, 320, CancellationToken.None));
        Assert.Contains($"GET /api/v1/artwork/collection/{colArtId}?kind=poster&rev=2&width=320", server.RequestUris);
        Assert.Contains($"GET /api/v1/artwork/collection/{colArtId}?kind=backdrop&rev=2&width=320", server.RequestUris);

        await client.FranchisesAsync(CancellationToken.None);
        Assert.Contains("GET /api/v1/catalog/franchises", server.Requests);
    }
}
