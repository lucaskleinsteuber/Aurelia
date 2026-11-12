using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.IntegrationTests;

/// <summary>The library screens' data against the real server and a synthetic library.</summary>
public sealed class LibraryFlowTests : IDisposable
{
    private readonly RealServer server = new();
    private readonly AureliaApi api;

    public LibraryFlowTests() => api = new AureliaApi(server.Transport);

    public void Dispose()
    {
        api.Dispose();
        server.Dispose();
    }

    private async Task<LibraryStore> OpenLibraryAsync()
    {
        var (device, opened) = await server.SeedLibraryAsync();
        var inspected = await api.InspectAsync(RealServer.Address, TestContext.Current.CancellationToken);
        var stored = new StoredServer(inspected.Info.ServerId, inspected.Info.Name, inspected.Address, inspected.Fingerprint,
            device.Token, device.SessionId, device.ExpiresAt, device.User);
        var profile = new ProfileSession(opened.User, opened.SessionId, opened.Token, opened.ExpiresAt);
        var client = new LibraryClient(api, stored, profile, inspected.Info.Capabilities ?? []);
        var store = new LibraryStore(client, new ArtworkCache(null), new GeneralPreferences(new MemorySettingsStore()),
            failure => throw new InvalidOperationException("Unexpected session failure: " + failure.Code));
        await store.RefreshAsync();
        Assert.True(store.Error is null, store.Error);
        return store;
    }

    [Fact]
    public async Task LoadsHomeTheCatalogAndPagesWithFiltersAndSearch()
    {
        var store = await OpenLibraryAsync();
        Assert.NotNull(store.Home);
        Assert.Equal(3, store.Catalog.Count(item => item.Kind is MediaKind.Movie or MediaKind.Series));

        var movies = await store.BrowseAsync(BrowseSection.Movies, BrowseQuery.DefaultFor(BrowseSection.Movies), "", TestContext.Current.CancellationToken);
        Assert.Equal(2, movies.Count);
        Assert.All(movies, item => Assert.Equal(MediaKind.Movie, item.Kind));

        var shows = await store.BrowseAsync(BrowseSection.TvShows, BrowseQuery.DefaultFor(BrowseSection.TvShows), "", TestContext.Current.CancellationToken);
        Assert.Equal("Cobalt Station", Assert.Single(shows).Title);

        var found = await store.BrowseAsync(BrowseSection.Library, new BrowseQuery(), "Alpha", TestContext.Current.CancellationToken);
        Assert.Contains(found, item => item.Title.StartsWith("Alpha", StringComparison.Ordinal));
        Assert.DoesNotContain(found, item => item.Title.StartsWith("Beta", StringComparison.Ordinal));

        var sorted = await store.BrowseAsync(BrowseSection.Movies, new BrowseQuery(Kind: MediaKind.Movie, Sort: BrowseSort.Title, Descending: true), "", TestContext.Current.CancellationToken);
        Assert.StartsWith("Beta", sorted[0].Title, StringComparison.Ordinal);

        var alpha = movies.Single(item => item.Title.StartsWith("Alpha", StringComparison.Ordinal));
        Assert.True(await store.SetFavoriteAsync(alpha, true));
        var favorites = await store.BrowseAsync(BrowseSection.Movies, new BrowseQuery(Kind: MediaKind.Movie, FavoritesOnly: true), "", TestContext.Current.CancellationToken);
        Assert.Equal(alpha.Id, Assert.Single(favorites).Id);
        Assert.Contains(store.Home!.Favorites, item => item.Id == alpha.Id);

        var unwatched = await store.BrowseAsync(BrowseSection.Library, new BrowseQuery(WatchState: CatalogWatchState.Unplayed), "", TestContext.Current.CancellationToken);
        Assert.NotEmpty(unwatched);
    }

    [Fact]
    public async Task ShowsASeriesWithItsEpisodesAndMarksItWatched()
    {
        var store = await OpenLibraryAsync();
        var series = store.Catalog.Single(item => item.Kind == MediaKind.Series);
        var detail = await store.Client.DetailAsync(series.Id, TestContext.Current.CancellationToken);
        var season = Assert.Single(detail.Seasons);
        Assert.Equal(1, season.Number);
        Assert.Equal([1, 2], season.Episodes.Select(e => e.EpisodeNumber));

        var plan = await store.Client.PlaybackPlanAsync(series.Id, TestContext.Current.CancellationToken);
        Assert.Equal(PlaybackPlanAction.Play, plan.Action);
        Assert.Equal(1, plan.Target?.EpisodeNumber);

        var state = await store.WatchStateAsync(series.Id, WatchStateScope.Series, null);
        Assert.NotNull(state);
        Assert.Equal(2, state.AffectedCount);
        Assert.True(await store.SetWatchedAsync(state, watched: true));
        var after = await store.Client.DetailAsync(series.Id, TestContext.Current.CancellationToken);
        Assert.All(after.Seasons[0].Episodes, e => Assert.Equal(CatalogWatchState.Completed, e.Item.WatchState));

        var seasonState = await store.WatchStateAsync(series.Id, WatchStateScope.Season, 1);
        Assert.Equal(2, seasonState!.AffectedCount);
        Assert.True(await store.SetWatchedAsync(seasonState, watched: false));
        var reset = await store.Client.DetailAsync(series.Id, TestContext.Current.CancellationToken);
        Assert.All(reset.Seasons[0].Episodes, e => Assert.NotEqual(CatalogWatchState.Completed, e.Item.WatchState));
    }

    [Fact]
    public async Task KeepsAWatchlistAndCollections()
    {
        var store = await OpenLibraryAsync();
        var movies = store.Catalog.Where(item => item.Kind == MediaKind.Movie).ToList();
        Assert.True(store.Client.SupportsWatchlist);
        Assert.True(await store.SetWatchlistAsync(movies[0].Id, true));
        Assert.True(store.IsWatchlisted(movies[0].Id));
        Assert.Contains((await store.Client.WatchlistAsync(TestContext.Current.CancellationToken)).Items, item => item.Id == movies[0].Id);

        var editor = new CollectionEditorModel(store.Catalog, null, null, canShare: true);
        Assert.False(editor.CanSave);
        editor.Name = "Weekend";
        editor.Overview = "Curated test box.";
        editor.SortMode = "custom";
        Assert.True(editor.CanSave);
        editor.Toggle(movies[0]);
        editor.Toggle(movies[1]);
        var standard = await store.SaveCollectionAsync(null, editor.Request());
        Assert.NotNull(standard);
        Assert.True(standard.CanEdit);
        Assert.Contains(store.Collections, c => c.Id == standard.Id && c.Items.Count == 2);

        var loaded = await store.CollectionAsync(standard.Id);
        Assert.NotNull(loaded);
        Assert.Equal("Curated test box.", loaded.Overview);
        Assert.Equal(2, loaded.Members.Count);
        var reordered = await store.UpdateCollectionOrderAsync(standard.Id,
            [new CollectionMemberInput(movies[1].Id), new CollectionMemberInput(movies[0].Id)], "custom");
        Assert.NotNull(reordered);
        Assert.Equal(movies[1].Id, reordered.Members[0].MediaId);
        var next = await store.Client.CollectionNextAsync(standard.Id, TestContext.Current.CancellationToken);
        Assert.Equal(movies[1].Id, next.Item.Id);

        var smart = new CollectionEditorModel(store.Catalog, null, null, canShare: true) { Name = "All Movies", IsSmart = true, Kind = "movie" };
        Assert.Equal(2, smart.MatchingCount);
        var saved = await store.SaveCollectionAsync(null, smart.Request());
        Assert.NotNull(saved);
        Assert.True(saved.IsSmart);
        var listed = (await store.Client.CollectionsAsync(TestContext.Current.CancellationToken)).Single(c => c.Id == saved.Id);
        Assert.Equal(2, listed.TotalCount);
        Assert.Contains("\"kind\":\"movie\"", listed.RulesJson, StringComparison.Ordinal);

        Assert.True(await store.RemoveFromCollectionAsync(standard.Id, movies[1].Id));
        Assert.Single(store.Collections.Single(c => c.Id == standard.Id).Items);
        Assert.True(await store.DeleteCollectionAsync(standard.Id));
        Assert.DoesNotContain(store.Collections, c => c.Id == standard.Id);

        var franchises = await store.Client.FranchisesAsync(TestContext.Current.CancellationToken);
        Assert.NotNull(franchises);
    }

    [Fact]
    public async Task ReadsHistoryStatisticsAndSyncChanges()
    {
        var store = await OpenLibraryAsync();
        var history = await store.Client.HistoryAsync(0, 50, TestContext.Current.CancellationToken);
        Assert.Equal(0, history.Total);
        var statistics = await store.Client.StatisticsAsync(TestContext.Current.CancellationToken);
        Assert.Equal(0, statistics.TotalHoursWatched);

        var first = await store.Client.ChangesAsync(0, 0, null, TestContext.Current.CancellationToken);
        Assert.True(first.Cursor >= 0);
        var movie = store.Catalog.First(item => item.Kind == MediaKind.Movie);
        await store.SetFavoriteAsync(movie, true);
        var next = await store.Client.ChangesAsync(first.Cursor, 0, first.Generation, TestContext.Current.CancellationToken);
        Assert.True(next.Cursor > first.Cursor);
        Assert.Contains(SyncChangeArea.UserState, next.ChangedAreas);
        await store.ApplyChangesAsync(next);
        Assert.True(store.Catalog.Single(item => item.Id == movie.Id).IsFavorite);
    }
}
