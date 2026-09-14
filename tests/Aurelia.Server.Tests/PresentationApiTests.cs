using System.Net;
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
            using var detailResponse = await client.SendAsync(detailRequest);
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
            Assert.Equal(HttpStatusCode.BadRequest, (await client.SendAsync(invalidKind)).StatusCode);

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
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<T>(response);
    }

    private sealed class AdjustableTimeProvider(DateTimeOffset initial) : TimeProvider
    {
        public DateTimeOffset UtcNow { get; set; } = initial;
        public override DateTimeOffset GetUtcNow() => UtcNow;
    }
}
