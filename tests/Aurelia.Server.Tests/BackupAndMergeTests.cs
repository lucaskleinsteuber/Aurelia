using System.Net;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using SkiaSharp;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class BackupAndMergeTests
{
    [Fact]
    public async Task FullBackupAndRestorePreservesWatchlistSubtitlesCollectionArtworkAndSettings()
    {
        var mediaRoot = Path.Combine(TestPaths.CreateDataDirectory(), "BackupMedia");
        Directory.CreateDirectory(mediaRoot);
        var filmPath = Path.Combine(mediaRoot, "Aurora (2024).mkv");
        await File.WriteAllBytesAsync(filmPath, [1, 2, 3, 4]);
        var restoreDir = TestPaths.CreateDataDirectory();
        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            Guid libraryId;
            using (var createLib = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries", owner.Token,
                new CreateLibraryRequest("Movies", mediaRoot, LibraryKind.Movies)))
            using (var libRes = await client.SendAsync(createLib))
            {
                libRes.EnsureSuccessStatusCode();
                libraryId = (await ApiTestClient.ReadAsync<LibrarySummary>(libRes)).Id;
            }
            await RunScanToCompletionAsync(factory, client, owner.Token, libraryId);

            Guid movieId;
            Guid collectionId;
            string collectionPosterRelative;
            string collectionOriginalRelative;
            var subtitleId = Guid.NewGuid();
            var subtitleBytes = Encoding.UTF8.GetBytes("1\n00:00:01,000 --> 00:00:03,000\nHello restored world.\n");

            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                movieId = (await db.MediaItems.AsNoTracking().SingleAsync(item => item.LibraryRootId == libraryId)).Id;

                var watchlist = scope.ServiceProvider.GetRequiredService<WatchlistService>();
                await watchlist.SetAsync(owner.User.Id, movieId, true, CancellationToken.None);

                var subtitles = scope.ServiceProvider.GetRequiredService<DownloadedSubtitleStore>();
                subtitles.Add(movieId, new StoredSubtitle(subtitleId, "en", false, false,
                    SubtitleDownloadService.SpeechProviderName, "speech-en", null, DateTimeOffset.UtcNow, false), subtitleBytes);
                subtitles.MarkChecked(movieId, "file-key-1", "en", DateTimeOffset.UtcNow);

                var security = scope.ServiceProvider.GetRequiredService<SecuritySettingsStore>();
                security.Update(new SecuritySettings(180, true));

                var subSettings = scope.ServiceProvider.GetRequiredService<SubtitleProviderSettingsStore>();
                subSettings.Save(new UpdateSubtitleProviderRequest(true, ["en", "de"], true, "AbCdEfGh1234567890", "subuser", "subpass"));

                var collection = new MediaCollectionRecord
                {
                    Id = Guid.NewGuid(),
                    Name = "Favorites Box",
                    IsManual = true,
                    UserId = owner.User.Id,
                    CreatedAt = DateTimeOffset.UtcNow,
                    UpdatedAt = DateTimeOffset.UtcNow,
                };
                db.MediaCollections.Add(collection);
                await db.SaveChangesAsync();
                collectionId = collection.Id;

                var collectionArtwork = scope.ServiceProvider.GetRequiredService<CollectionArtworkService>();
                using var png = CreatePngStream(640, 960);
                await collectionArtwork.SaveManualAsync(db, collection, owner.User.Id, owner.SessionId, ArtworkKind.Poster, png, null, null, CancellationToken.None);

                var asset = await db.CollectionArtworkAssets.AsNoTracking().SingleAsync(a => a.CollectionId == collectionId && a.IsManual);
                collectionPosterRelative = asset.RelativeFilePath;
                collectionOriginalRelative = asset.OriginalFilePath!;
            }

            const string passphrase = "correct-horse-backup-passphrase";
            string backupFile;
            using (var scope = factory.Services.CreateScope())
            {
                var backups = scope.ServiceProvider.GetRequiredService<FullServerBackupService>();
                var export = await backups.ExportAsync(passphrase, CancellationToken.None);
                Assert.True(export.IncludesArtwork);
                backupFile = backups.TransferPath(export.Id);
            }

            // Restore into a second initialized server's data directory.
            using (var targetFactory = new AureliaServerFactory())
            {
                using var targetClient = targetFactory.CreateClient();
                await ApiTestClient.SetupOwnerAsync(targetClient);
                var targetDir = targetFactory.DataDirectory;
                // Copy initialized state to restoreDir so targetFactory can be disposed cleanly before activation.
                CopyDirectory(targetDir, restoreDir);
            }
            var targetRuntime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", restoreDir]);
            var targetDbBackups = new DatabaseBackupService(targetRuntime);
            var targetConfig = new ServerConfigurationStore(targetRuntime);
            using var targetBackups = new FullServerBackupService(targetRuntime, targetDbBackups, targetConfig);
            var uploadId = Guid.NewGuid();
            await using (var fs = File.OpenRead(backupFile))
                await targetBackups.UploadAsync(uploadId, fs, fs.Length, CancellationToken.None);
            var prepared = await targetBackups.PrepareRestoreAsync(
                new BackupRestoreRequest(uploadId, passphrase, RevokeAllSessions: true, AcceptDifferentServerIdentity: true),
                CancellationToken.None);
            await FullServerBackupService.ApplyPreparedCoreAsync(targetRuntime, prepared.Id, CancellationToken.None);

            // Verify all user-created state survived restore.
            Assert.True(File.Exists(Path.Combine(restoreDir, "Watchlist", $"{owner.User.Id:N}.json")));
            var restoredSubtitles = new DownloadedSubtitleStore(targetRuntime);
            var restoredSubList = restoredSubtitles.List(movieId);
            Assert.Single(restoredSubList, s => s.Id == subtitleId);
            var restoredSrtPath = restoredSubtitles.SubtitlePath(movieId, subtitleId);
            Assert.NotNull(restoredSrtPath);
            Assert.Equal(subtitleBytes, await File.ReadAllBytesAsync(restoredSrtPath));
            Assert.NotNull(restoredSubtitles.LastChecked(movieId, "file-key-1", "en"));

            Assert.True(File.Exists(Path.Combine(restoreDir, "Artwork", "Collections", collectionPosterRelative)));
            Assert.True(File.Exists(Path.Combine(restoreDir, "Artwork", "Collections", collectionOriginalRelative)));

            var restoredSecurity = new SecuritySettingsStore(targetRuntime).Current;
            Assert.Equal(180, restoredSecurity.SecurityLogDays);
            Assert.True(restoredSecurity.RequirePasskeysForAdministrators);

            var restoredSubConfig = new SubtitleProviderSettingsStore(targetRuntime).Load();
            Assert.True(restoredSubConfig.Enabled);
            Assert.True(restoredSubConfig.Automatic);
            Assert.Equal(["en", "de"], restoredSubConfig.Languages);
            Assert.Equal("AbCdEfGh1234567890", restoredSubConfig.ApiKey);
            Assert.Equal("subuser", restoredSubConfig.AccountName);
            Assert.Equal("subpass", restoredSubConfig.AccountPassword);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(mediaRoot)!, recursive: true);
            if (Directory.Exists(restoreDir)) Directory.Delete(restoreDir, recursive: true);
        }
    }

    [Fact]
    public async Task MergeMissingDuplicatePreservesSceneNotesWatchlistGrantsRulesHiddenAndManualSegments()
    {
        var mediaRoot = Path.Combine(TestPaths.CreateDataDirectory(), "MergeMedia");
        var folderA = Path.Combine(mediaRoot, "CopyA");
        var folderB = Path.Combine(mediaRoot, "CopyB");
        Directory.CreateDirectory(folderA);
        Directory.CreateDirectory(folderB);
        await File.WriteAllBytesAsync(Path.Combine(folderA, "Horizon (2023).mkv"), [1, 2, 3, 4]);
        await File.WriteAllBytesAsync(Path.Combine(folderB, "Horizon (2023).mkv"), [5, 6, 7, 8]);
        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            Guid libA, libB;
            using (var req = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries", owner.Token, new CreateLibraryRequest("Movies A", folderA, LibraryKind.Movies)))
            using (var res = await client.SendAsync(req)) { res.EnsureSuccessStatusCode(); libA = (await ApiTestClient.ReadAsync<LibrarySummary>(res)).Id; }
            using (var req = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries", owner.Token, new CreateLibraryRequest("Movies B", folderB, LibraryKind.Movies)))
            using (var res = await client.SendAsync(req)) { res.EnsureSuccessStatusCode(); libB = (await ApiTestClient.ReadAsync<LibrarySummary>(res)).Id; }
            await RunScanToCompletionAsync(factory, client, owner.Token, libA);
            await RunScanToCompletionAsync(factory, client, owner.Token, libB);

            Guid sourceId, targetId, selectedViewerId, childViewerId;
            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var source = await db.MediaItems.SingleAsync(item => item.LibraryRootId == libA);
                var target = await db.MediaItems.SingleAsync(item => item.LibraryRootId == libB);
                sourceId = source.Id;
                targetId = target.Id;

                var selectedViewer = new ServerUser
                {
                    Id = Guid.NewGuid(),
                    Username = "selected-viewer",
                    NormalizedUsername = "SELECTED-VIEWER",
                    PasswordHash = "synthetic",
                    Role = UserRole.User,
                    AccessMode = ProfileAccessMode.SelectedTitles,
                    IsEnabled = true,
                    CreatedAt = DateTimeOffset.UtcNow,
                };
                var childViewer = new ServerUser
                {
                    Id = Guid.NewGuid(),
                    Username = "child-viewer",
                    NormalizedUsername = "CHILD-VIEWER",
                    PasswordHash = "synthetic",
                    Role = UserRole.User,
                    AccessMode = ProfileAccessMode.EntireLibrary,
                    AgeLimit = 12,
                    IsEnabled = true,
                    CreatedAt = DateTimeOffset.UtcNow,
                };
                selectedViewerId = selectedViewer.Id;
                childViewerId = childViewer.Id;
                db.Users.AddRange(selectedViewer, childViewer);

                db.UserTitleGrants.Add(new UserTitleGrant { UserId = selectedViewerId, MediaItemId = sourceId });
                db.UserTitleRules.Add(new UserTitleRule { UserId = childViewerId, MediaItemId = sourceId, Allowed = true });
                db.SceneNotes.Add(new SceneNote
                {
                    Id = Guid.NewGuid(),
                    UserId = selectedViewerId,
                    MediaItemId = sourceId,
                    StartMilliseconds = 42_000,
                    Text = "Favorite shot",
                    Revision = 1,
                });
                db.ContinueWatchingStates.Add(new ContinueWatchingState
                {
                    UserId = selectedViewerId,
                    MediaItemId = sourceId,
                    IsHidden = true,
                    Revision = 1,
                });
                db.MediaSegments.Add(new MediaSegment
                {
                    MediaItemId = sourceId,
                    IntroStartMilliseconds = 5_000,
                    IntroEndMilliseconds = 65_000,
                    IntroSource = MediaSegmentSource.Manual,
                    IntroConfidence = 1,
                    CreditsStartMilliseconds = 5_400_000,
                    CreditsSource = MediaSegmentSource.Manual,
                    CreditsConfidence = 1,
                    UpdatedAt = DateTimeOffset.UtcNow,
                });
                source.Availability = MediaAvailability.Missing;
                await db.SaveChangesAsync();

                var watchlist = scope.ServiceProvider.GetRequiredService<WatchlistService>();
                await watchlist.SetAsync(owner.User.Id, sourceId, true, CancellationToken.None);
            }

            using (var mergeReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/library/health/merge", owner.Token,
                new MergeMediaRequest(sourceId, targetId)))
            using (var mergeRes = await client.SendAsync(mergeReq))
            {
                Assert.Equal(HttpStatusCode.NoContent, mergeRes.StatusCode);
            }

            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                Assert.False(await db.MediaItems.AnyAsync(item => item.Id == sourceId));

                Assert.True(await db.UserTitleGrants.IgnoreQueryFilters().AnyAsync(g => g.UserId == selectedViewerId && g.MediaItemId == targetId));
                Assert.True(await db.UserTitleRules.IgnoreQueryFilters().AnyAsync(r => r.UserId == childViewerId && r.MediaItemId == targetId && r.Allowed));
                var note = await db.SceneNotes.IgnoreQueryFilters().SingleOrDefaultAsync(n => n.UserId == selectedViewerId && n.MediaItemId == targetId);
                Assert.NotNull(note);
                Assert.Equal("Favorite shot", note.Text);
                Assert.True(await db.ContinueWatchingStates.IgnoreQueryFilters().AnyAsync(c => c.UserId == selectedViewerId && c.MediaItemId == targetId && c.IsHidden));
                var segment = await db.MediaSegments.IgnoreQueryFilters().SingleOrDefaultAsync(s => s.MediaItemId == targetId);
                Assert.NotNull(segment);
                Assert.Equal(MediaSegmentSource.Manual, segment.IntroSource);
                Assert.Equal(5_000, segment.IntroStartMilliseconds);
                Assert.Equal(MediaSegmentSource.Manual, segment.CreditsSource);
                Assert.Equal(5_400_000, segment.CreditsStartMilliseconds);

                var watchlist = scope.ServiceProvider.GetRequiredService<WatchlistService>();
                var ownerWatchlist = await watchlist.MediaIdsAsync(owner.User.Id, CancellationToken.None);
                Assert.Contains(targetId, ownerWatchlist);
            }
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(mediaRoot)!, recursive: true);
        }
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.EnumerateFiles(source))
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)), overwrite: true);
        foreach (var dir in Directory.EnumerateDirectories(source))
            CopyDirectory(dir, Path.Combine(destination, Path.GetFileName(dir)));
    }

    private static MemoryStream CreatePngStream(int width, int height)
    {
        using var bitmap = new SKBitmap(width, height);
        using var canvas = new SKCanvas(bitmap);
        canvas.Clear(SKColors.SteelBlue);
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        var stream = new MemoryStream();
        data.SaveTo(stream);
        stream.Position = 0;
        return stream;
    }

    private static async Task RunScanToCompletionAsync(AureliaServerFactory factory, HttpClient client, string token, Guid libraryId)
    {
        Guid scanId;
        using (var startReq = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/libraries/{libraryId}/scans", token))
        using (var startRes = await client.SendAsync(startReq))
        {
            startRes.EnsureSuccessStatusCode();
            scanId = (await ApiTestClient.ReadAsync<LibraryScanSummary>(startRes)).Id;
        }
        var deadline = DateTimeOffset.UtcNow.AddSeconds(15);
        while (DateTimeOffset.UtcNow < deadline)
        {
            using var scope = factory.Services.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var state = await db.LibraryScans.AsNoTracking().Where(s => s.Id == scanId).Select(s => s.State).SingleAsync();
            if (state == LibraryScanState.Completed) return;
            Assert.NotEqual(LibraryScanState.Failed, state);
            await Task.Delay(50);
        }
        throw new TimeoutException("Library scan did not complete in time.");
    }
}
