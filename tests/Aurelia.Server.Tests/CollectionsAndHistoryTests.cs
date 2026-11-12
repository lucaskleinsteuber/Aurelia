using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using SkiaSharp;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class CollectionsAndHistoryTests
{
    private static AureliaServerFactory CreateFactory() => new();

    private static async Task<T> SendAsync<T>(
        HttpClient client,
        string token,
        HttpMethod method,
        string uri,
        object? body = null)
    {
        using var request = ApiTestClient.Authorized(method, uri, token, body);
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.True(response.IsSuccessStatusCode, $"Failed {method} {uri}: {response.StatusCode}");
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

    [Fact]
    public async Task SmartListsUnderstandTheRulesTheAppsSend()
    {
        var mediaRoot = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaRoot);
        await File.WriteAllBytesAsync(Path.Combine(mediaRoot, "Alpha.mkv"), [1]);
        await File.WriteAllBytesAsync(Path.Combine(mediaRoot, "Beta 100%.mkv"), [2]);
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
            var alpha = movies.Single(movie => movie.Title.StartsWith("Alpha", StringComparison.Ordinal));
            var beta = movies.Single(movie => movie.Title.StartsWith("Beta", StringComparison.Ordinal));
            await SendAsync<object>(client, owner.Token, HttpMethod.Put, $"/api/v1/media/{alpha.Id}/favorite", new SetFavoriteRequest(true));

            async Task<CollectionSummary> Smart(string name, string rules) =>
                await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/collections",
                    new SaveCollectionRequest(name, [], IsSmart: true, IsShared: false, RulesJson: rules));

            // The Mac app's spelling: plural kind, "match".
            var macList = await Smart("Mac", """{"kind":"movies","favoritesOnly":true,"match":"all"}""");
            Assert.Equal(alpha.Id, Assert.Single(macList.Items).Id);
            // The browser's spelling: "textContains", "matchAny"; % is a letter, not a wildcard.
            var webList = await Smart("Web", """{"kind":"movie","textContains":"100%","matchAny":false}""");
            Assert.Equal(beta.Id, Assert.Single(webList.Items).Id);
            Assert.Empty((await Smart("Nothing", """{"textContains":"_"}""")).Items);
            // "Match any rule": a favorite or a title with "Beta"; with all rules no title has both.
            Assert.Equal(2, (await Smart("Either", """{"favoritesOnly":true,"search":"Beta","match":"any"}""")).Items.Count);
            Assert.Empty((await Smart("Both", """{"favoritesOnly":true,"search":"Beta","match":"all"}""")).Items);
            // Stored in one spelling every app reads back.
            Assert.Contains("\"favoritesOnly\":true", macList.RulesJson, StringComparison.Ordinal);
            Assert.Contains("\"kind\":\"movie\"", macList.RulesJson, StringComparison.Ordinal);
            Assert.DoesNotContain("match\"", macList.RulesJson, StringComparison.Ordinal);

            using var invalid = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/collections", owner.Token,
                new SaveCollectionRequest("Broken", [], IsSmart: true, IsShared: false, RulesJson: "not json"));
            using var invalidResponse = await ApiTestClient.SendAsync(client, invalid);
            Assert.Equal(HttpStatusCode.BadRequest, invalidResponse.StatusCode);

            // Only provider franchises can be copied, not another collection by its id.
            using var copy = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/collections/from-franchise/{macList.Id}", owner.Token);
            using var copyResponse = await ApiTestClient.SendAsync(client, copy);
            Assert.Equal(HttpStatusCode.NotFound, copyResponse.StatusCode);
        }
        finally
        {
            Directory.Delete(mediaRoot, recursive: true);
        }
    }

    [Fact]
    public async Task ViewersCanCreateAndManageOwnCollectionsWhileSharedCollectionsAreProtected()
    {
        var mediaRoot = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaRoot);
        await File.WriteAllBytesAsync(Path.Combine(mediaRoot, "Alpha.mkv"), [1]);
        await File.WriteAllBytesAsync(Path.Combine(mediaRoot, "Beta.mkv"), [2]);

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

            // Create viewer user
            var user = await SendAsync<UserSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/users",
                new CreateUserRequest("cinephile", "another correct horse password", UserRole.User, ApiTestClient.TestPin, AccessMode: ProfileAccessMode.EntireLibrary));
            using var login = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/auth/login", owner.Token,
                new LoginRequest("cinephile", "another correct horse password", "Viewer Mac"));
            using var loginResponse = await ApiTestClient.SendAsync(client, login);
            var viewerAuth = await ApiTestClient.ReadAsync<AuthenticationResponse>(loginResponse);

            // Owner creates a shared collection
            var shared = await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/collections",
                new SaveCollectionRequest("Admin Selection", [movies[0].Id, movies[1].Id], IsSmart: false, IsShared: true));
            Assert.True(shared.IsShared);

            // Viewer creates their OWN collection
            var own = await SendAsync<CollectionSummary>(client, viewerAuth.Token, HttpMethod.Post, "/api/v1/collections",
                new SaveCollectionRequest("My Favorites", [movies[0].Id], IsSmart: false, IsShared: false));
            Assert.False(own.IsShared);
            Assert.Equal("My Favorites", own.Name);

            // Viewer tries to create a shared collection -> forbidden
            using var sharedByViewer = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/collections", viewerAuth.Token,
                new SaveCollectionRequest("Illegal Shared", [movies[0].Id], IsSmart: false, IsShared: true));
            using var sharedResp = await ApiTestClient.SendAsync(client, sharedByViewer);
            Assert.Equal(HttpStatusCode.Forbidden, sharedResp.StatusCode);

            // Viewer tries to delete owner's shared collection -> forbidden
            using var deleteShared = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/collections/{shared.Id}", viewerAuth.Token);
            using var deleteSharedResp = await ApiTestClient.SendAsync(client, deleteShared);
            Assert.Equal(HttpStatusCode.Forbidden, deleteSharedResp.StatusCode);

            // Viewer can add item to own collection
            using var addItem = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/collections/{own.Id}/items/{movies[1].Id}", viewerAuth.Token);
            using var addItemResp = await ApiTestClient.SendAsync(client, addItem);
            Assert.Equal(HttpStatusCode.NoContent, addItemResp.StatusCode);

            // The owner can neither change nor take over a viewer's private collection.
            using var ownerEdit = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/collections/{own.Id}", owner.Token,
                new SaveCollectionRequest("Taken", [movies[0].Id], IsSmart: false, IsShared: false));
            using var ownerEditResp = await ApiTestClient.SendAsync(client, ownerEdit);
            Assert.Equal(HttpStatusCode.NotFound, ownerEditResp.StatusCode);
            using var ownerDelete = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/collections/{own.Id}", owner.Token);
            using var ownerDeleteResp = await ApiTestClient.SendAsync(client, ownerDelete);
            Assert.Equal(HttpStatusCode.NotFound, ownerDeleteResp.StatusCode);

            // Viewer deletes their own collection -> success
            using var deleteOwn = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/collections/{own.Id}", viewerAuth.Token);
            using var deleteOwnResp = await ApiTestClient.SendAsync(client, deleteOwn);
            Assert.Equal(HttpStatusCode.NoContent, deleteOwnResp.StatusCode);
        }
        finally
        {
            Directory.Delete(mediaRoot, recursive: true);
        }
    }

    [Fact]
    public async Task SmartListEvaluatorFiltersCorrectly()
    {
        using var factory = CreateFactory();
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();

        var libraryRoot = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Movies",
            Path = "/fake/movies",
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = DateTimeOffset.UtcNow
        };
        db.LibraryRoots.Add(libraryRoot);

        var user = new ServerUser
        {
            Id = Guid.NewGuid(),
            Username = "tester",
            NormalizedUsername = "TESTER",
            PasswordHash = "hash",
            Role = UserRole.User,
            IsEnabled = true,
            CreatedAt = DateTimeOffset.UtcNow
        };
        db.Users.Add(user);

        var movie1 = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRootId = libraryRoot.Id,
            Kind = MediaKind.Movie,
            SourcePath = "/fake/movies/Inception.mkv",
            NormalizedSourcePath = "/fake/movies/Inception.mkv",
            DetectedTitle = "Inception",
            Year = 2010,
            Availability = MediaAvailability.Available,
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
            Metadata = new MediaMetadata
            {
                ProviderTitle = "Inception",
                ProviderGenresJson = "[\"Sci-Fi\",\"Action\"]",
                ProviderRating = 8.8,
                UpdatedAt = DateTimeOffset.UtcNow
            }
        };

        var movie2 = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRootId = libraryRoot.Id,
            Kind = MediaKind.Movie,
            SourcePath = "/fake/movies/Titanic.mkv",
            NormalizedSourcePath = "/fake/movies/Titanic.mkv",
            DetectedTitle = "Titanic",
            Year = 1997,
            Availability = MediaAvailability.Available,
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
            Metadata = new MediaMetadata
            {
                ProviderTitle = "Titanic",
                ProviderGenresJson = "[\"Drama\",\"Romance\"]",
                ProviderRating = 7.9,
                UpdatedAt = DateTimeOffset.UtcNow
            }
        };

        db.MediaItems.AddRange(movie1, movie2);
        await db.SaveChangesAsync();

        // Evaluate rule: Rating >= 8.0
        var (itemsHighRating, countHighRating) = await SmartListEvaluator.EvaluateAsync(
            db, user.Id, new SmartCollectionRules { RatingMin = 8.0 }, 0, 10, CancellationToken.None);
        Assert.Equal(1, countHighRating);
        Assert.Equal(movie1.Id, Assert.Single(itemsHighRating).Id);

        // Evaluate rule: Genre "Drama"
        var (itemsDrama, countDrama) = await SmartListEvaluator.EvaluateAsync(
            db, user.Id, new SmartCollectionRules { Genres = ["Drama"] }, 0, 10, CancellationToken.None);
        Assert.Equal(1, countDrama);
        Assert.Equal(movie2.Id, Assert.Single(itemsDrama).Id);

        // Evaluate rule: Year 2000-2020
        var (items2000s, count2000s) = await SmartListEvaluator.EvaluateAsync(
            db, user.Id, new SmartCollectionRules { YearMin = 2000, YearMax = 2020 }, 0, 10, CancellationToken.None);
        Assert.Equal(1, count2000s);
        Assert.Equal(movie1.Id, Assert.Single(items2000s).Id);
    }

    [Fact]
    public void EpisodesCountWithTheirSeriesGenres()
    {
        var series = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Series, DetectedTitle = "Invented Harbor", Metadata = new MediaMetadata { ProviderGenresJson = "[\"Drama\",\"Crime\"]" } };
        var episode = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Episode, DetectedTitle = "Pilot", Parent = series, ParentId = series.Id };
        var movie = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Movie, DetectedTitle = "Invented Heist", Metadata = new MediaMetadata { ProviderGenresJson = "[\"Action\"]" } };

        Assert.Equal(["Drama", "Crime"], WatchHistoryService.Genres(episode));
        Assert.Equal(["Action"], WatchHistoryService.Genres(movie));
    }

    [Fact]
    public async Task WatchEventsAreRecordedAndHistoryIsStrictlyPrivate()
    {
        var mediaRoot = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaRoot);
        await File.WriteAllBytesAsync(Path.Combine(mediaRoot, "Film.mkv"), [1]);

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
            var mediaId = Assert.Single(movies).Id;

            // Create viewer
            var user = await SendAsync<UserSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/users",
                new CreateUserRequest("watcher", "another correct horse password", UserRole.User, ApiTestClient.TestPin, AccessMode: ProfileAccessMode.EntireLibrary));
            using var login = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/auth/login", owner.Token,
                new LoginRequest("watcher", "another correct horse password", "Viewer Mac"));
            using var loginResponse = await ApiTestClient.SendAsync(client, login);
            var viewerAuth = await ApiTestClient.ReadAsync<AuthenticationResponse>(loginResponse);

            // Viewer watches film (records progress)
            using var progressReq = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{mediaId}/progress", viewerAuth.Token,
                new UpdatePlaybackProgressRequest(120_000, 600_000, false));
            using var progressResp = await ApiTestClient.SendAsync(client, progressReq);
            Assert.True(progressResp.IsSuccessStatusCode);

            // Viewer's history contains the event
            var viewerHistory = await SendAsync<WatchHistoryPage>(client, viewerAuth.Token, HttpMethod.Get, "/api/v1/history");
            Assert.Equal(1, viewerHistory.Total);
            var item = Assert.Single(viewerHistory.Items);
            Assert.Equal(mediaId, item.MediaId);
            Assert.Equal(120_000, item.PositionMilliseconds);

            // Owner's history does NOT contain viewer's event (strict privacy)
            var ownerHistory = await SendAsync<WatchHistoryPage>(client, owner.Token, HttpMethod.Get, "/api/v1/history");
            Assert.Equal(0, ownerHistory.Total);
            Assert.Empty(ownerHistory.Items);

            // Statistics for viewer
            var stats = await SendAsync<UserStatistics>(client, viewerAuth.Token, HttpMethod.Get, "/api/v1/statistics");
            Assert.True(stats.TotalHoursWatched >= 0);

            // Statistics keep exact minutes: ten minutes are not rounded to a tenth of an hour.
            var tenMinutes = Guid.NewGuid();
            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                db.WatchEvents.Add(new WatchEvent
                {
                    Id = tenMinutes,
                    UserId = user.Id,
                    MediaItemId = mediaId,
                    Timestamp = DateTimeOffset.UtcNow,
                    PositionMilliseconds = 720_000,
                    DurationMilliseconds = 6_000_000,
                    SecondsWatched = 600,
                });
                await db.SaveChangesAsync();
            }
            var exact = await SendAsync<UserStatistics>(client, viewerAuth.Token, HttpMethod.Get, "/api/v1/statistics");
            Assert.InRange(exact.TotalHoursWatched - stats.TotalHoursWatched, 599 / 3600.0, 601 / 3600.0);
            Assert.InRange(exact.HoursPast7Days - stats.HoursPast7Days, 599 / 3600.0, 601 / 3600.0);
            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                await db.WatchEvents.Where(e => e.Id == tenMinutes).ExecuteDeleteAsync();
            }

            // Viewer deletes single event
            using var deleteEvent = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/history/{item.Id}", viewerAuth.Token);
            using var deleteEventResp = await ApiTestClient.SendAsync(client, deleteEvent);
            Assert.Equal(HttpStatusCode.NoContent, deleteEventResp.StatusCode);

            var afterDelete = await SendAsync<WatchHistoryPage>(client, viewerAuth.Token, HttpMethod.Get, "/api/v1/history");
            Assert.Equal(0, afterDelete.Total);
        }
        finally
        {
            Directory.Delete(mediaRoot, recursive: true);
        }
    }

    [Fact]
    public async Task LibraryHealthDetectsDuplicatesAndNeverTouchesMediaFilesOnDisk()
    {
        var mediaRoot = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaRoot);
        var file1 = Path.Combine(mediaRoot, "Duplicate 1080p.mkv");
        var file2 = Path.Combine(mediaRoot, "Duplicate 4K.mkv");
        await File.WriteAllBytesAsync(file1, [1, 2, 3]);
        await File.WriteAllBytesAsync(file2, [1, 2, 3, 4]);

        var file1BytesBefore = await File.ReadAllBytesAsync(file1);
        var file2BytesBefore = await File.ReadAllBytesAsync(file2);

        try
        {
            using var factory = CreateFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            using var scope = factory.Services.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();

            var library = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Movies",
                Path = mediaRoot,
                Kind = LibraryKind.Movies,
                Availability = LibraryAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow
            };
            db.LibraryRoots.Add(library);

            var item1 = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = file1,
                NormalizedSourcePath = file1,
                DetectedTitle = "Same Movie",
                Year = 2022,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Metadata = new MediaMetadata
                {
                    Provider = "tmdb",
                    ProviderMediaId = "99999",
                    ProviderTitle = "Same Movie",
                    UpdatedAt = DateTimeOffset.UtcNow
                }
            };

            var item2 = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = file2,
                NormalizedSourcePath = file2,
                DetectedTitle = "Same Movie",
                Year = 2022,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Metadata = new MediaMetadata
                {
                    Provider = "tmdb",
                    ProviderMediaId = "99999",
                    ProviderTitle = "Same Movie",
                    UpdatedAt = DateTimeOffset.UtcNow
                }
            };

            db.MediaItems.AddRange(item1, item2);
            await db.SaveChangesAsync();

            // Check health duplicates endpoint
            var duplicates = await SendAsync<List<DuplicateGroup>>(client, owner.Token, HttpMethod.Get, "/api/v1/library/health/duplicates");
            var group = Assert.Single(duplicates);
            Assert.Equal("Same Movie", group.Title);
            Assert.Equal(2, group.Items.Count);
            Assert.All(group.Items, item => Assert.DoesNotContain(Path.DirectorySeparatorChar, item.FileName));

            // A copy whose file still exists cannot be merged or removed here: the next scan would bring it back.
            using var refusedMerge = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/library/health/merge", owner.Token,
                new MergeMediaRequest(item2.Id, item1.Id));
            using var refusedMergeResponse = await ApiTestClient.SendAsync(client, refusedMerge);
            Assert.Equal(HttpStatusCode.Conflict, refusedMergeResponse.StatusCode);
            using var refusedRemoval = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/library/health/entries/{item2.Id}", owner.Token);
            using var refusedRemovalResponse = await ApiTestClient.SendAsync(client, refusedRemoval);
            Assert.Equal(HttpStatusCode.Conflict, refusedRemovalResponse.StatusCode);
            Assert.Empty(await SendAsync<List<OfflineTitleSummary>>(client, owner.Token, HttpMethod.Get, "/api/v1/library/health/offline?days=0"));

            // Once its file is missing, every profile's favorite, progress and history moves to
            // the remaining copy, not only those of the administrator who merges.
            await SendAsync<object>(client, owner.Token, HttpMethod.Put, $"/api/v1/media/{item2.Id}/favorite", new SetFavoriteRequest(true));
            var viewer = new ServerUser
            {
                Id = Guid.NewGuid(),
                Username = "viewer",
                NormalizedUsername = "VIEWER",
                PasswordHash = "synthetic-only",
                Role = UserRole.User,
                IsEnabled = true,
                CreatedAt = DateTimeOffset.UtcNow
            };
            db.Users.Add(viewer);
            db.UserFavorites.Add(new UserFavorite { Id = Guid.NewGuid(), UserId = viewer.Id, MediaItemId = item2.Id, CreatedAt = DateTimeOffset.UtcNow });
            db.PlaybackProgress.Add(new PlaybackProgress
            {
                Id = Guid.NewGuid(),
                UserId = viewer.Id,
                User = null!,
                MediaItemId = item2.Id,
                MediaItem = null!,
                PositionMilliseconds = 60_000,
                DurationMilliseconds = 120_000,
                LastPlayedAt = DateTimeOffset.UtcNow,
                Revision = 1,
            });
            db.WatchEvents.Add(new WatchEvent
            {
                Id = Guid.NewGuid(),
                UserId = viewer.Id,
                MediaItemId = item2.Id,
                Timestamp = DateTimeOffset.UtcNow,
                PositionMilliseconds = 60_000,
                DurationMilliseconds = 120_000,
                SecondsWatched = 60,
            });
            await db.SaveChangesAsync();
            await db.MediaItems.Where(item => item.Id == item2.Id)
                .ExecuteUpdateAsync(update => update.SetProperty(item => item.Availability, MediaAvailability.Missing));
            var offline = await SendAsync<List<OfflineTitleSummary>>(client, owner.Token, HttpMethod.Get, "/api/v1/library/health/offline?days=0");
            Assert.Equal(item2.Id, Assert.Single(offline).Id);
            Assert.Equal("Duplicate 4K.mkv", offline[0].FileName);

            using var mergeReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/library/health/merge", owner.Token,
                new MergeMediaRequest(item2.Id, item1.Id));
            using var mergeResp = await ApiTestClient.SendAsync(client, mergeReq);
            Assert.Equal(HttpStatusCode.NoContent, mergeResp.StatusCode);

            var remaining = await SendAsync<List<DuplicateGroup>>(client, owner.Token, HttpMethod.Get, "/api/v1/library/health/duplicates");
            Assert.Empty(remaining);
            using var verify = factory.Services.CreateScope();
            var verifyDb = verify.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.False(await verifyDb.MediaItems.AnyAsync(item => item.Id == item2.Id));
            Assert.True(await verifyDb.UserFavorites.AnyAsync(favorite => favorite.MediaItemId == item1.Id && favorite.UserId == owner.User.Id));
            Assert.True(await verifyDb.UserFavorites.AnyAsync(favorite => favorite.MediaItemId == item1.Id && favorite.UserId == viewer.Id));
            Assert.Equal(60_000, (await verifyDb.PlaybackProgress.SingleAsync(progress => progress.UserId == viewer.Id)).PositionMilliseconds);
            Assert.Equal(item1.Id, (await verifyDb.WatchEvents.SingleAsync(watch => watch.UserId == viewer.Id)).MediaItemId);
            Assert.True(await verifyDb.MediaExclusions.AnyAsync(), "The removed copy stays out of future scans.");

            // INVARIANT CHECK: Media files on disk MUST NOT be deleted, renamed, or modified!
            Assert.True(File.Exists(file1), "File 1 must still exist on disk!");
            Assert.True(File.Exists(file2), "File 2 must still exist on disk!");
            Assert.Equal(file1BytesBefore, await File.ReadAllBytesAsync(file1));
            Assert.Equal(file2BytesBefore, await File.ReadAllBytesAsync(file2));
        }
        finally
        {
            Directory.Delete(mediaRoot, recursive: true);
        }
    }

    [Fact]
    public void BoxSetsModelHasNoPendingModelChangesAndReportsCollectionsV3Capability()
    {
        using var factory = CreateFactory();
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        Assert.False(db.Database.HasPendingModelChanges());
        Assert.Contains(ServerFeatures.CollectionsV3, ServerFeatures.Reported(liveConversion: false));
        Assert.Contains(ServerFeatures.CollectionsV3, ServerFeatures.Reported(liveConversion: true));
    }

    [Fact]
    public async Task BoxSetsMigrationUpgradePreservesCollectionMembersAndSupportsSeasonIndexes()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var options = new DbContextOptionsBuilder<AureliaDbContext>()
            .UseSqlite($"Data Source={Path.Combine(root, "aurelia.db")};Pooling=False")
            .Options;
        try
        {
            await using var database = new AureliaDbContext(options);
            await database.Database.GetService<IMigrator>().MigrateAsync("20261112122440_SuggestionKeywords");

            var ownerId = Guid.NewGuid();
            var libraryId = Guid.NewGuid();
            var movieId = Guid.NewGuid();
            var seriesId = Guid.NewGuid();
            var collectionId = Guid.NewGuid();
            var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

            await database.Database.ExecuteSqlInterpolatedAsync($"""
                INSERT INTO Users (Id, Username, NormalizedUsername, PasswordHash, Role, CreatedAt, IsEnabled, AccessMode, AccessRevision, PinProtectionEnabled, ProfileRevision)
                VALUES ({ownerId}, 'Owner', 'OWNER', 'synthetic-hash', 'Owner', {nowMs}, 1, 'EntireLibrary', 1, 0, 0);
                INSERT INTO LibraryRoots (Id, Name, Path, NormalizedPath, Kind, Availability, MonitoringEnabled, ImportPreviewRequired, ImportAssignmentRevision, CreatedAt)
                VALUES ({libraryId}, 'Synthetic', '/tmp/synthetic-migrate', '/TMP/SYNTHETIC-MIGRATE', 'Mixed', 'Available', 0, 0, 0, {nowMs});
                INSERT INTO MediaItems (Id, LibraryRootId, Kind, SourcePath, NormalizedSourcePath, ManualSourceBinding, DetectedTitle, Category, Availability, CreatedAt, UpdatedAt)
                VALUES ({movieId}, {libraryId}, 'Movie', '/tmp/synthetic-migrate/film.mkv', 'FILM', 0, 'Legacy Film', '', 'Available', {nowMs}, {nowMs}),
                       ({seriesId}, {libraryId}, 'Series', '/tmp/synthetic-migrate/show', 'SHOW', 0, 'Legacy Show', '', 'Available', {nowMs}, {nowMs});
                INSERT INTO MediaCollections (Id, Name, IsManual, IsSmart, UserId, CreatedAt, UpdatedAt)
                VALUES ({collectionId}, 'Legacy Box', 1, 0, {ownerId}, {nowMs}, {nowMs});
                INSERT INTO MediaCollectionMembers (CollectionId, MediaItemId, SortOrder)
                VALUES ({collectionId}, {movieId}, 0), ({collectionId}, {seriesId}, 1);
                """);

            await database.Database.MigrateAsync();

            var migratedMembers = await database.MediaCollectionMembers
                .AsNoTracking()
                .Where(m => m.CollectionId == collectionId)
                .OrderBy(m => m.SortOrder)
                .ToListAsync();
            Assert.Equal(2, migratedMembers.Count);
            Assert.Equal(movieId, migratedMembers[0].MediaItemId);
            Assert.Equal(seriesId, migratedMembers[1].MediaItemId);
            Assert.All(migratedMembers, m =>
            {
                Assert.NotEqual(Guid.Empty, m.Id);
                Assert.Null(m.SeasonNumber);
            });

            // Filtered unique indexes allow (seriesId, 0) and (seriesId, 1) alongside (seriesId, null),
            // while rejecting duplicates of (seriesId, 0).
            database.MediaCollectionMembers.Add(new MediaCollectionMember
            {
                Id = Guid.NewGuid(),
                CollectionId = collectionId,
                MediaItemId = seriesId,
                SeasonNumber = 0,
                SortOrder = 2,
            });
            database.MediaCollectionMembers.Add(new MediaCollectionMember
            {
                Id = Guid.NewGuid(),
                CollectionId = collectionId,
                MediaItemId = seriesId,
                SeasonNumber = 1,
                SortOrder = 3,
            });
            await database.SaveChangesAsync();

            database.MediaCollectionMembers.Add(new MediaCollectionMember
            {
                Id = Guid.NewGuid(),
                CollectionId = collectionId,
                MediaItemId = seriesId,
                SeasonNumber = 0,
                SortOrder = 4,
            });
            await Assert.ThrowsAsync<DbUpdateException>(() => database.SaveChangesAsync());
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task BoxSetsBug2NullSafeAndEpisodesSeasonsAndDetailMetricsWork()
    {
        using var factory = CreateFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        Guid movieId, seriesId, special1Id, s1EpId;
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var library = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Synthetic Box Library",
                Path = "/tmp/synthetic-box-2",
                NormalizedPath = "/TMP/SYNTHETIC-BOX-2",
                Availability = LibraryAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            var movie = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = "/tmp/synthetic-box-2/film.mkv",
                NormalizedSourcePath = "FILM2005",
                DetectedTitle = "Grand Special",
                Year = 2005,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Metadata = new MediaMetadata
                {
                    ManualTitle = "Grand Special",
                    ManualReleaseYear = 2005,
                    ManualRuntimeMinutes = 120,
                    ManualGenresJson = "[\"Action\"]",
                    ManualFieldsJson = "[\"title\",\"releaseYear\",\"runtimeMinutes\",\"genres\"]",
                },
            };
            movie.Metadata.MediaItemId = movie.Id;

            var series = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Series,
                SourcePath = "/tmp/synthetic-box-2/show",
                NormalizedSourcePath = "SHOWTG",
                DetectedTitle = "Road Adventures",
                Year = 2008,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Metadata = new MediaMetadata
                {
                    ManualTitle = "Road Adventures",
                    ManualGenresJson = "[\"Documentary\",\"Comedy\"]",
                    ManualFieldsJson = "[\"title\",\"genres\"]",
                },
            };
            series.Metadata.MediaItemId = series.Id;

            var sp1 = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                ParentId = series.Id,
                Kind = MediaKind.Episode,
                SeasonNumber = 0,
                EpisodeNumber = 1,
                SourcePath = "/tmp/synthetic-box-2/show/s0e1.mkv",
                NormalizedSourcePath = "S0E1",
                DetectedTitle = "Winter Challenge",
                Year = 2008,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Metadata = new MediaMetadata
                {
                    ManualRuntimeMinutes = 50,
                    ManualFieldsJson = "[\"runtimeMinutes\"]",
                },
            };
            sp1.Metadata.MediaItemId = sp1.Id;

            var sp2 = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                ParentId = series.Id,
                Kind = MediaKind.Episode,
                SeasonNumber = 0,
                EpisodeNumber = 2,
                SourcePath = "/tmp/synthetic-box-2/show/s0e2.mkv",
                NormalizedSourcePath = "S0E2",
                DetectedTitle = "Jungle Crossing",
                Year = 2019,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Metadata = new MediaMetadata
                {
                    ManualRuntimeMinutes = 60,
                    ManualFieldsJson = "[\"runtimeMinutes\"]",
                },
            };
            sp2.Metadata.MediaItemId = sp2.Id;

            var s1e1 = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                ParentId = series.Id,
                Kind = MediaKind.Episode,
                SeasonNumber = 1,
                EpisodeNumber = 1,
                SourcePath = "/tmp/synthetic-box-2/show/s1e1.mkv",
                NormalizedSourcePath = "S1E1",
                DetectedTitle = "Track Test",
                Year = 2009,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Metadata = new MediaMetadata
                {
                    ManualRuntimeMinutes = 45,
                    ManualFieldsJson = "[\"runtimeMinutes\"]",
                },
            };
            s1e1.Metadata.MediaItemId = s1e1.Id;

            db.AddRange(library, movie, series, sp1, sp2, s1e1);
            db.PlaybackProgress.Add(new PlaybackProgress
            {
                Id = Guid.NewGuid(),
                UserId = owner.User.Id,
                User = null!,
                MediaItemId = sp1.Id,
                MediaItem = null!,
                PositionMilliseconds = 3_000_000,
                DurationMilliseconds = 3_000_000,
                IsCompleted = true,
                LastPlayedAt = DateTimeOffset.UtcNow.AddMinutes(-10),
                UpdatedAt = DateTimeOffset.UtcNow.AddMinutes(-10),
                Revision = 1,
            });
            await db.SaveChangesAsync();
            movieId = movie.Id;
            seriesId = series.Id;
            special1Id = sp1.Id;
            s1EpId = s1e1.Id;
        }

        // Missing mediaIds and members save an empty collection instead of failing.
        var created = await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/collections",
            new SaveCollectionRequest("Complete Specials", MediaIds: null, IsSmart: false, IsShared: false,
                Overview: "All specials in viewing order.", SortMode: "custom", Members: null));
        Assert.Equal("Complete Specials", created.Name);
        Assert.Equal("All specials in viewing order.", created.Overview);
        Assert.Equal("custom", created.SortMode);
        Assert.True(created.CanEdit);
        Assert.Null(created.Provider);
        Assert.Equal(0, created.ItemCount);

        // Update with (Series, SeasonNumber=0), Movie, and single Episode.
        var updated = await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Put, $"/api/v1/collections/{created.Id}",
            new SaveCollectionRequest(
                "Complete Specials",
                IsSmart: false,
                IsShared: false,
                Overview: "Curated specials box set.",
                SortMode: "custom",
                Members: [
                    new CollectionMemberInput(seriesId, SeasonNumber: 0),
                    new CollectionMemberInput(movieId),
                    new CollectionMemberInput(s1EpId),
                ]));
        Assert.Equal(4, updated.ItemCount);
        Assert.Equal(1, updated.WatchedCount);
        Assert.Equal("2005\u20132019", updated.YearRange);

        var detail = await SendAsync<CollectionDetail>(client, owner.Token, HttpMethod.Get, $"/api/v1/collections/{created.Id}");
        Assert.Equal(3, detail.Members.Count);
        Assert.Equal(0, detail.Members[0].SeasonNumber);
        Assert.Equal(2, detail.Members[0].Episodes?.Count);
        Assert.Contains(detail.Members[0].Episodes!, ep => ep.Id == special1Id);
        Assert.Equal(2, detail.Members[0].ItemCount);
        Assert.Equal(1, detail.Members[0].WatchedCount);
        Assert.Equal((50 + 60) * 60L, detail.Members[0].TotalRuntimeSeconds);
        Assert.Equal(MediaKind.Movie, detail.Members[1].Kind);
        Assert.Equal(MediaKind.Episode, detail.Members[2].Kind);
        Assert.Equal((50 + 60 + 120 + 45) * 60L, detail.TotalRuntimeSeconds);
        Assert.Contains("Action", detail.Genres);
        Assert.Contains("Documentary", detail.Genres);
        Assert.True(detail.CanEdit);

        // Removing and adding season & episode items via query-string API works cleanly.
        using (var delSeasonReq = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/collections/{created.Id}/items/{seriesId}?seasonNumber=0", owner.Token))
        using (var delSeasonResp = await ApiTestClient.SendAsync(client, delSeasonReq))
            Assert.Equal(HttpStatusCode.NoContent, delSeasonResp.StatusCode);

        using (var addSeasonReq = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/collections/{created.Id}/items/{seriesId}?seasonNumber=0", owner.Token))
        using (var addSeasonResp = await ApiTestClient.SendAsync(client, addSeasonReq))
            Assert.Equal(HttpStatusCode.NoContent, addSeasonResp.StatusCode);

        // Invalid sort mode and season on a movie are rejected with 400.
        using (var invalidMovieSeason = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/collections/{created.Id}/items/{movieId}?seasonNumber=1", owner.Token))
        using (var invalidMovieResp = await ApiTestClient.SendAsync(client, invalidMovieSeason))
            Assert.Equal(HttpStatusCode.BadRequest, invalidMovieResp.StatusCode);

        using (var invalidSortReq = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/collections/{created.Id}", owner.Token,
            new SaveCollectionRequest("Complete Specials", SortMode: "random", Members: [])))
        using (var invalidSortResp = await ApiTestClient.SendAsync(client, invalidSortReq))
            Assert.Equal(HttpStatusCode.BadRequest, invalidSortResp.StatusCode);
    }

    [Fact]
    public async Task BoxSetsReorderSortModesAndSmartListSortingWork()
    {
        using var factory = CreateFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        Guid alphaId, betaId;
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var library = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Sort Library",
                Path = "/tmp/synthetic-sort-box",
                NormalizedPath = "/TMP/SYNTHETIC-SORT-BOX",
                Availability = LibraryAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            var alpha = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = "/tmp/synthetic-sort-box/alpha.mkv",
                NormalizedSourcePath = "ALPHA",
                DetectedTitle = "Alpha",
                Year = 2022,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Metadata = new MediaMetadata { ManualTitle = "Alpha", ManualReleaseYear = 2022, ManualFieldsJson = "[\"title\",\"releaseYear\"]" },
            };
            alpha.Metadata.MediaItemId = alpha.Id;
            var beta = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = "/tmp/synthetic-sort-box/beta.mkv",
                NormalizedSourcePath = "BETA",
                DetectedTitle = "Beta",
                Year = 2010,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Metadata = new MediaMetadata { ManualTitle = "Beta", ManualReleaseYear = 2010, ManualFieldsJson = "[\"title\",\"releaseYear\"]" },
            };
            beta.Metadata.MediaItemId = beta.Id;
            db.AddRange(library, alpha, beta);
            await db.SaveChangesAsync();
            alphaId = alpha.Id;
            betaId = beta.Id;
        }

        var box = await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/collections",
            new SaveCollectionRequest("Sort Box", SortMode: "custom", Members: [new(alphaId), new(betaId)]));

        var reordered = await SendAsync<CollectionDetail>(client, owner.Token, HttpMethod.Put, $"/api/v1/collections/{box.Id}/order",
            new CollectionOrderRequest([new(betaId), new(alphaId)], SortMode: "custom"));
        Assert.Equal([betaId, alphaId], reordered.Members.Select(m => m.MediaId).ToArray());

        await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Put, $"/api/v1/collections/{box.Id}",
            new SaveCollectionRequest("Sort Box", SortMode: "title", Members: [new(betaId), new(alphaId)]));
        var byTitle = await SendAsync<CollectionDetail>(client, owner.Token, HttpMethod.Get, $"/api/v1/collections/{box.Id}");
        Assert.Equal([alphaId, betaId], byTitle.Members.Select(m => m.MediaId).ToArray());

        await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Put, $"/api/v1/collections/{box.Id}",
            new SaveCollectionRequest("Sort Box", SortMode: "release", Members: [new(alphaId), new(betaId)]));
        var byRelease = await SendAsync<CollectionDetail>(client, owner.Token, HttpMethod.Get, $"/api/v1/collections/{box.Id}");
        Assert.Equal([betaId, alphaId], byRelease.Members.Select(m => m.MediaId).ToArray());

        var smart = await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/collections",
            new SaveCollectionRequest("Smart Box", IsSmart: true, RulesJson: """{"kind":"movie"}""", SortMode: "release"));
        var smartDetail = await SendAsync<CollectionDetail>(client, owner.Token, HttpMethod.Get, $"/api/v1/collections/{smart.Id}");
        Assert.Equal("release", smartDetail.SortMode);
        Assert.Equal([betaId, alphaId], smartDetail.Members.Select(m => m.MediaId).ToArray());
    }

    [Fact]
    public async Task BoxSetsNextPlaybackAdvancesAndResumesAcrossMoviesAndSeasons()
    {
        using var factory = CreateFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        Guid movie1Id, seriesId, ep1Id, ep2Id, movie2Id;
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var library = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Next Library",
                Path = "/tmp/synthetic-next-box",
                NormalizedPath = "/TMP/SYNTHETIC-NEXT-BOX",
                Availability = LibraryAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            var movie1 = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = "/tmp/synthetic-next-box/m1.mkv",
                NormalizedSourcePath = "M1NEXT",
                DetectedTitle = "Part One",
                Year = 2010,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
            };
            var series = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Series,
                SourcePath = "/tmp/synthetic-next-box/s",
                NormalizedSourcePath = "SNEXT",
                DetectedTitle = "Interlude Show",
                Year = 2012,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
            };
            var ep1 = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                ParentId = series.Id,
                Kind = MediaKind.Episode,
                SeasonNumber = 0,
                EpisodeNumber = 1,
                SourcePath = "/tmp/synthetic-next-box/s/e1.mkv",
                NormalizedSourcePath = "E1NEXT",
                DetectedTitle = "Special One",
                Year = 2012,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
            };
            var ep2 = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                ParentId = series.Id,
                Kind = MediaKind.Episode,
                SeasonNumber = 0,
                EpisodeNumber = 2,
                SourcePath = "/tmp/synthetic-next-box/s/e2.mkv",
                NormalizedSourcePath = "E2NEXT",
                DetectedTitle = "Special Two",
                Year = 2013,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
            };
            var movie2 = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = "/tmp/synthetic-next-box/m2.mkv",
                NormalizedSourcePath = "M2NEXT",
                DetectedTitle = "Finale Movie",
                Year = 2015,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
            };
            db.AddRange(library, movie1, series, ep1, ep2, movie2);
            await db.SaveChangesAsync();
            movie1Id = movie1.Id;
            seriesId = series.Id;
            ep1Id = ep1.Id;
            ep2Id = ep2.Id;
            movie2Id = movie2.Id;
        }

        var box = await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/collections",
            new SaveCollectionRequest("Play Box", SortMode: "custom",
                Members: [new(movie1Id), new(seriesId, SeasonNumber: 0), new(movie2Id)]));

        var step1 = await SendAsync<CollectionNextResponse>(client, owner.Token, HttpMethod.Get, $"/api/v1/collections/{box.Id}/next");
        Assert.Equal(movie1Id, step1.Item.Id);
        Assert.False(step1.Resume);
        Assert.Equal(0, step1.PositionMilliseconds);
        Assert.Equal(0, step1.ItemIndex);
        Assert.Equal(4, step1.TotalItems);

        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var t = DateTimeOffset.UtcNow;
            db.PlaybackProgress.AddRange(
                new PlaybackProgress { Id = Guid.NewGuid(), UserId = owner.User.Id, User = null!, MediaItemId = movie1Id, MediaItem = null!, PositionMilliseconds = 5_400_000, DurationMilliseconds = 5_400_000, IsCompleted = true, LastPlayedAt = t.AddMinutes(-20), UpdatedAt = t.AddMinutes(-20), Revision = 1 },
                new PlaybackProgress { Id = Guid.NewGuid(), UserId = owner.User.Id, User = null!, MediaItemId = ep1Id, MediaItem = null!, PositionMilliseconds = 123_000, DurationMilliseconds = 2_400_000, IsCompleted = false, LastPlayedAt = t.AddMinutes(-5), UpdatedAt = t.AddMinutes(-5), Revision = 1 });
            await db.SaveChangesAsync();
        }
        var step2 = await SendAsync<CollectionNextResponse>(client, owner.Token, HttpMethod.Get, $"/api/v1/collections/{box.Id}/next");
        Assert.Equal(ep1Id, step2.Item.Id);
        Assert.True(step2.Resume);
        Assert.Equal(123_000, step2.PositionMilliseconds);
        Assert.Equal(1, step2.ItemIndex);

        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var ep1Progress = await db.PlaybackProgress.SingleAsync(p => p.MediaItemId == ep1Id && p.UserId == owner.User.Id);
            ep1Progress.IsCompleted = true;
            ep1Progress.PositionMilliseconds = ep1Progress.DurationMilliseconds;
            ep1Progress.Revision = 2;
            await db.SaveChangesAsync();
        }
        var step3 = await SendAsync<CollectionNextResponse>(client, owner.Token, HttpMethod.Get, $"/api/v1/collections/{box.Id}/next");
        Assert.Equal(ep2Id, step3.Item.Id);
        Assert.False(step3.Resume);
        Assert.Equal(2, step3.ItemIndex);

        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var t = DateTimeOffset.UtcNow;
            db.PlaybackProgress.AddRange(
                new PlaybackProgress { Id = Guid.NewGuid(), UserId = owner.User.Id, User = null!, MediaItemId = ep2Id, MediaItem = null!, PositionMilliseconds = 2_400_000, DurationMilliseconds = 2_400_000, IsCompleted = true, LastPlayedAt = t.AddMinutes(-2), UpdatedAt = t.AddMinutes(-2), Revision = 1 },
                new PlaybackProgress { Id = Guid.NewGuid(), UserId = owner.User.Id, User = null!, MediaItemId = movie2Id, MediaItem = null!, PositionMilliseconds = 4_800_000, DurationMilliseconds = 4_800_000, IsCompleted = true, LastPlayedAt = t, UpdatedAt = t, Revision = 1 });
            await db.SaveChangesAsync();
        }
        var step4 = await SendAsync<CollectionNextResponse>(client, owner.Token, HttpMethod.Get, $"/api/v1/collections/{box.Id}/next");
        Assert.Equal(movie1Id, step4.Item.Id);
        Assert.False(step4.Resume);
        Assert.Equal(0, step4.ItemIndex);
    }

    [Fact]
    public async Task BoxSetsArtworkUploadCropMosaicFallbackAndCleanupWork()
    {
        using var factory = CreateFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        Guid movie1Id, movie2Id;
        string dataDir;
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            dataDir = scope.ServiceProvider.GetRequiredService<ServerRuntimeOptions>().DataDirectory;
            var library = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Art Library",
                Path = "/tmp/synthetic-art-box",
                NormalizedPath = "/TMP/SYNTHETIC-ART-BOX",
                Availability = LibraryAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            var movie1 = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = "/tmp/synthetic-art-box/m1.mkv",
                NormalizedSourcePath = "ARTM1",
                DetectedTitle = "Red Title",
                Year = 2011,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Metadata = new MediaMetadata(),
            };
            movie1.Metadata.MediaItemId = movie1.Id;
            var movie2 = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = "/tmp/synthetic-art-box/m2.mkv",
                NormalizedSourcePath = "ARTM2",
                DetectedTitle = "Blue Title",
                Year = 2012,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Metadata = new MediaMetadata(),
            };
            movie2.Metadata.MediaItemId = movie2.Id;
            db.AddRange(library, movie1, movie2);

            var artworkDir = Path.Combine(dataDir, "Artwork");
            Directory.CreateDirectory(artworkDir);
            var poster1Bytes = CreateSolidPng(400, 600, new SKColor(220, 40, 40));
            var poster2Bytes = CreateSolidPng(400, 600, new SKColor(40, 90, 220));
            var backdrop1Bytes = CreateSolidPng(960, 540, new SKColor(30, 160, 70));

            await File.WriteAllBytesAsync(Path.Combine(artworkDir, "m1-poster.png"), poster1Bytes);
            await File.WriteAllBytesAsync(Path.Combine(artworkDir, "m2-poster.png"), poster2Bytes);
            await File.WriteAllBytesAsync(Path.Combine(artworkDir, "m1-backdrop.png"), backdrop1Bytes);

            db.ArtworkAssets.AddRange(
                new ArtworkAsset { Id = Guid.NewGuid(), MediaItemId = movie1.Id, Kind = ArtworkKind.Poster, ProviderPath = "/m1p.png", RelativeFilePath = "m1-poster.png", ContentType = "image/png", ContentLength = poster1Bytes.Length, Revision = 1, CreatedAt = DateTimeOffset.UtcNow },
                new ArtworkAsset { Id = Guid.NewGuid(), MediaItemId = movie2.Id, Kind = ArtworkKind.Poster, ProviderPath = "/m2p.png", RelativeFilePath = "m2-poster.png", ContentType = "image/png", ContentLength = poster2Bytes.Length, Revision = 1, CreatedAt = DateTimeOffset.UtcNow },
                new ArtworkAsset { Id = Guid.NewGuid(), MediaItemId = movie1.Id, Kind = ArtworkKind.Backdrop, ProviderPath = "/m1b.png", RelativeFilePath = "m1-backdrop.png", ContentType = "image/png", ContentLength = backdrop1Bytes.Length, Revision = 1, CreatedAt = DateTimeOffset.UtcNow });
            await db.SaveChangesAsync();
            movie1Id = movie1.Id;
            movie2Id = movie2.Id;
        }

        var box = await SendAsync<CollectionSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/collections",
            new SaveCollectionRequest("Art Box", Members: [new(movie1Id), new(movie2Id)]));
        Assert.NotNull(box.Poster);
        Assert.StartsWith($"/api/v1/artwork/collection/{box.Id}?kind=poster", box.Poster!.Path, StringComparison.Ordinal);
        Assert.NotNull(box.Backdrop);
        Assert.StartsWith($"/api/v1/artwork/collection/{box.Id}?kind=backdrop", box.Backdrop!.Path, StringComparison.Ordinal);

        using (var mosaicReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/collection/{box.Id}?kind=poster&width=320", owner.Token))
        using (var mosaicResp = await ApiTestClient.SendAsync(client, mosaicReq))
        {
            mosaicResp.EnsureSuccessStatusCode();
            using var decoded = SKBitmap.Decode(await mosaicResp.Content.ReadAsByteArrayAsync());
            Assert.NotNull(decoded);
            Assert.Equal(320, decoded.Width);
            Assert.Equal(480, decoded.Height);
            Assert.True(decoded.GetPixel(60, 240).Red > 150);
            Assert.True(decoded.GetPixel(260, 240).Blue > 150);
        }

        using (var fbReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/collection/{box.Id}?kind=backdrop", owner.Token))
        using (var fbResp = await ApiTestClient.SendAsync(client, fbReq))
        {
            fbResp.EnsureSuccessStatusCode();
            using var decoded = SKBitmap.Decode(await fbResp.Content.ReadAsByteArrayAsync());
            Assert.True(decoded.GetPixel(100, 100).Green > 120);
        }

        EditorUploadSummary draft;
        var uploadBytes = CreateSolidPng(900, 900, new SKColor(235, 200, 30));
        using (var uploadReq = new HttpRequestMessage(HttpMethod.Post, $"/api/v1/collections/{box.Id}/editor/uploads"))
        {
            uploadReq.Headers.Authorization = new AuthenticationHeaderValue("Bearer", owner.Token);
            uploadReq.Content = new ByteArrayContent(uploadBytes);
            uploadReq.Content.Headers.ContentType = new MediaTypeHeaderValue("image/png");
            using var uploadResp = await ApiTestClient.SendAsync(client, uploadReq);
            uploadResp.EnsureSuccessStatusCode();
            draft = (await uploadResp.Content.ReadFromJsonAsync<EditorUploadSummary>(ApiTestClient.JsonOptions))!;
        }

        using (var draftGetReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/collections/{box.Id}/editor/uploads/{draft.Id}", owner.Token))
        using (var draftGetResp = await ApiTestClient.SendAsync(client, draftGetReq))
            Assert.Equal(HttpStatusCode.OK, draftGetResp.StatusCode);

        var croppedPoster = await SendAsync<ArtworkSummary>(client, owner.Token, HttpMethod.Post, $"/api/v1/collections/{box.Id}/artwork/poster",
            new SaveCollectionArtworkRequest(draft.Id, new ArtworkCrop(0.1, 0.05, 0.6, 0.9)));
        Assert.Equal(1, croppedPoster.Revision);

        var recropped = await SendAsync<ArtworkSummary>(client, owner.Token, HttpMethod.Post, $"/api/v1/collections/{box.Id}/artwork/poster",
            new SaveCollectionArtworkRequest(null, new ArtworkCrop(0.2, 0.1, 0.5, 0.75)));
        Assert.Equal(2, recropped.Revision);

        using (var customReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/collection/{box.Id}?kind=poster", owner.Token))
        using (var customResp = await ApiTestClient.SendAsync(client, customReq))
        {
            customResp.EnsureSuccessStatusCode();
            using var decoded = SKBitmap.Decode(await customResp.Content.ReadAsByteArrayAsync());
            Assert.True(decoded.GetPixel(20, 20).Red > 180 && decoded.GetPixel(20, 20).Green > 150);
        }

        var customBackdropBytes = CreateSolidPng(1280, 720, new SKColor(150, 50, 200));
        using (var rawBackReq = new HttpRequestMessage(HttpMethod.Post, $"/api/v1/collections/{box.Id}/artwork/backdrop"))
        {
            rawBackReq.Headers.Authorization = new AuthenticationHeaderValue("Bearer", owner.Token);
            rawBackReq.Content = new ByteArrayContent(customBackdropBytes);
            rawBackReq.Content.Headers.ContentType = new MediaTypeHeaderValue("image/png");
            using var rawBackResp = await ApiTestClient.SendAsync(client, rawBackReq);
            rawBackResp.EnsureSuccessStatusCode();
        }

        var collectionArtDir = Path.Combine(dataDir, "Artwork", "Collections");
        Assert.True(Directory.EnumerateFiles(collectionArtDir).Any());

        using (var delPoster = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/collections/{box.Id}/artwork/poster", owner.Token))
        using (var delPosterResp = await ApiTestClient.SendAsync(client, delPoster))
            Assert.Equal(HttpStatusCode.NoContent, delPosterResp.StatusCode);

        using (var fallbackAgainReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/collection/{box.Id}?kind=poster&width=320", owner.Token))
        using (var fallbackAgainResp = await ApiTestClient.SendAsync(client, fallbackAgainReq))
        {
            fallbackAgainResp.EnsureSuccessStatusCode();
            using var decoded = SKBitmap.Decode(await fallbackAgainResp.Content.ReadAsByteArrayAsync());
            Assert.True(decoded.GetPixel(60, 240).Red > 150);
        }

        using (var delBox = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/collections/{box.Id}", owner.Token))
        using (var delBoxResp = await ApiTestClient.SendAsync(client, delBox))
            Assert.Equal(HttpStatusCode.NoContent, delBoxResp.StatusCode);

        Assert.Empty(Directory.EnumerateFiles(collectionArtDir));
    }

    [Fact]
    public async Task BoxSetsBug3ManualAndSmartCollectionsSurviveLibraryResetWhileAutomaticIsPruned()
    {
        using var factory = CreateFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        Guid libraryId, autoCollectionId, manualCollectionId, smartCollectionId;
        string autoFilePath;
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var dataDir = scope.ServiceProvider.GetRequiredService<ServerRuntimeOptions>().DataDirectory;
            var collectionsArt = Path.Combine(dataDir, "Artwork", "Collections");
            Directory.CreateDirectory(collectionsArt);
            autoFilePath = Path.Combine(collectionsArt, "auto-prune.png");
            await File.WriteAllBytesAsync(autoFilePath, CreateSolidPng(200, 300, SKColors.SlateBlue));

            var library = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Reset Box Lib",
                Path = "/tmp/synthetic-reset-box",
                NormalizedPath = "/TMP/SYNTHETIC-RESET-BOX",
                Availability = LibraryAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            var movie = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = "/tmp/synthetic-reset-box/film.mkv",
                NormalizedSourcePath = "RESETBOXFILM",
                DetectedTitle = "Ephemeral Film",
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
            };
            var manualCol = new MediaCollectionRecord
            {
                Id = Guid.NewGuid(),
                Name = "Own Box",
                IsManual = true,
                IsSmart = false,
                UserId = owner.User.Id,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
            };
            manualCol.Members.Add(new MediaCollectionMember { Id = Guid.NewGuid(), CollectionId = manualCol.Id, MediaItemId = movie.Id, SortOrder = 0 });
            var smartCol = new MediaCollectionRecord
            {
                Id = Guid.NewGuid(),
                Name = "Smart Action",
                IsManual = true,
                IsSmart = true,
                SmartRulesJson = """{"kind":"movie"}""",
                UserId = owner.User.Id,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
            };
            var autoCol = new MediaCollectionRecord
            {
                Id = Guid.NewGuid(),
                Name = "TMDB Trilogy",
                Provider = "tmdb",
                ProviderCollectionId = "900",
                IsManual = false,
                IsSmart = false,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
            };
            autoCol.Members.Add(new MediaCollectionMember { Id = Guid.NewGuid(), CollectionId = autoCol.Id, MediaItemId = movie.Id, SortOrder = 0 });
            var autoArt = new CollectionArtworkAsset
            {
                Id = Guid.NewGuid(),
                CollectionId = autoCol.Id,
                Kind = ArtworkKind.Poster,
                IsManual = false,
                ProviderPath = "/auto.png",
                RelativeFilePath = "auto-prune.png",
                ContentType = "image/png",
                ContentLength = 100,
                Revision = 1,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            db.AddRange(library, movie, manualCol, smartCol, autoCol, autoArt);
            await db.SaveChangesAsync();

            libraryId = library.Id;
            manualCollectionId = manualCol.Id;
            smartCollectionId = smartCol.Id;
            autoCollectionId = autoCol.Id;
        }

        var preview = await SendAsync<ResetLibraryPreview>(client, owner.Token, HttpMethod.Post, "/api/v1/libraries/reset/preview", new[] { libraryId });
        var payload = new ResetLibraryRequest([libraryId], preview.Revision);
        var bodyBytes = JsonSerializer.SerializeToUtf8Bytes(payload, ApiTestClient.JsonOptions);
        var approval = await SendAsync<AdministrationApprovalResponse>(client, owner.Token, HttpMethod.Post, "/api/v1/libraries/reset/approval",
            new AdministrationApprovalRequest("POST /api/v1/libraries/reset", AdministrationApprovalStore.Hash(bodyBytes)));

        using (var resetReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset", owner.Token, payload))
        {
            resetReq.Headers.Add("X-Aurelia-Approval", approval.Token);
            using var resetResp = await client.SendAsync(resetReq);
            resetResp.EnsureSuccessStatusCode();
        }

        using (var verify = factory.Services.CreateScope())
        {
            var db = verify.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.True(await db.MediaCollections.AnyAsync(c => c.Id == manualCollectionId), "Manual box must survive reset even when emptied.");
            Assert.True(await db.MediaCollections.AnyAsync(c => c.Id == smartCollectionId), "Smart list must survive reset.");
            Assert.False(await db.MediaCollections.AnyAsync(c => c.Id == autoCollectionId), "Empty automatic provider collection must be pruned.");
            Assert.False(File.Exists(autoFilePath), "Pruned automatic collection artwork file must be removed from disk.");
        }
    }

    [Fact]
    public async Task BoxSetsBug4TmdbCollectionEnrichmentStaleRemovalAndCanEdit()
    {
        var fakeTmdb = new BoxSetTmdbClient();
        using var factory = new AureliaServerFactory(configureServices: services =>
        {
            services.RemoveAll<ITmdbClient>();
            services.AddSingleton<ITmdbClient>(fakeTmdb);
        });
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        var settingsResult = await SendAsync<MetadataProviderStatus>(client, owner.Token, HttpMethod.Put, "/api/v1/metadata/provider",
            new UpdateMetadataProviderRequest(true, "en-US", "synthetic-provider-token-with-no-network"));
        Assert.True(settingsResult.Enabled);

        await SendAsync<UserSummary>(client, owner.Token, HttpMethod.Post, "/api/v1/users",
            new CreateUserRequest("viewer", "ViewerPass123!", UserRole.User, ApiTestClient.TestPin));
        using var login = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/auth/login", owner.Token,
            new LoginRequest("viewer", "ViewerPass123!", "Viewer Browser"));
        using var loginResp = await ApiTestClient.SendAsync(client, login);
        var viewer = (await loginResp.Content.ReadFromJsonAsync<AuthenticationResponse>(ApiTestClient.JsonOptions))!;

        Guid movieId;
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var library = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Franchise Lib",
                Path = "/tmp/synthetic-franchise-box",
                NormalizedPath = "/TMP/SYNTHETIC-FRANCHISE-BOX",
                Availability = LibraryAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            var movie = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = "/tmp/synthetic-franchise-box/saga1.mkv",
                NormalizedSourcePath = "SAGA1",
                DetectedTitle = "Saga One",
                Year = 2020,
                Availability = MediaAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
            };
            db.AddRange(library, movie);
            await db.SaveChangesAsync();
            movieId = movie.Id;

            var metadata = scope.ServiceProvider.GetRequiredService<MetadataService>();
            await metadata.ApplyAsync(movie, fakeTmdb.FirstMatch, 0.99, CancellationToken.None);
        }

        await ApiTestClient.GrantExistingLibrariesAsync(client, owner.Token, viewer.User.Id);

        var franchises = await SendAsync<List<CollectionSummary>>(client, viewer.Token, HttpMethod.Get, "/api/v1/catalog/franchises");
        var tmdbBox = Assert.Single(franchises, f => f.Provider == "tmdb");
        Assert.Equal("Galaxy Saga", tmdbBox.Name);
        Assert.Equal("Full saga overview from TMDB.", tmdbBox.Overview);
        Assert.False(tmdbBox.CanEdit);
        Assert.NotNull(tmdbBox.Poster);
        Assert.NotNull(tmdbBox.Backdrop);
        Assert.Contains(franchises, f => f.Provider == MediaUniverses.Provider);

        using (var editProviderReq = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/collections/{tmdbBox.Id}", owner.Token,
            new SaveCollectionRequest("Hijack", Members: [])))
        using (var editProviderResp = await ApiTestClient.SendAsync(client, editProviderReq))
            Assert.Equal(HttpStatusCode.NotFound, editProviderResp.StatusCode);

        using (var imgReq = ApiTestClient.Authorized(HttpMethod.Get, tmdbBox.Poster!.Path, viewer.Token))
        using (var imgResp = await ApiTestClient.SendAsync(client, imgReq))
            Assert.Equal(HttpStatusCode.OK, imgResp.StatusCode);

        var copied = await SendAsync<CollectionSummary>(client, viewer.Token, HttpMethod.Post, $"/api/v1/collections/from-franchise/{tmdbBox.Id}");
        Assert.True(copied.CanEdit);
        Assert.Null(copied.Provider);
        Assert.Equal("Full saga overview from TMDB.", copied.Overview);
        Assert.NotNull(copied.Poster);

        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var movie = await db.MediaItems.Include(m => m.Metadata).SingleAsync(m => m.Id == movieId);
            var metadata = scope.ServiceProvider.GetRequiredService<MetadataService>();
            await metadata.ApplyAsync(movie, fakeTmdb.SecondMatch, 0.99, CancellationToken.None);

            Assert.False(await db.MediaCollections.AnyAsync(c => c.Provider == "tmdb" && c.ProviderCollectionId == "501"));
            Assert.False(await db.MediaCollections.AnyAsync(c => c.Provider == MediaUniverses.Provider));
            Assert.True(await db.MediaCollections.AnyAsync(c => c.Provider == "tmdb" && c.ProviderCollectionId == "502"));
        }

        using (var scope = factory.Services.CreateScope())
        {
            var metadata = scope.ServiceProvider.GetRequiredService<MetadataService>();
            await metadata.ClearMatchAsync(movieId, CancellationToken.None);
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.Empty(await db.MediaCollectionMembers.Where(m => m.MediaItemId == movieId && m.CollectionId != copied.Id).ToListAsync());
            Assert.False(await db.MediaCollections.AnyAsync(c => c.Provider == "tmdb" && c.ProviderCollectionId == "502"));
            Assert.True(await db.MediaCollections.AnyAsync(c => c.Id == copied.Id), "User's copied manual box remains.");
        }
    }

    private static byte[] CreateSolidPng(int width, int height, SKColor color)
    {
        using var bitmap = new SKBitmap(width, height);
        bitmap.Erase(color);
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        return data.ToArray();
    }

    private sealed class BoxSetTmdbClient : ITmdbClient
    {
        private readonly byte[] posterBytes = CreateSolidPng(300, 450, SKColors.DarkOrange);
        private readonly byte[] backdropBytes = CreateSolidPng(640, 360, SKColors.DarkSlateGray);

        public TmdbMetadata FirstMatch { get; } = new(
            "101", "movie", "Saga One", null, "First film.", "2020-05-01", 120, null, "PG-13",
            ["Sci-Fi"], [], [], null, null, [],
            Collection: new("501", "Galaxy Saga", "/saga-poster.png", "/saga-backdrop.png"),
            Keywords: ["marvel cinematic universe"]);

        public TmdbMetadata SecondMatch { get; } = new(
            "102", "movie", "Other Saga", null, "Rematched film.", "2021-06-01", 110, null, "PG",
            ["Adventure"], [], [], null, null, [],
            Collection: new("502", "Second Saga", "/second-poster.png", null),
            Keywords: []);

        public Task ValidateAsync(string token, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(string token, string language, MediaKind kind, string title, int? year, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<MetadataCandidateSummary>>([]);
        public Task<TmdbMetadata> GetAsync(string token, string language, string mediaType, string providerId, CancellationToken cancellationToken) =>
            Task.FromResult(providerId == "102" ? SecondMatch : FirstMatch);
        public Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(string token, string language, string showProviderId, int seasonNumber, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<TmdbEpisodeMetadata>>([]);
        public Task<TmdbCollectionDetail?> GetCollectionAsync(string token, string language, string providerId, CancellationToken cancellationToken) =>
            Task.FromResult<TmdbCollectionDetail?>(providerId == "501"
                ? new TmdbCollectionDetail("501", "Galaxy Saga", "Full saga overview from TMDB.", "/saga-poster.png", "/saga-backdrop.png")
                : new TmdbCollectionDetail("502", "Second Saga", "Second saga overview.", "/second-poster.png", null));
        public Task<byte[]> DownloadImageAsync(string token, string providerPath, string size, CancellationToken cancellationToken) =>
            Task.FromResult(providerPath.Contains("backdrop", StringComparison.Ordinal) ? backdropBytes : posterBytes);
    }
}
