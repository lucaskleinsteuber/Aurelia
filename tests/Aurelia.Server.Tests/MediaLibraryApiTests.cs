using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

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
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await CreateLibraryAsync(client, owner.Token, root, LibraryKind.TvShows);

            var user = await CreateUserAsync(client, owner.Token);
            var userLogin = await LoginAsync(client, "viewer", "a secure viewer password");
            using (var forbiddenRequest = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       "/api/v1/libraries",
                       userLogin.Token))
            using (var forbiddenResponse = await ApiTestClient.SendAsync(client, forbiddenRequest))
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
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var storedSeries = await database.MediaItems.FindAsync(seriesId);
                Assert.NotNull(storedSeries);
                storedSeries.OverrideTitle = "My Manual Series Title";
                await database.SaveChangesAsync();
            }

            using (var detailRequest = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       $"/api/v1/catalog/series/{seriesId}",
                       userLogin.Token))
            using (var detailResponse = await ApiTestClient.SendAsync(client, detailRequest))
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
            Guid waitingScanId;
            Directory.Move(root, offlinePath);
            try
            {
                var offlineScan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
                Assert.Equal(LibraryScanState.WaitingForStorage, offlineScan.State);
                waitingScanId = offlineScan.Id;
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

            using (var cancelWaiting = ApiTestClient.Authorized(
                       HttpMethod.Delete,
                       $"/api/v1/scans/{waitingScanId}",
                       owner.Token))
            using (var cancelResponse = await ApiTestClient.SendAsync(client, cancelWaiting))
            {
                Assert.Equal(HttpStatusCode.NoContent, cancelResponse.StatusCode);
            }

            using (var invalidPage = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       "/api/v1/catalog/series?limit=0",
                       userLogin.Token))
            using (var invalidPageResponse = await ApiTestClient.SendAsync(client, invalidPage))
            {
                Assert.Equal(HttpStatusCode.BadRequest, invalidPageResponse.StatusCode);
            }

            using (var removeRequest = ApiTestClient.Authorized(
                       HttpMethod.Delete,
                       $"/api/v1/libraries/{library.Id}",
                       owner.Token))
            using (var removeResponse = await ApiTestClient.SendAsync(client, removeRequest))
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
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await CreateLibraryAsync(client, owner.Token, root, LibraryKind.Movies);
            var scan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
            Assert.Equal(LibraryScanState.Completed, scan.State);

            using var listRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                "/api/v1/catalog/movies",
                owner.Token);
            using var listResponse = await ApiTestClient.SendAsync(client, listRequest);
            listResponse.EnsureSuccessStatusCode();
            var catalog = await ApiTestClient.ReadAsync<PagedResponse<MovieSummary>>(listResponse);
            var movie = Assert.Single(catalog.Items);

            using var detailRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/catalog/movies/{movie.Id}",
                owner.Token);
            using var detailResponse = await ApiTestClient.SendAsync(client, detailRequest);
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
    public async Task TrailerImportReviewsArePrivatePersistentAndLimitedToSameLibraryMovies()
    {
        var root = CreateDirectory("Trailer Import Review");
        var foreignRoot = CreateDirectory("Foreign Trailer Review");
        Touch(root, "Target Movie (2020).mkv");
        Touch(root, "Unmatched Movie - Official Trailer.mp4");
        Touch(root, "Another Unmatched Film - Teaser.mp4");
        Touch(foreignRoot, "Foreign Movie.mkv");
        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await CreateLibraryAsync(client, owner.Token, root, LibraryKind.Movies);
            var foreignLibrary = await CreateLibraryAsync(
                client, owner.Token, foreignRoot, LibraryKind.Movies);
            _ = await StartAndWaitForScanAsync(client, owner.Token, foreignLibrary.Id);
            var firstScan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
            Assert.Equal(LibraryScanState.Completed, firstScan.State);

            var sameLibraryMovie = Assert.Single(
                (await GetLibraryMoviesAsync(client, owner.Token, library.Id)).Items);
            var foreignMovie = Assert.Single(
                (await GetLibraryMoviesAsync(client, owner.Token, foreignLibrary.Id)).Items);
            List<LibraryImportReviewSummary> reviews;
            using (var request = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       $"/api/v1/libraries/{library.Id}/import-reviews",
                       owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, request))
            {
                response.EnsureSuccessStatusCode();
                var json = await response.Content.ReadAsStringAsync();
                Assert.DoesNotContain(root, json, StringComparison.Ordinal);
                reviews = await ApiTestClient.ReadAsync<List<LibraryImportReviewSummary>>(response);
            }

            Assert.Equal(2, reviews.Count);
            Assert.All(reviews, review => Assert.Equal(LibraryImportReviewState.Pending, review.State));
            var assignedReview = Assert.Single(
                reviews, review => review.RelativePath == "Unmatched Movie - Official Trailer.mp4");
            var ignoredReview = Assert.Single(
                reviews, review => review.RelativePath == "Another Unmatched Film - Teaser.mp4");
            var viewer = await CreateUserAsync(client, owner.Token);
            var viewerLogin = await LoginAsync(client, viewer.Username, "a secure viewer password");
            using (var forbiddenRequest = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       $"/api/v1/libraries/{library.Id}/import-reviews",
                       viewerLogin.Token))
            using (var forbiddenResponse = await ApiTestClient.SendAsync(client, forbiddenRequest))
            {
                Assert.Equal(HttpStatusCode.Forbidden, forbiddenResponse.StatusCode);
            }

            using (var crossLibraryRequest = ApiTestClient.Authorized(
                       HttpMethod.Put,
                       $"/api/v1/libraries/{library.Id}/import-reviews/{assignedReview.Id}",
                       owner.Token,
                       new UpdateLibraryImportReviewRequest(
                           LibraryImportReviewAction.AssignToMovie,
                           foreignMovie.Id)))
            using (var crossLibraryResponse = await ApiTestClient.SendAsync(client, crossLibraryRequest))
            {
                Assert.Equal(HttpStatusCode.NotFound, crossLibraryResponse.StatusCode);
                Assert.Equal("movie_not_found", (await ApiTestClient.ReadAsync<ApiProblem>(crossLibraryResponse)).Code);
            }

            var trailerIds = await GetTrailerIdsAsync(factory, library.Id);
            var assignScan = await DecideTrailerReviewAsync(
                client,
                owner.Token,
                library.Id,
                assignedReview.Id,
                new UpdateLibraryImportReviewRequest(
                    LibraryImportReviewAction.AssignToMovie,
                    sameLibraryMovie.Id));
            Assert.Equal(LibraryScanState.Completed, assignScan.State);

            using (var ignoreRequest = ApiTestClient.Authorized(
                       HttpMethod.Put,
                       $"/api/v1/libraries/{library.Id}/import-reviews/{ignoredReview.Id}",
                       owner.Token,
                       new UpdateLibraryImportReviewRequest(LibraryImportReviewAction.Ignore)))
            using (var ignoreResponse = await ApiTestClient.SendAsync(client, ignoreRequest))
            {
                Assert.Equal(HttpStatusCode.Accepted, ignoreResponse.StatusCode);
                var queued = await ApiTestClient.ReadAsync<LibraryScanSummary>(ignoreResponse);
                Assert.Equal(LibraryScanState.Completed,
                    (await WaitForScanAsync(client, owner.Token, queued.Id)).State);
            }

            _ = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
            Assert.Empty(await GetImportReviewsAsync(client, owner.Token, library.Id));
            using var scope = factory.Services.CreateScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var persisted = await database.LibraryImportReviews
                .Where(review => review.LibraryRootId == library.Id)
                .ToListAsync();
            Assert.Equal(2, persisted.Count);
            Assert.Equal(LibraryImportReviewState.Assigned,
                Assert.Single(persisted, review => review.Id == assignedReview.Id).State);
            Assert.Equal(sameLibraryMovie.Id,
                Assert.Single(persisted, review => review.Id == assignedReview.Id).AssignedMovieId);
            Assert.Equal(LibraryImportReviewState.Ignored,
                Assert.Single(persisted, review => review.Id == ignoredReview.Id).State);

            var assignedTrailer = await database.MediaItems.SingleAsync(
                item => item.LibraryRootId == library.Id
                    && item.SourcePath.EndsWith("Unmatched Movie - Official Trailer.mp4"));
            var ignoredTrailer = await database.MediaItems.SingleAsync(
                item => item.LibraryRootId == library.Id
                    && item.SourcePath.EndsWith("Another Unmatched Film - Teaser.mp4"));
            Assert.Equal(MediaKind.Trailer, assignedTrailer.Kind);
            Assert.Equal(sameLibraryMovie.Id, assignedTrailer.ParentId);
            Assert.Equal(MediaKind.Trailer, ignoredTrailer.Kind);
            Assert.Null(ignoredTrailer.ParentId);
            Assert.Equal(trailerIds[assignedTrailer.SourcePath], assignedTrailer.Id);
            Assert.Equal(trailerIds[ignoredTrailer.SourcePath], ignoredTrailer.Id);
        }
        finally
        {
            DeleteFixture(root);
            DeleteFixture(foreignRoot);
        }
    }

    [Fact]
    public async Task ExactSiblingTrailerRepairsAnOldMovieImportWithoutReplacingItsIdentity()
    {
        var root = CreateDirectory("Legacy Trailer Repair");
        var moviePath = Touch(root, "The Truman Show (1998).mkv");
        var trailerPath = Touch(root, "The Truman Show - Official Trailer.mp4");
        var legacyTrailerId = Guid.NewGuid();
        var originalCreatedAt = DateTimeOffset.FromUnixTimeMilliseconds(
            DateTimeOffset.UtcNow.AddDays(-3).ToUnixTimeMilliseconds());
        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await CreateLibraryAsync(client, owner.Token, root, LibraryKind.Movies);
            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var libraryRoot = await database.LibraryRoots.SingleAsync(item => item.Id == library.Id);
                database.MediaItems.Add(new MediaItem
                {
                    Id = legacyTrailerId,
                    LibraryRootId = library.Id,
                    LibraryRoot = libraryRoot,
                    Kind = MediaKind.Movie,
                    SourcePath = trailerPath,
                    NormalizedSourcePath = MediaPath.Normalize(trailerPath),
                    DetectedTitle = "The Truman Show - Official Trailer",
                    OverrideTitle = "My Manually Named Trailer",
                    Extension = ".mp4",
                    FileSize = 3,
                    Availability = MediaAvailability.Available,
                    CreatedAt = originalCreatedAt,
                    UpdatedAt = originalCreatedAt,
                });
                await database.SaveChangesAsync();
            }

            var scan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
            Assert.Equal(LibraryScanState.Completed, scan.State);
            Assert.Equal(2, scan.FilesDiscovered);
            Assert.Equal(1, scan.UpdatedFiles);

            using var verificationScope = factory.Services.CreateScope();
            var verificationDatabase = verificationScope.ServiceProvider
                .GetRequiredService<AureliaDbContext>();
            var trailer = await verificationDatabase.MediaItems.SingleAsync(
                item => item.LibraryRootId == library.Id && item.SourcePath == trailerPath);
            var movie = await verificationDatabase.MediaItems.SingleAsync(
                item => item.LibraryRootId == library.Id && item.SourcePath == moviePath);
            Assert.Equal(legacyTrailerId, trailer.Id);
            Assert.Equal(MediaKind.Trailer, trailer.Kind);
            Assert.Equal(movie.Id, trailer.ParentId);
            Assert.Equal("My Manually Named Trailer", trailer.OverrideTitle);
            Assert.Equal(originalCreatedAt, trailer.CreatedAt);
            Assert.Empty(await verificationDatabase.LibraryImportReviews
                .Where(review => review.LibraryRootId == library.Id)
                .ToListAsync());
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public async Task ImportReviewDecisionRemainsPendingWhenAnotherScanIsAlreadyRunning()
    {
        var root = CreateDirectory("Atomic Trailer Decision");
        var blockingScanner = new BlockingScanner();
        try
        {
            using var factory = new AureliaServerFactory(
                configureServices: services =>
                {
                    services.RemoveAll<IMediaLibraryScanner>();
                    services.AddSingleton<IMediaLibraryScanner>(blockingScanner);
                });
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await CreateLibraryAsync(client, owner.Token, root, LibraryKind.Movies);
            var reviewId = Guid.NewGuid();
            var now = DateTimeOffset.UtcNow;
            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var libraryRoot = await database.LibraryRoots.SingleAsync(item => item.Id == library.Id);
                database.LibraryImportReviews.Add(new LibraryImportReview
                {
                    Id = reviewId,
                    LibraryRootId = library.Id,
                    LibraryRoot = libraryRoot,
                    RelativePath = "Unmatched - Trailer.mp4",
                    NormalizedRelativePath = "UNMATCHED - TRAILER.MP4",
                    DetectedTitle = "Unmatched",
                    Reason = "No exact movie title match was found in this storage location.",
                    State = LibraryImportReviewState.Pending,
                    CreatedAt = now,
                    UpdatedAt = now,
                });
                await database.SaveChangesAsync();
            }

            using var scanRequest = ApiTestClient.Authorized(
                HttpMethod.Post,
                $"/api/v1/libraries/{library.Id}/scans",
                owner.Token);
            using var scanResponse = await ApiTestClient.SendAsync(client, scanRequest);
            Assert.Equal(HttpStatusCode.Accepted, scanResponse.StatusCode);
            var scan = await ApiTestClient.ReadAsync<LibraryScanSummary>(scanResponse);
            Assert.True(blockingScanner.Started.Wait(TimeSpan.FromSeconds(5)));

            using var decisionRequest = ApiTestClient.Authorized(
                HttpMethod.Put,
                $"/api/v1/libraries/{library.Id}/import-reviews/{reviewId}",
                owner.Token,
                new UpdateLibraryImportReviewRequest(LibraryImportReviewAction.Ignore));
            using var decisionResponse = await ApiTestClient.SendAsync(client, decisionRequest);
            Assert.Equal(HttpStatusCode.Conflict, decisionResponse.StatusCode);
            Assert.Equal("library_scan_active",
                (await ApiTestClient.ReadAsync<ApiProblem>(decisionResponse)).Code);

            using (var verificationScope = factory.Services.CreateScope())
            {
                var database = verificationScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var review = await database.LibraryImportReviews
                    .AsNoTracking()
                    .SingleAsync(item => item.Id == reviewId);
                Assert.Equal(LibraryImportReviewState.Pending, review.State);
            }

            blockingScanner.Release.Set();
            Assert.Equal(LibraryScanState.Completed,
                (await WaitForScanAsync(client, owner.Token, scan.Id)).State);
        }
        finally
        {
            blockingScanner.Release.Set();
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
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            using var createRequest = ApiTestClient.Authorized(
                HttpMethod.Post,
                "/api/v1/libraries",
                owner.Token,
                new CreateLibraryRequest(null, root, LibraryKind.Automatic));
            using var createResponse = await ApiTestClient.SendAsync(client, createRequest);
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
            using var discoveriesResponse = await ApiTestClient.SendAsync(client, discoveriesRequest);
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
            using var decideResponse = await ApiTestClient.SendAsync(client, decideRequest);
            Assert.Equal(HttpStatusCode.Accepted, decideResponse.StatusCode);
            var rescan = await ApiTestClient.ReadAsync<LibraryScanSummary>(decideResponse);
            var completed = await WaitForScanAsync(client, owner.Token, rescan.Id);
            Assert.Equal(LibraryScanState.Completed, completed.State);
            Assert.Equal(2, completed.FilesDiscovered);

            using var afterRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/libraries/{library.Id}/discoveries",
                owner.Token);
            using var afterResponse = await ApiTestClient.SendAsync(client, afterRequest);
            afterResponse.EnsureSuccessStatusCode();
            var after = await ApiTestClient.ReadAsync<List<LibraryDiscoverySummary>>(afterResponse);
            Assert.Equal(
                ClassificationDecision.Ignore,
                Assert.Single(after, item => item.Id == tiktok.Id).Decision);

            using var resetRequest = ApiTestClient.Authorized(
                HttpMethod.Delete,
                $"/api/v1/libraries/{library.Id}/classification-decisions/{tiktok.Id}",
                owner.Token);
            using var resetResponse = await ApiTestClient.SendAsync(client, resetRequest);
            Assert.Equal(HttpStatusCode.Accepted, resetResponse.StatusCode);
            var resetScan = await ApiTestClient.ReadAsync<LibraryScanSummary>(resetResponse);
            var resetCompleted = await WaitForScanAsync(client, owner.Token, resetScan.Id);
            Assert.Equal(LibraryScanState.Completed, resetCompleted.State);
            Assert.Equal(2, resetCompleted.FilesDiscovered);

            using var resetDiscoveriesRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/libraries/{library.Id}/discoveries",
                owner.Token);
            using var resetDiscoveriesResponse = await ApiTestClient.SendAsync(client, resetDiscoveriesRequest);
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
            using var forbiddenResponse = await ApiTestClient.SendAsync(client, forbiddenRequest);
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
            using var factory = new AureliaServerFactory();
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
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
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
            using var combineResponse = await ApiTestClient.SendAsync(client, combineRequest);
            Assert.Equal(HttpStatusCode.Created, combineResponse.StatusCode);
            var combined = await ApiTestClient.ReadAsync<LibrarySummary>(combineResponse);
            Assert.Equal(LibraryKind.Automatic, combined.Kind);

            using var verificationScope = factory.Services.CreateScope();
            var verificationDatabase = verificationScope.ServiceProvider
                .GetRequiredService<AureliaDbContext>();
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
            using var factory = new AureliaServerFactory();
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
            using var duplicateResponse = await ApiTestClient.SendAsync(client, duplicateRequest);

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
    public async Task RunningScansResumeAfterRestart()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        var root = CreateDirectory("Restart Show");
        Guid scanId;
        string ownerToken;
        try
        {
            using (var firstFactory = new AureliaServerFactory(dataDirectory))
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
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
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

            using var secondFactory = new AureliaServerFactory(dataDirectory);
            using var secondClient = secondFactory.CreateClient();
            using var request = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/scans/{scanId}",
                ownerToken);
            using var response = await secondClient.SendAsync(request);
            response.EnsureSuccessStatusCode();
            var scan = await ApiTestClient.ReadAsync<LibraryScanSummary>(response);
            Assert.Equal(LibraryScanState.Completed, scan.State);
            Assert.Equal(1, scan.Attempt);
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
            using var factory = new AureliaServerFactory(
                configureServices: services =>
                {
                    services.RemoveAll<Aurelia.Server.Services.IMediaLibraryScanner>();
                    services.AddSingleton<Aurelia.Server.Services.IMediaLibraryScanner>(blockingScanner);
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
                using var overlappingResponse = await ApiTestClient.SendAsync(client, overlappingRequest);
                Assert.Equal(HttpStatusCode.Conflict, overlappingResponse.StatusCode);
            }

            using var firstRequest = ApiTestClient.Authorized(
                HttpMethod.Post,
                $"/api/v1/libraries/{library.Id}/scans",
                owner.Token);
            using var firstResponse = await ApiTestClient.SendAsync(client, firstRequest);
            Assert.Equal(HttpStatusCode.Accepted, firstResponse.StatusCode);
            var firstScan = await ApiTestClient.ReadAsync<LibraryScanSummary>(firstResponse);
            Assert.True(blockingScanner.Started.Wait(TimeSpan.FromSeconds(5)));

            using var secondRequest = ApiTestClient.Authorized(
                HttpMethod.Post,
                $"/api/v1/libraries/{library.Id}/scans",
                owner.Token);
            using var secondResponse = await ApiTestClient.SendAsync(client, secondRequest);
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

    [Fact]
    public async Task ActiveScansAndBoundedLibraryHistoryCanBeRestored()
    {
        var root = CreateDirectory("Scan History");
        Touch(root, "Movie.mkv");
        var blockingScanner = new BlockingScanner();
        try
        {
            using var factory = new AureliaServerFactory(
                configureServices: services =>
                {
                    services.RemoveAll<Aurelia.Server.Services.IMediaLibraryScanner>();
                    services.AddSingleton<Aurelia.Server.Services.IMediaLibraryScanner>(blockingScanner);
                });
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await CreateLibraryAsync(client, owner.Token, root, LibraryKind.Movies);

            using var startRequest = ApiTestClient.Authorized(
                HttpMethod.Post,
                $"/api/v1/libraries/{library.Id}/scans",
                owner.Token);
            using var startResponse = await ApiTestClient.SendAsync(client, startRequest);
            Assert.Equal(HttpStatusCode.Accepted, startResponse.StatusCode);
            var started = await ApiTestClient.ReadAsync<LibraryScanSummary>(startResponse);
            Assert.True(blockingScanner.Started.Wait(TimeSpan.FromSeconds(5)));

            using (var activeRequest = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       "/api/v1/libraries/scans",
                       owner.Token))
            using (var activeResponse = await ApiTestClient.SendAsync(client, activeRequest))
            {
                activeResponse.EnsureSuccessStatusCode();
                var active = await ApiTestClient.ReadAsync<List<LibraryScanSummary>>(activeResponse);
                Assert.Equal(started.Id, Assert.Single(active).Id);
                Assert.Contains(Assert.Single(active).State, new[]
                {
                    LibraryScanState.Queued,
                    LibraryScanState.Running,
                });
            }

            blockingScanner.Release.Set();
            var completed = await WaitForScanAsync(client, owner.Token, started.Id);

            using (var historyRequest = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       $"/api/v1/libraries/{library.Id}/scans?limit=1",
                       owner.Token))
            using (var historyResponse = await ApiTestClient.SendAsync(client, historyRequest))
            {
                historyResponse.EnsureSuccessStatusCode();
                var history = await ApiTestClient.ReadAsync<List<LibraryScanSummary>>(historyResponse);
                Assert.Equal(completed.Id, Assert.Single(history).Id);
                Assert.Equal(LibraryScanState.Completed, history[0].State);
            }

            using var invalidRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                $"/api/v1/libraries/{library.Id}/scans?limit=101",
                owner.Token);
            using var invalidResponse = await ApiTestClient.SendAsync(client, invalidRequest);
            Assert.Equal(HttpStatusCode.BadRequest, invalidResponse.StatusCode);
        }
        finally
        {
            blockingScanner.Release.Set();
            DeleteFixture(root);
        }
    }

    [Fact]
    public async Task MonitoringMoveIdentitySearchAndSyncRemainConsistent()
    {
        var root = CreateDirectory("Reliable Movies");
        var original = Touch(root, "Arrival (2016).mkv");
        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var library = await CreateLibraryAsync(client, owner.Token, root, LibraryKind.Movies);

            using (var disable = ApiTestClient.Authorized(
                       HttpMethod.Put,
                       $"/api/v1/libraries/{library.Id}/monitoring",
                       owner.Token,
                       new UpdateLibraryMonitoringRequest(false)))
            using (var response = await ApiTestClient.SendAsync(client, disable))
            {
                response.EnsureSuccessStatusCode();
                var updated = await ApiTestClient.ReadAsync<LibrarySummary>(response);
                Assert.False(updated.MonitoringEnabled);
            }

            var firstScan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
            Assert.Equal(LibraryScanTrigger.Manual, firstScan.Trigger);
            Assert.Equal(1, firstScan.Attempt);
            var firstCatalog = await GetCatalogAsync(client, owner.Token);
            var movie = Assert.Single(firstCatalog.Items);

            using (var favorite = ApiTestClient.Authorized(
                       HttpMethod.Put,
                       $"/api/v1/media/{movie.Id}/favorite",
                       owner.Token,
                       new SetFavoriteRequest(true)))
            using (var response = await ApiTestClient.SendAsync(client, favorite))
                response.EnsureSuccessStatusCode();

            var moved = Path.Combine(root, "Renamed", "Arrival Final.mkv");
            Directory.CreateDirectory(Path.GetDirectoryName(moved)!);
            File.Move(original, moved);
            var secondScan = await StartAndWaitForScanAsync(client, owner.Token, library.Id);
            Assert.Equal(0, secondScan.AddedFiles);
            Assert.Equal(1, secondScan.UpdatedFiles);
            var secondCatalog = await GetCatalogAsync(client, owner.Token);
            var movedMovie = Assert.Single(secondCatalog.Items);
            Assert.Equal(movie.Id, movedMovie.Id);
            Assert.True(movedMovie.IsFavorite);

            string entityTag;
            using (var catalog = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       "/api/v1/catalog/items?offset=0&limit=100",
                       owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, catalog))
            {
                response.EnsureSuccessStatusCode();
                Assert.NotNull(response.Headers.ETag);
                entityTag = response.Headers.ETag.ToString();
            }

            using (var unchanged = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       "/api/v1/catalog/items?offset=0&limit=100",
                       owner.Token))
            {
                unchanged.Headers.TryAddWithoutValidation("If-None-Match", entityTag);
                using var response = await ApiTestClient.SendAsync(client, unchanged);
                Assert.Equal(HttpStatusCode.NotModified, response.StatusCode);
                Assert.Empty(await response.Content.ReadAsByteArrayAsync());
            }

            using (var search = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       "/api/v1/catalog/search?query=Arrival&offset=0&limit=10",
                       owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, search))
            {
                response.EnsureSuccessStatusCode();
                Assert.Equal(movie.Id, Assert.Single(
                    (await ApiTestClient.ReadAsync<PagedResponse<CatalogItemSummary>>(response)).Items).Id);
            }

            using (var filtered = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       $"/api/v1/catalog/items?kind=movie&libraryId={library.Id}&favorite=true&availability=available&sort=dateAdded&direction=descending",
                       owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, filtered))
            {
                response.EnsureSuccessStatusCode();
                Assert.Equal(movie.Id, Assert.Single(
                    (await ApiTestClient.ReadAsync<PagedResponse<CatalogItemSummary>>(response)).Items).Id);
            }

            using (var invalidFilter = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       "/api/v1/catalog/items?yearFrom=2020&yearTo=2010",
                       owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, invalidFilter))
            {
                Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
                Assert.Equal("invalid_year_range", (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
            }

            using (var rebuild = ApiTestClient.Authorized(
                       HttpMethod.Post,
                       "/api/v1/catalog/search/rebuild",
                       owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, rebuild))
            {
                Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
            }

            using (var sync = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       "/api/v1/sync/changes?after=0&waitSeconds=0",
                       owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, sync))
            {
                response.EnsureSuccessStatusCode();
                var changes = await ApiTestClient.ReadAsync<SyncChangesResponse>(response);
                Assert.True(changes.Cursor > 0);
                Assert.Contains(SyncChangeArea.Catalog, changes.ChangedAreas);
            }
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    private static async Task<PagedResponse<CatalogItemSummary>> GetCatalogAsync(
        HttpClient client,
        string token)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Get,
            "/api/v1/catalog/items?offset=0&limit=100",
            token);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<PagedResponse<CatalogItemSummary>>(response);
    }

    private static async Task<PagedResponse<CatalogItemSummary>> GetLibraryMoviesAsync(
        HttpClient client,
        string token,
        Guid libraryId)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Get,
            $"/api/v1/catalog/items?kind=movie&libraryId={libraryId}&offset=0&limit=100",
            token);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<PagedResponse<CatalogItemSummary>>(response);
    }

    private static async Task<Dictionary<string, Guid>> GetTrailerIdsAsync(
        AureliaServerFactory factory,
        Guid libraryId)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        return await database.MediaItems
            .Where(item => item.LibraryRootId == libraryId && item.Kind == MediaKind.Trailer)
            .ToDictionaryAsync(item => item.SourcePath, item => item.Id);
    }

    private static async Task<List<LibraryImportReviewSummary>> GetImportReviewsAsync(
        HttpClient client,
        string token,
        Guid libraryId)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Get,
            $"/api/v1/libraries/{libraryId}/import-reviews",
            token);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<List<LibraryImportReviewSummary>>(response);
    }

    private static async Task<LibraryScanSummary> DecideTrailerReviewAsync(
        HttpClient client,
        string token,
        Guid libraryId,
        Guid reviewId,
        UpdateLibraryImportReviewRequest decision)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Put,
            $"/api/v1/libraries/{libraryId}/import-reviews/{reviewId}",
            token,
            decision);
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        var scan = await ApiTestClient.ReadAsync<LibraryScanSummary>(response);
        return await WaitForScanAsync(client, token, scan.Id);
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
        using var response = await ApiTestClient.SendAsync(client, request);
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
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        var user = await ApiTestClient.ReadAsync<UserSummary>(response);
        await ApiTestClient.GrantExistingLibrariesAsync(client, token, user.Id);
        return user;
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
        using var response = await ApiTestClient.SendAsync(client, request);
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
            using var response = await ApiTestClient.SendAsync(client, request);
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
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<List<LibrarySummary>>(response);
    }

    private static async Task<PagedResponse<SeriesSummary>> GetSeriesCatalogAsync(
        HttpClient client,
        string token)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/catalog/series", token);
        using var response = await ApiTestClient.SendAsync(client, request);
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
        using var response = await ApiTestClient.SendAsync(client, request);
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

    private sealed class BlockingScanner : Aurelia.Server.Services.IMediaLibraryScanner
    {
        public ManualResetEventSlim Started { get; } = new(false);

        public ManualResetEventSlim Release { get; } = new(false);

        public Aurelia.Server.Services.MediaScanDiscovery Scan(
            string rootPath,
            LibraryKind kind,
            IReadOnlyList<Aurelia.Server.Services.ExistingEpisodeBinding> existingEpisodes,
            Action<int>? progress,
            CancellationToken cancellationToken,
            IReadOnlyList<Aurelia.Server.Services.ExistingClassificationDecision>? classificationDecisions = null,
            IReadOnlyList<Aurelia.Server.Services.ExistingMovieBinding>? existingMovies = null,
            IReadOnlyList<Aurelia.Server.Services.ExistingImportReviewDecision>? importReviewDecisions = null)
        {
            Started.Set();
            Release.Wait(cancellationToken);
            return new Aurelia.Server.Services.MediaScanDiscovery([], [], 0, 0);
        }
    }
}
