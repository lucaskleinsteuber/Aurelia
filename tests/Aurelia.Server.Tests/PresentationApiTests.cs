using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class PresentationApiTests
{
    [Fact]
    public async Task PresentationCatalogPaginatesFiltersAndBundlesSeriesDetailsWithoutPaths()
    {
        var fixture = TestPaths.CreateDataDirectory();
        var movies = Path.Combine(fixture, "Movies");
        var shows = Path.Combine(fixture, "Shows");
        Touch(movies, "First Movie.mkv");
        Touch(movies, "Second Movie.mkv");
        Touch(shows, "Example Show/Season 1/Example Show S01E01 Pilot.mkv");
        Touch(shows, "Example Show/Season 1/Example Show S01E02 Second.mkv");
        Touch(shows, "Example Show/Season 1/Extras/Behind the Scenes.mkv");
        Touch(shows, "Example Show/Extras/Series Retrospective.mkv");

        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            await ScanAsync(client, owner.Token, movies, LibraryKind.Movies);
            await ScanAsync(client, owner.Token, shows, LibraryKind.TvShows);

            var firstPage = await SendAsync<PagedResponse<CatalogItemSummary>>(
                client, owner.Token, "/api/v1/catalog/items?offset=0&limit=2");
            var secondPage = await SendAsync<PagedResponse<CatalogItemSummary>>(
                client, owner.Token, "/api/v1/catalog/items?offset=2&limit=2");
            Assert.Equal(3, firstPage.Total);
            Assert.Equal(2, firstPage.Items.Count);
            Assert.Single(secondPage.Items);
            Assert.Empty(firstPage.Items.Select(item => item.Id).Intersect(secondPage.Items.Select(item => item.Id)));

            var moviePage = await SendAsync<PagedResponse<CatalogItemSummary>>(
                client, owner.Token, "/api/v1/catalog/items?kind=movie&offset=0&limit=200");
            Assert.Equal(2, moviePage.Total);
            Assert.All(moviePage.Items, item => Assert.Equal(MediaKind.Movie, item.Kind));

            var show = Assert.Single((await SendAsync<PagedResponse<CatalogItemSummary>>(
                client, owner.Token, "/api/v1/catalog/items?kind=series&offset=0&limit=200")).Items);
            using var detailRequest = ApiTestClient.Authorized(
                HttpMethod.Get, $"/api/v1/catalog/items/{show.Id}", owner.Token);
            using var detailResponse = await ApiTestClient.SendAsync(client, detailRequest);
            detailResponse.EnsureSuccessStatusCode();
            var json = await detailResponse.Content.ReadAsStringAsync();
            Assert.DoesNotContain(fixture, json, StringComparison.Ordinal);
            var detail = await ApiTestClient.ReadAsync<CatalogDetailPresentation>(detailResponse);
            var season = Assert.Single(detail.Seasons);
            Assert.Equal(2, season.Episodes.Count);
            Assert.Single(season.Supplements);
            Assert.Single(detail.Supplements);

            var episodeSearch = await SendAsync<PagedResponse<CatalogItemSummary>>(
                client, owner.Token, "/api/v1/catalog/search?query=Season%201");
            Assert.Equal(2, episodeSearch.Total);
            Assert.All(episodeSearch.Items, item =>
            {
                Assert.Equal(MediaKind.Episode, item.Kind);
                Assert.Equal("Example Show", item.ParentTitle);
                Assert.Equal(1, item.SeasonNumber);
                Assert.NotNull(item.EpisodeNumber);
            });

            using var invalidKind = ApiTestClient.Authorized(
                HttpMethod.Get, "/api/v1/catalog/items?kind=episode", owner.Token);
            Assert.Equal(HttpStatusCode.BadRequest, (await ApiTestClient.SendAsync(client, invalidKind)).StatusCode);

            // The Build 9 catalog remains available to existing clients.
            var legacy = await SendAsync<PagedResponse<SeriesSummary>>(
                client, owner.Token, "/api/v1/catalog/series");
            Assert.Single(legacy.Items);
        }
        finally
        {
            if (Directory.Exists(fixture)) Directory.Delete(fixture, recursive: true);
        }
    }

    [Fact]
    public async Task ContinueWatchingPublishesSavedEpisodesAndMoviesAndResumesTheExactFilePerUser()
    {
        var fixture = TestPaths.CreateDataDirectory();
        var movies = Path.Combine(fixture, "Movies");
        var shows = Path.Combine(fixture, "Shows");
        Touch(movies, "Example Movie.mkv");
        Touch(shows, "Example Show/Season 1/Example Show S01E01 Pilot.mkv");

        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            await ScanAsync(client, owner.Token, movies, LibraryKind.Movies);
            await ScanAsync(client, owner.Token, shows, LibraryKind.TvShows);
            var catalog = await SendAsync<PagedResponse<CatalogItemSummary>>(
                client, owner.Token, "/api/v1/catalog/items");
            var movie = Assert.Single(catalog.Items, item => item.Kind == MediaKind.Movie);
            var show = Assert.Single(catalog.Items, item => item.Kind == MediaKind.Series);
            var detail = await SendAsync<CatalogDetailPresentation>(
                client, owner.Token, $"/api/v1/catalog/items/{show.Id}");
            var episode = Assert.Single(Assert.Single(detail.Seasons).Episodes).Item;
            var episodeSummary = await SendAsync<CatalogItemSummary>(
                client, owner.Token, $"/api/v1/catalog/items/{episode.Id}/summary");
            Assert.Equal(episode.Id, episodeSummary.Id);
            Assert.Equal(episode.Title, episodeSummary.Title);
            Assert.Equal(episode.ParentTitle, episodeSummary.ParentTitle);
            using (var anonymous = await client.GetAsync($"/api/v1/catalog/items/{episode.Id}/summary"))
                Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
            Assert.DoesNotContain(catalog.Items, item => item.Id == episode.Id);
            Assert.Empty((await SendAsync<HomeResponse>(client, owner.Token, "/api/v1/home")).ContinueWatching);
            var before = await SendAsync<SyncChangesResponse>(
                client, owner.Token, "/api/v1/sync/changes?after=0&waitSeconds=0");

            await SendAsync<PlaybackProgressResponse>(client, owner.Token,
                $"/api/v1/media/{episode.Id}/progress", HttpMethod.Put,
                new UpdatePlaybackProgressRequest(20_000, 120_000, false));
            var resumed = Assert.Single((await SendAsync<HomeResponse>(
                client, owner.Token, "/api/v1/home")).ContinueWatching);
            Assert.Equal(episode.Id, resumed.Id);
            Assert.Equal(MediaKind.Episode, resumed.Kind);
            Assert.Equal(show.Title, resumed.ParentTitle);
            Assert.Equal(1, resumed.SeasonNumber);
            Assert.Equal(1, resumed.EpisodeNumber);
            Assert.Equal(20_000, resumed.Progress!.PositionMilliseconds);
            var savedSummary = await SendAsync<CatalogItemSummary>(
                client, owner.Token, $"/api/v1/catalog/items/{episode.Id}/summary");
            Assert.Equal(resumed.Progress, savedSummary.Progress);
            Assert.Equal(1, savedSummary.Progress!.Revision);
            var changes = await SendAsync<SyncChangesResponse>(
                client, owner.Token, $"/api/v1/sync/changes?after={before.Cursor}&waitSeconds=0");
            Assert.Contains(SyncChangeArea.UserState, changes.ChangedAreas);
            Assert.Contains(episode.Id, changes.ChangedMediaIds);

            var playback = await SendAsync<PlaybackSourceResponse>(client, owner.Token,
                $"/api/v1/media/{resumed.Id}/playback", HttpMethod.Post);
            Assert.Equal(episode.Id, playback.MediaId);
            Assert.Equal(20_000, playback.Progress.PositionMilliseconds);
            using (var stream = ApiTestClient.Authorized(HttpMethod.Get, playback.StreamPath, owner.Token))
            {
                stream.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(0, 0);
                using var response = await ApiTestClient.SendAsync(client, stream);
                Assert.Equal(HttpStatusCode.PartialContent, response.StatusCode);
                Assert.Equal(new byte[] { 1 }, await response.Content.ReadAsByteArrayAsync());
            }
            await SendAsync<PlaybackProgressResponse>(client, owner.Token,
                $"/api/v1/media/{movie.Id}/progress", HttpMethod.Put,
                new UpdatePlaybackProgressRequest(30_000, 120_000, false));
            Assert.Equal(2, (await SendAsync<HomeResponse>(client, owner.Token, "/api/v1/home")).ContinueWatching.Count);

            await SendAsync<UserSummary>(client, owner.Token, "/api/v1/users", HttpMethod.Post,
                new CreateUserRequest("viewer", "a secure viewer password", UserRole.User, ApiTestClient.TestPin));
            using var login = await ApiTestClient.LoginAsync(client, new LoginRequest("viewer", "a secure viewer password", "Viewer Mac"));
            login.EnsureSuccessStatusCode();
            var viewer = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
            Assert.Empty((await SendAsync<HomeResponse>(client, viewer.Token, "/api/v1/home")).ContinueWatching);
            await ApiTestClient.GrantExistingLibrariesAsync(client, owner.Token, viewer.User.Id);
            await SendAsync<PlaybackProgressResponse>(client, viewer.Token,
                $"/api/v1/media/{episode.Id}/progress", HttpMethod.Put,
                new UpdatePlaybackProgressRequest(40_000, 120_000, false));
            Assert.Equal(40_000, Assert.Single((await SendAsync<HomeResponse>(
                client, viewer.Token, "/api/v1/home")).ContinueWatching).Progress!.PositionMilliseconds);
            Assert.Equal(20_000, (await SendAsync<HomeResponse>(client, owner.Token, "/api/v1/home"))
                .ContinueWatching.Single(item => item.Id == episode.Id).Progress!.PositionMilliseconds);

            // Finished and deliberately restarted titles are removed; another user's Home is unchanged.
            await SendAsync<PlaybackProgressResponse>(client, viewer.Token,
                $"/api/v1/media/{episode.Id}/progress", HttpMethod.Put,
                new UpdatePlaybackProgressRequest(120_000, 120_000, true));
            Assert.Empty((await SendAsync<HomeResponse>(client, viewer.Token, "/api/v1/home")).ContinueWatching);
            await SendAsync<PlaybackProgressResponse>(client, owner.Token,
                $"/api/v1/media/{episode.Id}/progress", HttpMethod.Put,
                new UpdatePlaybackProgressRequest(0, 120_000, false));
            Assert.Equal(movie.Id, Assert.Single((await SendAsync<HomeResponse>(
                client, owner.Token, "/api/v1/home")).ContinueWatching).Id);
        }
        finally
        {
            if (Directory.Exists(fixture)) Directory.Delete(fixture, recursive: true);
        }
    }

    [Fact]
    public async Task HomeRecommendationIsUserStableUntilTheReportedHourBoundary()
    {
        var fixture = TestPaths.CreateDataDirectory();
        var movies = Path.Combine(fixture, "Movies");
        for (var index = 1; index <= 6; index++) Touch(movies, $"Movie {index}.mkv");
        var clock = new AdjustableTimeProvider(new DateTimeOffset(2026, 9, 12, 10, 15, 0, TimeSpan.Zero));

        try
        {
            using var factory = new AureliaServerFactory(configureServices: services =>
            {
                services.RemoveAll<TimeProvider>();
                services.AddSingleton<TimeProvider>(clock);
            });
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            await ScanAsync(client, owner.Token, movies, LibraryKind.Movies);

            var first = await SendAsync<HomeResponse>(client, owner.Token, "/api/v1/home");
            var repeated = await SendAsync<HomeResponse>(client, owner.Token, "/api/v1/home");
            Assert.Equal(first.Recommendation?.Id, repeated.Recommendation?.Id);
            Assert.Equal(new DateTimeOffset(2026, 9, 12, 11, 0, 0, TimeSpan.Zero), first.RecommendationChangesAt);

            var initial = first.Recommendation?.Id;
            var changed = false;
            for (var hour = 1; hour <= 24 && !changed; hour++)
            {
                clock.UtcNow = new DateTimeOffset(2026, 9, 12, 10, 15, 0, TimeSpan.Zero).AddHours(hour);
                var next = await SendAsync<HomeResponse>(client, owner.Token, "/api/v1/home");
                changed = next.Recommendation?.Id != initial;
                Assert.Equal(clock.UtcNow.AddMinutes(-15).AddHours(1), next.RecommendationChangesAt);
            }
            Assert.True(changed, "The stable recommendation should change at an hourly boundary.");
        }
        finally
        {
            if (Directory.Exists(fixture)) Directory.Delete(fixture, recursive: true);
        }
    }

    private static void Touch(string root, string relativePath)
    {
        var path = Path.Combine(root, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, [1]);
    }

    private static async Task ScanAsync(
        HttpClient client,
        string token,
        string path,
        LibraryKind kind)
    {
        var library = await SendAsync<LibrarySummary>(
            client, token, "/api/v1/libraries", HttpMethod.Post,
            new CreateLibraryRequest(null, path, kind));
        var scan = await SendAsync<LibraryScanSummary>(
            client, token, $"/api/v1/libraries/{library.Id}/scans", HttpMethod.Post);
        for (var attempt = 0; attempt < 100; attempt++)
        {
            scan = await SendAsync<LibraryScanSummary>(client, token, $"/api/v1/scans/{scan.Id}");
            if (scan.State == LibraryScanState.Completed) return;
            await Task.Delay(20);
        }
        throw new TimeoutException("Scan did not finish.");
    }

    private static async Task<T> SendAsync<T>(
        HttpClient client,
        string token,
        string path,
        HttpMethod? method = null,
        object? body = null)
    {
        using var request = ApiTestClient.Authorized(method ?? HttpMethod.Get, path, token, body);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<T>(response);
    }

    private sealed class AdjustableTimeProvider(DateTimeOffset initial) : TimeProvider
    {
        public DateTimeOffset UtcNow { get; set; } = initial;
        public override DateTimeOffset GetUtcNow() => UtcNow;
    }
}
