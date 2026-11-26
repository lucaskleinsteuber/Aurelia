using System.Net;
using System.Net.Http.Json;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class LibraryAndDataP3Tests
{
    [Fact]
    public async Task DatabaseBackupLeavesNoTemporaryWalOrShmSidecarFiles()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        await ApiTestClient.SetupOwnerAsync(client);

        using var scope = factory.Services.CreateScope();
        var backups = scope.ServiceProvider.GetRequiredService<DatabaseBackupService>();
        var created = await backups.CreateBackupAsync(DatabaseBackupKind.Manual, CancellationToken.None);
        Assert.True(File.Exists(created));

        var backupDir = Path.GetDirectoryName(created)!;
        var leftovers = Directory.EnumerateFiles(backupDir)
            .Select(Path.GetFileName)
            .Where(name => name is not null && (name.Contains(".tmp", StringComparison.Ordinal) || name.EndsWith("-shm", StringComparison.Ordinal) || name.EndsWith("-wal", StringComparison.Ordinal)))
            .ToArray();
        Assert.Empty(leftovers);
    }

    [Fact]
    public void FilenameParserStripsMultiEpisodeRangesAndSidecarMatchesNfcVsNfdAndNormalizePreservesSuperscripts()
    {
        // SRV-LIB-003: Multi-episode range stripped cleanly from title.
        var parsed = FilenameMetadataParser.Episode("Orbit Kitchen - S01E01-E02 - Double Pilot.mkv", expectedSeason: 1);
        Assert.Equal(1, parsed.Season);
        Assert.Equal(1, parsed.Episode);
        Assert.Equal("Double Pilot", parsed.Title);

        var parsedAlt = FilenameMetadataParser.Episode("Show S02E03E04 Finale.mkv", expectedSeason: 2);
        Assert.Equal(2, parsedAlt.Season);
        Assert.Equal(3, parsedAlt.Episode);
        Assert.Equal("Finale", parsedAlt.Title);

        // SRV-LIB-009: NormalizeRelative uses NFC (FormC), so Season² != Season2.
        Assert.NotEqual(MediaPath.NormalizeRelative("Season\u00B2"), MediaPath.NormalizeRelative("Season2"));

        // SRV-LIB-006: NFC video matches NFD sidecar subtitle.
        var dir = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dir);
        try
        {
            var nfcVideo = Path.Combine(dir, "M\u00FCde (2020).mkv");
            var nfdSub = Path.Combine(dir, "Mu\u0308de (2020).en.srt");
            File.WriteAllBytes(nfcVideo, [1, 2, 3, 4]);
            File.WriteAllText(nfdSub, "1\n00:00:01,000 --> 00:00:02,000\nHello\n");
            var subs = SidecarSubtitles.Discover(nfcVideo);
            var matched = Assert.Single(subs);
            Assert.Equal("en", matched.Language);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [Fact]
    public void ScannerReportsSkippedSymbolicLinksAsSummaryIssue()
    {
        if (OperatingSystem.IsWindows()) return;
        var root = TestPaths.CreateDataDirectory();
        var outside = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(outside);
        try
        {
            var realMovie = Path.Combine(root, "Real Movie (2022).mkv");
            File.WriteAllBytes(realMovie, [1, 2, 3, 4]);
            var target = Path.Combine(outside, "Linked Movie (2022).mkv");
            File.WriteAllBytes(target, [1, 2, 3, 4]);
            File.CreateSymbolicLink(Path.Combine(root, "Linked Movie (2022).mkv"), target);

            var discovery = new MediaLibraryScanner().Scan(root, LibraryKind.Movies, [], null, CancellationToken.None);
            Assert.Single(discovery.Items);
            Assert.Contains(discovery.Issues, issue => issue.Code == "symbolic_link_skipped");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
            Directory.Delete(outside, recursive: true);
        }
    }

    [Fact]
    public async Task OfflineStorageLocationMarksCatalogMoviesMissingShowsInHealthAndManualScanResumesWaitingScan()
    {
        var mediaParent = TestPaths.CreateDataDirectory();
        var moviesDir = Path.Combine(mediaParent, "Movies");
        Directory.CreateDirectory(moviesDir);
        await File.WriteAllBytesAsync(Path.Combine(moviesDir, "Island Signal (2024).mkv"), [1, 2, 3, 4]);
        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            using var createLib = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries", owner.Token,
                new CreateLibraryRequest("Movies", moviesDir, LibraryKind.Movies));
            using var libResp = await client.SendAsync(createLib);
            libResp.EnsureSuccessStatusCode();
            var lib = await ApiTestClient.ReadAsync<LibrarySummary>(libResp);

            using (var scanReq = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/libraries/{lib.Id}/scans", owner.Token))
            using (var scanResp = await client.SendAsync(scanReq))
            {
                scanResp.EnsureSuccessStatusCode();
                var scan = await ApiTestClient.ReadAsync<LibraryScanSummary>(scanResp);
                for (var i = 0; i < 60; i++)
                {
                    using var pollReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/scans/{scan.Id}", owner.Token);
                    using var pollResp = await client.SendAsync(pollReq);
                    var current = await ApiTestClient.ReadAsync<LibraryScanSummary>(pollResp);
                    if (current.State == LibraryScanState.Completed) break;
                    await Task.Delay(100);
                }
            }

            // Simulate storage going offline and a scan entering WaitingForStorage.
            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var root = await db.LibraryRoots.SingleAsync(r => r.Id == lib.Id);
                root.Availability = LibraryAvailability.Unavailable;
                db.LibraryScans.Add(new LibraryScan
                {
                    Id = Guid.NewGuid(),
                    LibraryRootId = lib.Id,
                    State = LibraryScanState.WaitingForStorage,
                    Trigger = LibraryScanTrigger.Manual,
                    CreatedAt = DateTimeOffset.UtcNow,
                });
                await db.SaveChangesAsync();
            }

            // DYN-LIFE-004: /catalog/movies, /catalog/movies/{id}, and /library/health/offline reflect offline storage.
            using (var listReq = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/catalog/movies", owner.Token))
            using (var listResp = await client.SendAsync(listReq))
            {
                listResp.EnsureSuccessStatusCode();
                var page = await ApiTestClient.ReadAsync<PagedResponse<MovieSummary>>(listResp);
                var movie = Assert.Single(page.Items);
                Assert.Equal(LibraryAvailability.Unavailable, movie.LibraryAvailability);

                using var detailReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/catalog/movies/{movie.Id}", owner.Token);
                using var detailResp = await client.SendAsync(detailReq);
                detailResp.EnsureSuccessStatusCode();
                var detail = await ApiTestClient.ReadAsync<MovieDetail>(detailResp);
                Assert.Equal(LibraryAvailability.Unavailable, detail.LibraryAvailability);
            }

            using (var offlineReq = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/library/health/offline?days=0", owner.Token))
            using (var offlineResp = await client.SendAsync(offlineReq))
            {
                offlineResp.EnsureSuccessStatusCode();
                var offline = await ApiTestClient.ReadAsync<OfflineTitleSummary[]>(offlineResp);
                Assert.Single(offline);
            }

            // DYN-LIFE-005: Since moviesDir is readable on disk again, manual scan resumes WaitingForStorage with 202 (not 409).
            using (var resumeReq = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/libraries/{lib.Id}/scans", owner.Token))
            using (var resumeResp = await client.SendAsync(resumeReq))
            {
                Assert.Equal(HttpStatusCode.Accepted, resumeResp.StatusCode);
            }
        }
        finally { Directory.Delete(mediaParent, recursive: true); }
    }

    [Fact]
    public async Task ClearingMatchAsRestrictedAdminDoesNotDeleteAutomaticCollectionWithInvisibleMembers()
    {
        var mediaParent = TestPaths.CreateDataDirectory();
        var libADir = Path.Combine(mediaParent, "LibA");
        var libBDir = Path.Combine(mediaParent, "LibB");
        Directory.CreateDirectory(libADir);
        Directory.CreateDirectory(libBDir);
        await File.WriteAllBytesAsync(Path.Combine(libADir, "Part One (2020).mkv"), [1, 2, 3, 4]);
        await File.WriteAllBytesAsync(Path.Combine(libBDir, "Part Two (2022).mkv"), [1, 2, 3, 4]);
        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            Guid movieAId, collectionId;
            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var now = DateTimeOffset.UtcNow;
                var libA = new LibraryRoot { Id = Guid.NewGuid(), Name = "A", Path = libADir, NormalizedPath = MediaPath.Normalize(libADir), Kind = LibraryKind.Movies, Availability = LibraryAvailability.Available, CreatedAt = now };
                var libB = new LibraryRoot { Id = Guid.NewGuid(), Name = "B", Path = libBDir, NormalizedPath = MediaPath.Normalize(libBDir), Kind = LibraryKind.Movies, Availability = LibraryAvailability.Available, CreatedAt = now };
                db.LibraryRoots.AddRange(libA, libB);

                var pathA = Path.Combine(libADir, "Part One (2020).mkv");
                var pathB = Path.Combine(libBDir, "Part Two (2022).mkv");
                var movieA = new MediaItem { Id = Guid.NewGuid(), LibraryRootId = libA.Id, Kind = MediaKind.Movie, DetectedTitle = "Part One", Year = 2020, SourcePath = pathA, NormalizedSourcePath = MediaPath.Normalize(pathA), Extension = ".mkv", FileSize = 4, FileModifiedAt = now, Availability = MediaAvailability.Available, CreatedAt = now, UpdatedAt = now, Metadata = new MediaMetadata { Provider = "tmdb", ProviderMediaId = "10", ReviewState = MetadataReviewState.Matched, UpdatedAt = now } };
                var movieB = new MediaItem { Id = Guid.NewGuid(), LibraryRootId = libB.Id, Kind = MediaKind.Movie, DetectedTitle = "Part Two", Year = 2022, SourcePath = pathB, NormalizedSourcePath = MediaPath.Normalize(pathB), Extension = ".mkv", FileSize = 4, FileModifiedAt = now, Availability = MediaAvailability.Available, CreatedAt = now, UpdatedAt = now, Metadata = new MediaMetadata { Provider = "tmdb", ProviderMediaId = "11", ReviewState = MetadataReviewState.Matched, UpdatedAt = now } };
                movieA.Metadata.MediaItemId = movieA.Id;
                movieB.Metadata.MediaItemId = movieB.Id;
                db.MediaItems.AddRange(movieA, movieB);
                movieAId = movieA.Id;

                var collection = new MediaCollectionRecord { Id = Guid.NewGuid(), Name = "Shared Saga", Provider = "tmdb", ProviderCollectionId = "500", IsManual = false, IsSmart = false, CreatedAt = now, UpdatedAt = now };
                db.MediaCollections.Add(collection);
                db.MediaCollectionMembers.AddRange(
                    new MediaCollectionMember { CollectionId = collection.Id, MediaItemId = movieA.Id, SortOrder = 0 },
                    new MediaCollectionMember { CollectionId = collection.Id, MediaItemId = movieB.Id, SortOrder = 1 });
                collectionId = collection.Id;
                await db.SaveChangesAsync();
            }

            // Create an admin restricted to only Movie A (Movie B in LibB is invisible to them).
            using var createAdmin = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                new CreateUserRequest("LimitedAdmin", null, UserRole.Admin, ApiTestClient.TestPin, PinProtectionEnabled: true,
                    AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: [movieAId]));
            using var adminResp = await ApiTestClient.SendAsync(client, createAdmin);
            adminResp.EnsureSuccessStatusCode();
            var adminUser = await ApiTestClient.ReadAsync<UserSummary>(adminResp);

            var sessionStore = factory.Services.GetRequiredService<ProfileSessionStore>();
            var adminToken = sessionStore.Issue(owner.SessionId, adminUser.Id).Token;

            using var clearReq = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/media/{movieAId}/metadata/match", adminToken);
            using var clearResp = await ApiTestClient.SendAsync(client, clearReq);
            clearResp.EnsureSuccessStatusCode();

            // Collection must still exist with Movie B intact!
            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var remaining = await db.MediaCollections.IgnoreQueryFilters().Include(c => c.Members)
                    .SingleOrDefaultAsync(c => c.Id == collectionId);
                Assert.NotNull(remaining);
                Assert.Single(remaining.Members);
            }
        }
        finally { Directory.Delete(mediaParent, recursive: true); }
    }
}
