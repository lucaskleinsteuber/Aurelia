using System.Net;
using System.Net.Http.Json;
using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Home.Server.Tests;

public sealed class MediaLibraryApiTests
{
    [Fact]
    public async Task AdminCanScanAndUserCatalogDoesNotExposePaths()
    {
        var root = CreateDirectory("Breaking Bad");
        var episodeOne = Touch(root, "Season 1/Breaking Bad S01E01 Pilot.mkv");
        Touch(root, "Season 1/Breaking Bad S01E02 Cat's in the Bag.mkv");
        Touch(root, "Season 1/Extras/Making Of.mkv");
        Touch(root, "Season 1/._Breaking Bad S01E03 AppleDouble.mkv");

        try
        {
            using var factory = new AureliaHomeServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await CreateLibraryAsync(client, owner.Token, root, LibraryKind.TvShows);

            var user = await CreateUserAsync(client, owner.Token);
            var userLogin = await LoginAsync(client, "viewer", "a secure viewer password");
            using (var forbiddenRequest = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       "/api/v1/libraries",
                       userLogin.Token))
            using (var forbiddenResponse = await client.SendAsync(forbiddenRequest))
            {
                Assert.Equal(HttpStatusCode.Forbidden, forbiddenResponse.StatusCode);
            }

            Assert.Equal(UserRole.User, user.Role);
            var firstScan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
            Assert.Equal(LibraryScanState.Completed, firstScan.State);
            Assert.Equal(3, firstScan.FilesDiscovered);
            Assert.Equal(3, firstScan.AddedFiles);
            Assert.Equal(0, firstScan.SkippedFiles);

            var firstCatalog = await GetSeriesCatalogAsync(client, userLogin.Token);
            var series = Assert.Single(firstCatalog.Items);
            Assert.Equal(2, series.EpisodeCount);
            Assert.Equal(1, series.SeasonCount);
            var seriesId = series.Id;

            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
                var storedSeries = await database.MediaItems.FindAsync(seriesId);
                Assert.NotNull(storedSeries);
                storedSeries.OverrideTitle = "My Manual Series Title";
                await database.SaveChangesAsync();
            }

            using (var detailRequest = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       $"/api/v1/catalog/series/{seriesId}",
                       userLogin.Token))
            using (var detailResponse = await client.SendAsync(detailRequest))
            {
                detailResponse.EnsureSuccessStatusCode();
                var json = await detailResponse.Content.ReadAsStringAsync();
                Assert.DoesNotContain(root, json, StringComparison.Ordinal);
                var detail = await ApiTestClient.ReadAsync<SeriesDetail>(detailResponse);
                var season = Assert.Single(detail.Seasons);
                Assert.Equal(2, season.Episodes.Count);
                Assert.Single(season.Supplements);
            }

            var secondScan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
            Assert.Equal(0, secondScan.AddedFiles);
            Assert.Equal(0, secondScan.UpdatedFiles);
            var secondCatalog = await GetSeriesCatalogAsync(client, userLogin.Token);
            var rescannedSeries = Assert.Single(secondCatalog.Items);
            Assert.Equal(seriesId, rescannedSeries.Id);
            Assert.Equal("My Manual Series Title", rescannedSeries.Title);

            File.Delete(episodeOne);
            var missingScan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
            Assert.Equal(1, missingScan.MissingFiles);
            var detailAfterMissing = await GetSeriesDetailAsync(client, userLogin.Token, seriesId);
            Assert.Contains(
                Assert.Single(detailAfterMissing.Seasons).Episodes,
                episode => episode.EpisodeNumber == 1
                    && episode.Availability == MediaAvailability.Missing);

            var offlinePath = root + "-offline";
            Directory.Move(root, offlinePath);
            try
            {
                var offlineScan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
                Assert.Equal(LibraryScanState.Failed, offlineScan.State);
                var libraries = await ListLibrariesAsync(client, owner.Token);
                Assert.Equal(LibraryAvailability.Unavailable, Assert.Single(libraries).Availability);
                var unchanged = await GetSeriesDetailAsync(client, userLogin.Token, seriesId);
                Assert.Contains(
                    Assert.Single(unchanged.Seasons).Episodes,
                    episode => episode.EpisodeNumber == 2
                        && episode.Availability == MediaAvailability.Available);
            }
            finally
            {
                Directory.Move(offlinePath, root);
            }

            using (var invalidPage = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       "/api/v1/catalog/series?limit=0",
                       userLogin.Token))
            using (var invalidPageResponse = await client.SendAsync(invalidPage))
            {
                Assert.Equal(HttpStatusCode.BadRequest, invalidPageResponse.StatusCode);
            }

            using (var removeRequest = ApiTestClient.Authorized(
                       HttpMethod.Delete,
                       $"/api/v1/libraries/{library.Id}",
                       owner.Token))
            using (var removeResponse = await client.SendAsync(removeRequest))
            {
                Assert.Equal(HttpStatusCode.NoContent, removeResponse.StatusCode);
            }

            Assert.True(File.Exists(Path.Combine(
                root,
                "Season 1",
                "Breaking Bad S01E02 Cat's in the Bag.mkv")));
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public async Task MovieCatalogContainsItsExtrasAndNeverReturnsAPath()
    {
        var root = CreateDirectory("El Camino - A Breaking Bad Movie");
        var moviePath = Touch(root, "El Camino - A Breaking Bad Movie.mkv");
        Touch(root, "Extras/Making El Camino.mkv");
        Touch(root, "Extras/Trailer.mkv");
        try
        {
            using var factory = new AureliaHomeServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await CreateLibraryAsync(client, owner.Token, root, LibraryKind.Movies);
            var scan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
            Assert.Equal(LibraryScanState.Completed, scan.State);

            using var listRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                "/api/v1/catalog/movies",
                owner.Token);
            using var listResponse = await client.SendAsync(listRequest);
            listResponse.EnsureSuccessStatusCode();
            var catalog = await ApiTestClient.ReadAsync<PagedResponse<MovieSummary>>(listResponse);
            var movie = Assert.Single(catalog.Items);

            using var detailRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/catalog/movies/{movie.Id}",
                owner.Token);
            using var detailResponse = await client.SendAsync(detailRequest);
            detailResponse.EnsureSuccessStatusCode();
            var json = await detailResponse.Content.ReadAsStringAsync();
            Assert.DoesNotContain(root, json, StringComparison.Ordinal);
            var detail = await ApiTestClient.ReadAsync<MovieDetail>(detailResponse);
            Assert.Equal("El Camino - A Breaking Bad Movie", detail.Title);
            Assert.Equal(2, detail.Supplements.Count);
            Assert.Contains(detail.Supplements, item => item.Kind == MediaKind.Extra);
            Assert.Contains(detail.Supplements, item => item.Kind == MediaKind.Trailer);
            Assert.True(File.Exists(moviePath));
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public async Task AutomaticStoragePersistsReviewDecisionsAndKeepsPathsPrivate()
    {
        var root = CreateDirectory("Mixed Storage");
        Touch(root, "Show/Season 1/Show S01E01 Pilot.mkv");
        Touch(root, "Movie/Movie.mkv");
        Touch(root, "Tiktok/clip-one.mkv");
        Touch(root, "Tiktok/clip-two.mp4");
        try
        {
            using var factory = new AureliaHomeServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            using var createRequest = ApiTestClient.Authorized(
                HttpMethod.Post,
                "/api/v1/libraries",
                owner.Token,
                new CreateLibraryRequest(null, root, LibraryKind.Automatic));
            using var createResponse = await client.SendAsync(createRequest);
            Assert.Equal(HttpStatusCode.Created, createResponse.StatusCode);
            var library = await ApiTestClient.ReadAsync<LibrarySummary>(createResponse);
            Assert.Equal("Mixed Storage", library.Name);
            Assert.Equal(LibraryKind.Automatic, library.Kind);

            var firstScan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
            Assert.Equal(LibraryScanState.Completed, firstScan.State);

            using var discoveriesRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/libraries/{library.Id}/discoveries",
                owner.Token);
            using var discoveriesResponse = await client.SendAsync(discoveriesRequest);
            discoveriesResponse.EnsureSuccessStatusCode();
            var discoveryJson = await discoveriesResponse.Content.ReadAsStringAsync();
            Assert.DoesNotContain(root, discoveryJson, StringComparison.Ordinal);
            var discoveries = await ApiTestClient.ReadAsync<List<LibraryDiscoverySummary>>(
                discoveriesResponse);
            var tiktok = Assert.Single(discoveries, item => item.RelativePath == "Tiktok");
            Assert.Null(tiktok.SuggestedKind);
            Assert.Null(tiktok.Decision);

            using var decideRequest = ApiTestClient.Authorized(
                HttpMethod.Put,
                $"/api/v1/libraries/{library.Id}/classification-decisions",
                owner.Token,
                new UpdateClassificationDecisionsRequest(
                    [new ClassificationDecisionUpdate(tiktok.Id, ClassificationDecision.Ignore)]));
            using var decideResponse = await client.SendAsync(decideRequest);
            Assert.Equal(HttpStatusCode.Accepted, decideResponse.StatusCode);
            var rescan = await ApiTestClient.ReadAsync<LibraryScanSummary>(decideResponse);
            var completed = await WaitForScanAsync(client, owner.Token, rescan.Id);
            Assert.Equal(LibraryScanState.Completed, completed.State);
            Assert.Equal(2, completed.FilesDiscovered);

            using var afterRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/libraries/{library.Id}/discoveries",
                owner.Token);
            using var afterResponse = await client.SendAsync(afterRequest);
            afterResponse.EnsureSuccessStatusCode();
            var after = await ApiTestClient.ReadAsync<List<LibraryDiscoverySummary>>(afterResponse);
            Assert.Equal(
                ClassificationDecision.Ignore,
                Assert.Single(after, item => item.Id == tiktok.Id).Decision);

            using var resetRequest = ApiTestClient.Authorized(
                HttpMethod.Delete,
                $"/api/v1/libraries/{library.Id}/classification-decisions/{tiktok.Id}",
                owner.Token);
            using var resetResponse = await client.SendAsync(resetRequest);
            Assert.Equal(HttpStatusCode.Accepted, resetResponse.StatusCode);
            var resetScan = await ApiTestClient.ReadAsync<LibraryScanSummary>(resetResponse);
            var resetCompleted = await WaitForScanAsync(client, owner.Token, resetScan.Id);
            Assert.Equal(LibraryScanState.Completed, resetCompleted.State);
            Assert.Equal(2, resetCompleted.FilesDiscovered);

            using var resetDiscoveriesRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/libraries/{library.Id}/discoveries",
                owner.Token);
            using var resetDiscoveriesResponse = await client.SendAsync(resetDiscoveriesRequest);
            resetDiscoveriesResponse.EnsureSuccessStatusCode();
            var resetDiscoveries = await ApiTestClient.ReadAsync<List<LibraryDiscoverySummary>>(
                resetDiscoveriesResponse);
            Assert.Null(Assert.Single(
                resetDiscoveries,
                item => item.Id == tiktok.Id).Decision);

            var viewer = await CreateUserAsync(client, owner.Token);
            var viewerLogin = await LoginAsync(client, viewer.Username, "a secure viewer password");
            using var forbiddenRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/libraries/{library.Id}/discoveries",
                viewerLogin.Token);
            using var forbiddenResponse = await client.SendAsync(forbiddenRequest);
            Assert.Equal(HttpStatusCode.Forbidden, forbiddenResponse.StatusCode);
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public async Task AutomaticStorageCanAtomicallyCombineExistingLibraries()
    {
        var storage = CreateDirectory("Combined Storage");
        var movieRoot = Path.Combine(storage, "Movies");
        Directory.CreateDirectory(movieRoot);
        Touch(movieRoot, "Existing Movie.mkv");
        try
        {
            using var factory = new AureliaHomeServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var oldLibrary = await CreateLibraryAsync(
                client,
                owner.Token,
                movieRoot,
                LibraryKind.Movies);
            _ = await StartAndWaitForScanAsync(client, owner.Token, oldLibrary.Id);

            Guid mediaId;
            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
                var media = await database.MediaItems.SingleAsync(item => item.Kind == MediaKind.Movie);
                var user = await database.Users.SingleAsync(item => item.Id == owner.User.Id);
                mediaId = media.Id;
                media.OverrideTitle = "My Existing Title";
                database.PlaybackProgress.Add(new PlaybackProgress
                {
                    Id = Guid.NewGuid(),
                    UserId = owner.User.Id,
                    User = user,
                    MediaItemId = media.Id,
                    MediaItem = media,
                    PositionMilliseconds = 12_345,
                    DurationMilliseconds = 90_000,
                    LastPlayedAt = DateTimeOffset.UtcNow,
                    UpdatedAt = DateTimeOffset.UtcNow,
                });
                await database.SaveChangesAsync();
            }

            using var combineRequest = ApiTestClient.Authorized(
                HttpMethod.Post,
                "/api/v1/libraries",
                owner.Token,
                new CreateLibraryRequest(null, storage, LibraryKind.Automatic, CombineExisting: true));
            using var combineResponse = await client.SendAsync(combineRequest);
            Assert.Equal(HttpStatusCode.Created, combineResponse.StatusCode);
            var combined = await ApiTestClient.ReadAsync<LibrarySummary>(combineResponse);
            Assert.Equal(LibraryKind.Automatic, combined.Kind);

            using var verificationScope = factory.Services.CreateScope();
            var verificationDatabase = verificationScope.ServiceProvider
                .GetRequiredService<AureliaHomeDbContext>();
            var library = Assert.Single(await verificationDatabase.LibraryRoots.ToListAsync());
            Assert.Equal(combined.Id, library.Id);
            var mediaAfter = Assert.Single(await verificationDatabase.MediaItems.ToListAsync());
            Assert.Equal(mediaId, mediaAfter.Id);
            Assert.Equal(combined.Id, mediaAfter.LibraryRootId);
            Assert.Equal("My Existing Title", mediaAfter.OverrideTitle);
            var progress = Assert.Single(await verificationDatabase.PlaybackProgress.ToListAsync());
            Assert.Equal(mediaId, progress.MediaItemId);
            Assert.Equal(12_345, progress.PositionMilliseconds);
            var decision = Assert.Single(await verificationDatabase.LibraryDiscoveries.ToListAsync());
            Assert.Equal("Movies", decision.RelativePath);
            Assert.Equal(ClassificationDecision.Movie, decision.Decision);
        }
        finally
        {
            DeleteFixture(storage);
        }
    }

    [Fact]
    public async Task ExistingAutomaticStorageCannotBeCombinedAgain()
    {
        var storage = CreateDirectory("Existing Automatic Storage");
        try
        {
            using var factory = new AureliaHomeServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            _ = await CreateLibraryAsync(
                client,
                owner.Token,
                storage,
                LibraryKind.Automatic);

            using var duplicateRequest = ApiTestClient.Authorized(
                HttpMethod.Post,
                "/api/v1/libraries",
                owner.Token,
                new CreateLibraryRequest(
                    null,
                    storage,
                    LibraryKind.Automatic,
                    CombineExisting: true));
            using var duplicateResponse = await client.SendAsync(duplicateRequest);

            Assert.Equal(HttpStatusCode.Conflict, duplicateResponse.StatusCode);
            var problem = await ApiTestClient.ReadAsync<ApiProblem>(duplicateResponse);
            Assert.Equal("libraries_cannot_be_combined", problem.Code);
        }
        finally
        {
            DeleteFixture(storage);
        }
    }

    [Fact]
    public async Task QueuedAndRunningScansBecomeInterruptedAfterRestart()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        var root = CreateDirectory("Restart Show");
        Guid scanId;
        string ownerToken;
        try
        {
            using (var firstFactory = new AureliaHomeServerFactory(dataDirectory))
            using (var firstClient = firstFactory.CreateClient())
            {
                var owner = await ApiTestClient.SetupOwnerAsync(firstClient);
                ownerToken = owner.Token;
                var library = await CreateLibraryAsync(
                    firstClient,
                    owner.Token,
                    root,
                    LibraryKind.TvShows);
                scanId = Guid.NewGuid();
                using var scope = firstFactory.Services.CreateScope();
                var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
                database.LibraryScans.Add(new LibraryScan
                {
                    Id = scanId,
                    LibraryRootId = library.Id,
                    State = LibraryScanState.Running,
                    CreatedAt = DateTimeOffset.UtcNow,
                    StartedAt = DateTimeOffset.UtcNow,
                });
                await database.SaveChangesAsync();
            }

            using var secondFactory = new AureliaHomeServerFactory(dataDirectory);
            using var secondClient = secondFactory.CreateClient();
            using var request = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/scans/{scanId}",
                ownerToken);
            using var response = await secondClient.SendAsync(request);
            response.EnsureSuccessStatusCode();
            var scan = await ApiTestClient.ReadAsync<LibraryScanSummary>(response);
            Assert.Equal(LibraryScanState.Interrupted, scan.State);
            Assert.NotNull(scan.CompletedAt);
        }
        finally
        {
            DeleteFixture(root);
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task OverlappingLibrariesAndParallelScansAreRejected()
    {
        var root = CreateDirectory("Movies");
        Touch(root, "Movie.mkv");
        var blockingScanner = new BlockingScanner();
        try
        {
            using var factory = new AureliaHomeServerFactory(
                configureServices: services =>
                {
                    services.RemoveAll<Aurelia.Home.Server.Services.IMediaLibraryScanner>();
                    services.AddSingleton<Aurelia.Home.Server.Services.IMediaLibraryScanner>(blockingScanner);
                });
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await CreateLibraryAsync(client, owner.Token, root, LibraryKind.Movies);

            using (var overlappingRequest = ApiTestClient.Authorized(
                       HttpMethod.Post,
                       "/api/v1/libraries",
                       owner.Token,
                       new CreateLibraryRequest("Nested", Path.Combine(root, "Nested"), LibraryKind.Movies)))
            {
                Directory.CreateDirectory(Path.Combine(root, "Nested"));
                using var overlappingResponse = await client.SendAsync(overlappingRequest);
                Assert.Equal(HttpStatusCode.Conflict, overlappingResponse.StatusCode);
            }

            using var firstRequest = ApiTestClient.Authorized(
                HttpMethod.Post,
                $"/api/v1/libraries/{library.Id}/scans",
                owner.Token);
            using var firstResponse = await client.SendAsync(firstRequest);
            Assert.Equal(HttpStatusCode.Accepted, firstResponse.StatusCode);
            var firstScan = await ApiTestClient.ReadAsync<LibraryScanSummary>(firstResponse);
            Assert.True(blockingScanner.Started.Wait(TimeSpan.FromSeconds(5)));

            using var secondRequest = ApiTestClient.Authorized(
                HttpMethod.Post,
                $"/api/v1/libraries/{library.Id}/scans",
                owner.Token);
            using var secondResponse = await client.SendAsync(secondRequest);
            Assert.Equal(HttpStatusCode.Conflict, secondResponse.StatusCode);

            blockingScanner.Release.Set();
            var completed = await WaitForScanAsync(client, owner.Token, firstScan.Id);
            Assert.Equal(LibraryScanState.Completed, completed.State);
        }
        finally
        {
            blockingScanner.Release.Set();
            DeleteFixture(root);
        }
    }

    private static async Task<LibrarySummary> CreateLibraryAsync(
        HttpClient client,
        string token,
        string path,
        LibraryKind kind)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Post,
            "/api/v1/libraries",
            token,
            new CreateLibraryRequest(Path.GetFileName(path), path, kind));
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        return await ApiTestClient.ReadAsync<LibrarySummary>(response);
    }

    private static async Task<UserSummary> CreateUserAsync(HttpClient client, string token)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Post,
            "/api/v1/users",
            token,
            new CreateUserRequest("viewer", "a secure viewer password", UserRole.User));
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<UserSummary>(response);
    }

    private static async Task<AuthenticationResponse> LoginAsync(
        HttpClient client,
        string username,
        string password)
    {
        using var response = await client.PostAsJsonAsync(
            "/api/v1/auth/login",
            new LoginRequest(username, password, "Viewer Mac"),
            ApiTestClient.JsonOptions);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AuthenticationResponse>(response);
    }

    private static async Task<LibraryScanSummary> StartAndWaitForScanAsync(
        HttpClient client,
        string token,
        Guid libraryId)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Post,
            $"/api/v1/libraries/{libraryId}/scans",
            token);
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        var scan = await ApiTestClient.ReadAsync<LibraryScanSummary>(response);
        return await WaitForScanAsync(client, token, scan.Id);
    }

    private static async Task<LibraryScanSummary> WaitForScanAsync(
        HttpClient client,
        string token,
        Guid scanId)
    {
        for (var attempt = 0; attempt < 200; attempt += 1)
        {
            using var request = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/scans/{scanId}",
                token);
            using var response = await client.SendAsync(request);
            response.EnsureSuccessStatusCode();
            var scan = await ApiTestClient.ReadAsync<LibraryScanSummary>(response);
            if (scan.State is not (LibraryScanState.Queued or LibraryScanState.Running))
            {
                return scan;
            }

            await Task.Delay(25);
        }

        throw new TimeoutException("The scan did not finish.");
    }

    private static async Task<IReadOnlyList<LibrarySummary>> ListLibrariesAsync(
        HttpClient client,
        string token)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/libraries", token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<List<LibrarySummary>>(response);
    }

    private static async Task<PagedResponse<SeriesSummary>> GetSeriesCatalogAsync(
        HttpClient client,
        string token)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/catalog/series", token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<PagedResponse<SeriesSummary>>(response);
    }

    private static async Task<SeriesDetail> GetSeriesDetailAsync(
        HttpClient client,
        string token,
        Guid seriesId)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Get,
            $"/api/v1/catalog/series/{seriesId}",
            token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<SeriesDetail>(response);
    }

    private static string CreateDirectory(string name)
    {
        var root = Path.Combine(TestPaths.CreateDataDirectory(), name);
        Directory.CreateDirectory(root);
        return root;
    }

    private static string Touch(string root, string relativePath)
    {
        var path = Path.Combine(root, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, [1, 2, 3]);
        return path;
    }

    private static void DeleteFixture(string root)
    {
        var parent = Directory.GetParent(root);
        var target = parent is not null && Guid.TryParseExact(parent.Name, "N", out _)
            ? parent.FullName
            : root;
        if (Directory.Exists(target))
        {
            Directory.Delete(target, recursive: true);
        }
    }

    private sealed class BlockingScanner : Aurelia.Home.Server.Services.IMediaLibraryScanner
    {
        public ManualResetEventSlim Started { get; } = new(false);

        public ManualResetEventSlim Release { get; } = new(false);

        public Aurelia.Home.Server.Services.MediaScanDiscovery Scan(
            string rootPath,
            LibraryKind kind,
            IReadOnlyList<Aurelia.Home.Server.Services.ExistingEpisodeBinding> existingEpisodes,
            Action<int>? progress,
            CancellationToken cancellationToken,
            IReadOnlyList<Aurelia.Home.Server.Services.ExistingClassificationDecision>? classificationDecisions = null)
        {
            Started.Set();
            Release.Wait(cancellationToken);
            return new Aurelia.Home.Server.Services.MediaScanDiscovery([], [], 0, 0);
        }
    }
}
