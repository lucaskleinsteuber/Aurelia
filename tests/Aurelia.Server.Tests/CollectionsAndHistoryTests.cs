using System.Net;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
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

            // Once its file is missing, the copy's favorite moves to the remaining copy.
            await SendAsync<object>(client, owner.Token, HttpMethod.Put, $"/api/v1/media/{item2.Id}/favorite", new SetFavoriteRequest(true));
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
            Assert.True(await verifyDb.UserFavorites.AnyAsync(favorite => favorite.MediaItemId == item1.Id));
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
}
