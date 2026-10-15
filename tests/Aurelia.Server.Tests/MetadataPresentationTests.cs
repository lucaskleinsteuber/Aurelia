using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class MetadataPresentationTests
{
    [Fact]
    public async Task MetadataEnrichmentFeedsSearchHomeFavoritesAndArtworkWithoutExposingToken()
    {
        var mediaRoot = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaRoot);
        await File.WriteAllBytesAsync(Path.Combine(mediaRoot, "El Camino (2019).mkv"), [1, 2, 3]);
        try
        {
            using var factory = CreateFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await SendAsync<LibrarySummary>(client, owner.Token, HttpMethod.Post, "/api/v1/libraries",
                new CreateLibraryRequest("Movies", mediaRoot, LibraryKind.Movies));
            var scan = await SendAsync<LibraryScanSummary>(client, owner.Token, HttpMethod.Post, $"/api/v1/libraries/{library.Id}/scans");
            await WaitForScanAsync(client, owner.Token, scan.Id);
            var moviePage = await SendAsync<PagedResponse<MovieSummary>>(client, owner.Token, HttpMethod.Get, "/api/v1/catalog/movies");
            var movie = Assert.Single(moviePage.Items);

            var status = await SendAsync<MetadataProviderStatus>(client, owner.Token, HttpMethod.Put, "/api/v1/metadata/provider",
                new UpdateMetadataProviderRequest(true, "en-US", "test-token-value-with-more-than-thirty-two-characters"));
            Assert.True(status.Enabled);
            Assert.True(status.HasToken);
            var job = await SendAsync<MetadataJobSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/metadata/jobs");
            job = await WaitForMetadataAsync(client, owner.Token, job.Id);
            Assert.True(job.State == MetadataJobState.Completed, job.Error);
            Assert.Equal(1, job.ItemsMatched);

            var metadata = await SendAsync<MediaMetadataSummary>(client, owner.Token, HttpMethod.Get, $"/api/v1/media/{movie.Id}/metadata");
            Assert.Equal("El Camino: A Breaking Bad Movie", metadata.Title);
            Assert.Equal("tmdb", metadata.Provider);
            Assert.Equal(7.0, metadata.Rating);
            Assert.Equal("R", metadata.ContentRating);
            Assert.NotNull(metadata.Poster);
            Assert.DoesNotContain("test-token", JsonContent(metadata), StringComparison.Ordinal);

            using var artworkRequest = ApiTestClient.Authorized(HttpMethod.Get, metadata.Poster!.Path, owner.Token);
            using var artworkResponse = await ApiTestClient.SendAsync(client, artworkRequest);
            Assert.Equal(HttpStatusCode.OK, artworkResponse.StatusCode);
            Assert.Equal("image/jpeg", artworkResponse.Content.Headers.ContentType?.MediaType);
            using var unauthenticatedArtwork = await client.GetAsync(metadata.Poster.Path);
            Assert.Equal(HttpStatusCode.Unauthorized, unauthenticatedArtwork.StatusCode);

            _ = await SendAsync<bool>(client, owner.Token, HttpMethod.Put, $"/api/v1/media/{movie.Id}/favorite", new SetFavoriteRequest(true));
            var home = await SendAsync<HomeResponse>(client, owner.Token, HttpMethod.Get, "/api/v1/home");
            Assert.Equal(movie.Id, Assert.Single(home.Favorites).Id);
            Assert.Equal(movie.Id, home.Recommendation?.Id);
            var search = await SendAsync<PagedResponse<CatalogItemSummary>>(client, owner.Token, HttpMethod.Get, "/api/v1/catalog/search?query=breaking");
            Assert.Equal(movie.Id, Assert.Single(search.Items).Id);
            var personSearch = await SendAsync<PagedResponse<CatalogItemSummary>>(client, owner.Token, HttpMethod.Get, "/api/v1/catalog/search?query=Aaron%20Paul");
            Assert.Equal(movie.Id, Assert.Single(personSearch.Items).Id);

            var secretPath = Path.Combine(factory.DataDirectory, "Secrets", "tmdb-token");
            Assert.Equal("test-token-value-with-more-than-thirty-two-characters", await File.ReadAllTextAsync(secretPath));
            Assert.DoesNotContain("test-token", await File.ReadAllTextAsync(Path.Combine(factory.DataDirectory, "metadata-settings.json")), StringComparison.Ordinal);
        }
        finally { Directory.Delete(mediaRoot, recursive: true); }
    }

    [Fact]
    public async Task AmbiguousMatchesNeedReviewAndManualFieldsSurviveProviderRemoval()
    {
        var mediaRoot = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaRoot);
        await File.WriteAllBytesAsync(Path.Combine(mediaRoot, "Unknown Movie.mkv"), [1]);
        try
        {
            using var factory = CreateFactory(ambiguous: true);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await SendAsync<LibrarySummary>(client, owner.Token, HttpMethod.Post, "/api/v1/libraries",
                new CreateLibraryRequest("Movies", mediaRoot, LibraryKind.Movies));
            var scan = await SendAsync<LibraryScanSummary>(client, owner.Token, HttpMethod.Post, $"/api/v1/libraries/{library.Id}/scans");
            await WaitForScanAsync(client, owner.Token, scan.Id);
            var movie = Assert.Single((await SendAsync<PagedResponse<MovieSummary>>(client, owner.Token, HttpMethod.Get, "/api/v1/catalog/movies")).Items);
            _ = await SendAsync<MetadataProviderStatus>(client, owner.Token, HttpMethod.Put, "/api/v1/metadata/provider",
                new UpdateMetadataProviderRequest(true, "en", "test-token-value-with-more-than-thirty-two-characters"));
            var job = await SendAsync<MetadataJobSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/metadata/jobs");
            job = await WaitForMetadataAsync(client, owner.Token, job.Id);
            Assert.Equal(1, job.ItemsNeedingReview);
            var review = Assert.Single(await SendAsync<List<MetadataReviewSummary>>(
                client, owner.Token, HttpMethod.Get, "/api/v1/metadata/reviews"));
            Assert.Equal("Several similar TMDB matches need confirmation.", review.Reason);

            var edited = await SendAsync<MediaMetadataSummary>(client, owner.Token, HttpMethod.Put, $"/api/v1/media/{movie.Id}/metadata",
                new UpdateMediaMetadataRequest(Title: "My Title", Overview: "My description", Genres: ["Drama"]));
            Assert.Equal("My Title", edited.Title);
            var selected = await SendAsync<MediaMetadataSummary>(client, owner.Token, HttpMethod.Put, $"/api/v1/media/{movie.Id}/metadata/match",
                new SelectMetadataMatchRequest("559", "movie"));
            Assert.Equal("My Title", selected.Title);
            Assert.Equal("My description", selected.Overview);
            var cleared = await SendAsync<MediaMetadataSummary>(client, owner.Token, HttpMethod.Delete, $"/api/v1/media/{movie.Id}/metadata/match");
            Assert.Equal("My Title", cleared.Title);
            Assert.Null(cleared.Provider);
        }
        finally { Directory.Delete(mediaRoot, recursive: true); }
    }

    [Fact]
    public async Task MissingProviderResultsUseADistinctReviewReason()
    {
        var mediaRoot = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaRoot);
        await File.WriteAllBytesAsync(Path.Combine(mediaRoot, "No Match Movie.mkv"), [1]);
        try
        {
            using var factory = CreateFactory(noResults: true);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await SendAsync<LibrarySummary>(
                client,
                owner.Token,
                HttpMethod.Post,
                "/api/v1/libraries",
                new CreateLibraryRequest("Movies", mediaRoot, LibraryKind.Movies));
            var scan = await SendAsync<LibraryScanSummary>(
                client,
                owner.Token,
                HttpMethod.Post,
                $"/api/v1/libraries/{library.Id}/scans");
            await WaitForScanAsync(client, owner.Token, scan.Id);
            _ = await SendAsync<MetadataProviderStatus>(
                client,
                owner.Token,
                HttpMethod.Put,
                "/api/v1/metadata/provider",
                new UpdateMetadataProviderRequest(
                    true,
                    "en",
                    "test-token-value-with-more-than-thirty-two-characters"));
            var job = await SendAsync<MetadataJobSummary>(
                client,
                owner.Token,
                HttpMethod.Post,
                "/api/v1/metadata/jobs");
            job = await WaitForMetadataAsync(client, owner.Token, job.Id);
            Assert.Equal(1, job.ItemsNeedingReview);
            var review = Assert.Single(await SendAsync<List<MetadataReviewSummary>>(
                client,
                owner.Token,
                HttpMethod.Get,
                "/api/v1/metadata/reviews"));
            Assert.Empty(review.Candidates);
            Assert.Equal("TMDB returned no results for the detected title.", review.Reason);
        }
        finally { Directory.Delete(mediaRoot, recursive: true); }
    }

    [Fact]
    public async Task RegularUsersCannotConfigureMetadataButHaveSeparateFavorites()
    {
        using var factory = CreateFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var user = await SendAsync<UserSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/users",
            new CreateUserRequest("viewer", "another correct horse password", UserRole.User, ApiTestClient.TestPin));
        Assert.Equal(UserRole.User, user.Role);
        using var login = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/auth/login", owner.Token,
            new LoginRequest("viewer", "another correct horse password", "Viewer Mac"));
        using var loginResponse = await ApiTestClient.SendAsync(client, login);
        var authentication = await ApiTestClient.ReadAsync<AuthenticationResponse>(loginResponse);
        using var forbidden = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/metadata/provider", authentication.Token);
        Assert.Equal(HttpStatusCode.Forbidden, (await ApiTestClient.SendAsync(client, forbidden)).StatusCode);
        var home = await SendAsync<HomeResponse>(client, authentication.Token, HttpMethod.Get, "/api/v1/home");
        Assert.Empty(home.Favorites);
    }

    [Fact]
    public async Task OwnerCanMaintainManualCollectionsWhileRegularUsersCannot()
    {
        var mediaRoot = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaRoot);
        await File.WriteAllBytesAsync(Path.Combine(mediaRoot, "First Movie.mkv"), [1]);
        await File.WriteAllBytesAsync(Path.Combine(mediaRoot, "Second Movie.mkv"), [2]);
        try
        {
            using var factory = CreateFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await SendAsync<LibrarySummary>(client, owner.Token, HttpMethod.Post, "/api/v1/libraries",
                new CreateLibraryRequest("Movies", mediaRoot, LibraryKind.Movies));
            var scan = await SendAsync<LibraryScanSummary>(client, owner.Token, HttpMethod.Post, $"/api/v1/libraries/{library.Id}/scans");
            await WaitForScanAsync(client, owner.Token, scan.Id);
            var movies = (await SendAsync<PagedResponse<MovieSummary>>(client, owner.Token, HttpMethod.Get, "/api/v1/catalog/movies")).Items;
            Assert.Equal(2, movies.Count);

            var created = await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/collections",
                new SaveCollectionRequest("My Movies", movies.Select(movie => movie.Id).ToList()));
            Assert.Equal("My Movies", created.Name);
            Assert.Equal(2, created.Items.Count);

            var updated = await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Put, $"/api/v1/collections/{created.Id}",
                new SaveCollectionRequest("Movie Night", movies.Reverse().Select(movie => movie.Id).ToList()));
            Assert.Equal("Movie Night", updated.Name);
            Assert.Equal(movies[1].Id, updated.Items[0].Id);

            var user = await SendAsync<UserSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/users",
                new CreateUserRequest("viewer", "another correct horse password", UserRole.User, ApiTestClient.TestPin));
            Assert.Equal(UserRole.User, user.Role);
            using var login = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/auth/login", owner.Token,
                new LoginRequest("viewer", "another correct horse password", "Viewer Mac"));
            using var loginResponse = await ApiTestClient.SendAsync(client, login);
            var authentication = await ApiTestClient.ReadAsync<AuthenticationResponse>(loginResponse);
            using var forbidden = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/collections/{created.Id}", authentication.Token);
            Assert.Equal(HttpStatusCode.Forbidden, (await ApiTestClient.SendAsync(client, forbidden)).StatusCode);

            using var delete = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/collections/{created.Id}", owner.Token);
            Assert.Equal(HttpStatusCode.NoContent, (await ApiTestClient.SendAsync(client, delete)).StatusCode);
            Assert.Empty(await SendAsync<List<CollectionSummary>>(client, owner.Token, HttpMethod.Get, "/api/v1/catalog/collections"));
        }
        finally { Directory.Delete(mediaRoot, recursive: true); }
    }

    [Fact]
    public async Task TmdbClientReportsRateLimitsToTheDurableJobScheduler()
    {
        var handler = new RateLimitedHandler();
        using var client = new HttpClient(handler);
        var tmdb = new TmdbClient(client);

        var error = await Assert.ThrowsAsync<MetadataProviderException>(() => tmdb.ValidateAsync("temporary-test-token", CancellationToken.None));
        Assert.True(error.Transient);
        Assert.False(error.AuthenticationFailure);
        Assert.Equal(1, handler.RequestCount);
        Assert.All(handler.AuthorizationValues, value => Assert.Equal("Bearer temporary-test-token", value));
    }

    private static AureliaServerFactory CreateFactory(
        bool ambiguous = false,
        bool noResults = false) => new(
        configureServices: services =>
        {
            services.RemoveAll<ITmdbClient>();
            services.AddSingleton<ITmdbClient>(new FakeTmdbClient(ambiguous, noResults));
        });

    private static async Task<T> SendAsync<T>(HttpClient client, string token, HttpMethod method, string path, object? body = null)
    {
        using var request = ApiTestClient.Authorized(method, path, token, body);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<T>(response);
    }

    private static async Task WaitForScanAsync(HttpClient client, string token, Guid id)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            var scan = await SendAsync<LibraryScanSummary>(client, token, HttpMethod.Get, $"/api/v1/scans/{id}");
            if (scan.State == LibraryScanState.Completed) return;
            await Task.Delay(20);
        }
        throw new TimeoutException("Scan did not finish.");
    }

    private static async Task<MetadataJobSummary> WaitForMetadataAsync(HttpClient client, string token, Guid id)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            var job = await SendAsync<MetadataJobSummary>(client, token, HttpMethod.Get, $"/api/v1/metadata/jobs/{id}");
            if (job.State is MetadataJobState.Completed or MetadataJobState.Failed) return job;
            await Task.Delay(20);
        }
        throw new TimeoutException("Metadata did not finish.");
    }

    private static string JsonContent<T>(T value) => System.Text.Json.JsonSerializer.Serialize(value, ApiTestClient.JsonOptions);

    private sealed class FakeTmdbClient(bool ambiguous, bool noResults) : ITmdbClient
    {
        public Task ValidateAsync(string token, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(string token, string language, MediaKind kind, string title, int? year, CancellationToken cancellationToken)
        {
            IReadOnlyList<MetadataCandidateSummary> values = noResults
                ? []
                : ambiguous
                ? [new("tmdb", "559", "movie", "Unknown", null, null, null, null, 0.8), new("tmdb", "560", "movie", "Unknown Again", null, null, null, null, 0.78)]
                : [new("tmdb", "559", kind == MediaKind.Movie ? "movie" : "tv", "El Camino: A Breaking Bad Movie", "El Camino", 2019, "Jesse Pinkman begins again.", "/poster.jpg", 1)];
            return Task.FromResult(values);
        }
        public Task<TmdbMetadata> GetAsync(string token, string language, string mediaType, string providerId, CancellationToken cancellationToken) => Task.FromResult(new TmdbMetadata(
            providerId, mediaType, "El Camino: A Breaking Bad Movie", "El Camino", "Provider description", "2019-10-11", 122, 7.0, "R", ["Crime", "Drama"], ["Netflix"], ["US"], "/poster.jpg", "/backdrop.jpg",
            [new TmdbCredit("1", "Aaron Paul", "Acting", null, "Jesse Pinkman", 0, null)], new TmdbCollectionInfo("62", "Breaking Bad Universe", null)));
        public Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(string token, string language, string seriesProviderId, int seasonNumber, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<TmdbEpisodeMetadata>>([]);
        public Task<byte[]> DownloadImageAsync(string token, string providerPath, string size, CancellationToken cancellationToken) =>
            Task.FromResult<byte[]>([0xff, 0xd8, 1, 2, 3, 4, 0xff, 0xd9, 0, 0, 0, 0, 0xff, 0xd9]);
    }

    private sealed class RateLimitedHandler : HttpMessageHandler
    {
        public int RequestCount { get; private set; }
        public List<string?> AuthorizationValues { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            RequestCount++;
            AuthorizationValues.Add(request.Headers.Authorization?.ToString());
            return Task.FromResult(new HttpResponseMessage(RequestCount < 3 ? HttpStatusCode.TooManyRequests : HttpStatusCode.OK)
            {
                Content = new StringContent("{}"),
            });
        }
    }
}
