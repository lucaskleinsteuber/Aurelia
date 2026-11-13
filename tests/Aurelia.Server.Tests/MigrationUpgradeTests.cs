using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using System.Net.Http.Json;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class MigrationUpgradeTests
{
    private static long CurrentMigrationCount(AureliaServerFactory factory)
    {
        using var scope = factory.Services.CreateScope();
        return scope.ServiceProvider.GetRequiredService<AureliaDbContext>().Database.GetMigrations().LongCount();
    }

    [Fact]
    public async Task DeviceAuthorizationUpgradePreservesPairedDevicesAndInitializesExistingArtworkRevision()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var options = new DbContextOptionsBuilder<AureliaDbContext>()
            .UseSqlite($"Data Source={Path.Combine(root, "aurelia.db")};Pooling=False").Options;
        try
        {
            await using var database = new AureliaDbContext(options);
            await database.Database.GetService<IMigrator>().MigrateAsync("20261015134947_DurableMetadataWorklists");
            var now = DateTimeOffset.UtcNow;
            var owner = new ServerUser
            {
                Id = Guid.NewGuid(),
                Username = "Owner",
                NormalizedUsername = "OWNER",
                PasswordHash = "synthetic-password-hash",
                Role = UserRole.Owner,
            };
            var device = new DeviceSession
            {
                Id = Guid.NewGuid(),
                User = owner,
                UserId = owner.Id,
                DeviceName = "Existing Mac",
                TokenHash = "synthetic-existing-device-hash",
                CreatedAt = now,
                LastSeenAt = now,
                ExpiresAt = now.AddDays(30),
            };
            var legacyPairing = new PairingCode
            {
                Id = Guid.NewGuid(),
                User = owner,
                UserId = owner.Id,
                CodeHash = "synthetic-legacy-code-hash",
                CreatedAt = now,
                ExpiresAt = now.AddMinutes(5),
            };
            var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", NormalizedPath = "synthetic" };
            var media = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRoot = library,
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                DetectedTitle = "Existing Film",
                NormalizedSourcePath = "EXISTING-FILM",
            };
            media.Metadata = new MediaMetadata { MediaItemId = media.Id, ManualTitle = "Existing Manual Title" };
            await SeedLegacyUserAsync(database, owner);
            await SeedLegacyDeviceAsync(database, device);
            database.AddRange(legacyPairing, library, media);
            await database.SaveChangesAsync();
            var artworkId = Guid.NewGuid();
            await database.Database.ExecuteSqlInterpolatedAsync($"""
                INSERT INTO ArtworkAssets (Id,MediaItemId,Kind,ProviderPath,RelativeFilePath,ContentType,ContentLength,CreatedAt,IsManual)
                VALUES ({artworkId},{media.Id},'Poster','manual-existing','Artwork/manual-existing.png','image/png',12,{now.ToUnixTimeMilliseconds()},1);
                """);
            await database.Database.MigrateAsync();
            Assert.Empty(await database.DeviceAuthorizationRequests.ToListAsync());
            var retainedDevice = await database.DeviceSessions.AsNoTracking().SingleAsync();
            Assert.Equal(device.Id, retainedDevice.Id);
            Assert.Equal(device.TokenHash, retainedDevice.TokenHash);
            Assert.Null(retainedDevice.RevokedAt);
            Assert.NotNull(retainedDevice.AcknowledgedAt);
            Assert.Null((await database.PairingCodes.AsNoTracking().SingleAsync()).ConsumedAt);
            Assert.Equal("Existing Manual Title", (await database.MediaMetadata.AsNoTracking().SingleAsync()).ManualTitle);
            var artwork = await database.ArtworkAssets.AsNoTracking().SingleAsync();
            Assert.Equal(artworkId, artwork.Id);
            Assert.Equal(1, artwork.Revision);
            Assert.True(artwork.IsManual);
            Assert.Equal("Artwork/manual-existing.png", artwork.RelativeFilePath);
            Assert.Equal(database.Database.GetMigrations().Count(), (await database.Database.GetAppliedMigrationsAsync()).Count());
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task MetadataWorklistUpgradeRetainsHistoryAndInterruptsLegacyOpenJobs()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={Path.Combine(root, "aurelia.db")};Pooling=False").Options;
        try
        {
            await using var database = new AureliaDbContext(options);
            await database.Database.GetService<IMigrator>().MigrateAsync("20261014163033_LibraryState");
            var owner = new ServerUser { Id = Guid.NewGuid(), Username = "Owner", NormalizedUsername = "OWNER", PasswordHash = "synthetic", Role = UserRole.Owner };
            var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", NormalizedPath = "synthetic" };
            var series = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Series, DetectedTitle = "Old Series", LibraryRootId = library.Id, LibraryRoot = library, NormalizedSourcePath = "SERIES" };
            series.Metadata = new MediaMetadata { MediaItemId = series.Id, ManualTitle = "Renamed Galaxy" };
            var episode = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Episode, DetectedTitle = "Pilot", SeasonNumber = 1, EpisodeNumber = 1, Parent = series, LibraryRootId = library.Id, LibraryRoot = library, NormalizedSourcePath = "EPISODE" };
            await SeedLegacyUserAsync(database, owner);
            database.AddRange(library, series, episode);
            await database.SaveChangesAsync();
            await database.Database.ExecuteSqlRawAsync("DELETE FROM MediaSearchIndex; INSERT INTO MediaSearchIndex(MediaId,Title,OriginalTitle,Details) SELECT lower(replace(Id,'-','')),DetectedTitle,'','' FROM MediaItems;");
            var completed = Guid.NewGuid();
            var running = Guid.NewGuid();
            await database.Database.ExecuteSqlInterpolatedAsync($"""
                INSERT INTO MetadataJobs (Id,State,Mode,Attempt,ItemsTotal,ItemsProcessed,ItemsMatched,ItemsNeedingReview,ItemsFailed,CreatedAt)
                VALUES ({completed},'Completed','FullRefresh',1,10,10,8,1,1,0),
                       ({running},'Running','Incremental',2,20,7,6,1,0,0);
                """);
            await database.Database.MigrateAsync();
            var history = await database.MetadataJobs.SingleAsync(value => value.Id == completed);
            Assert.Equal(MetadataJobState.Completed, history.State);
            Assert.Equal(10, history.ItemsProcessed);
            Assert.Equal(8, history.ItemsMatched);
            var interrupted = await database.MetadataJobs.SingleAsync(value => value.Id == running);
            Assert.Equal(MetadataJobState.Interrupted, interrupted.State);
            Assert.Equal(20, interrupted.ItemsTotal);
            Assert.Equal(7, interrupted.ItemsProcessed);
            Assert.False(interrupted.WorklistInitialized);
            Assert.Contains("Retry", interrupted.Error!, StringComparison.Ordinal);
            Assert.Empty(await database.MetadataJobItems.ToListAsync());
            var search = new PresentationService(database, TimeProvider.System, new MediaSearchIndexService(database));
            var rebuilt = await search.SearchAsync(owner.Id, "Renamed Galaxy", new CatalogQuery(), default);
            Assert.Equal(2, rebuilt.Total);
            Assert.Contains(rebuilt.Items, item => item.Id == episode.Id);
            Assert.Contains(rebuilt.Items, item => item.Id == series.Id);
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    [Fact]
    public async Task MediaSegmentTimesUpgradeAddsAnEmptyTableAndKeepsExistingData()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var options = new DbContextOptionsBuilder<AureliaDbContext>()
            .UseSqlite($"Data Source={Path.Combine(root, "aurelia.db")};Pooling=False").Options;
        try
        {
            await using var database = new AureliaDbContext(options);
            await database.Database.GetService<IMigrator>().MigrateAsync("20261107173836_ProfilePersonalizationAndAgeLimits");
            var userId = Guid.NewGuid();
            await database.Database.ExecuteSqlInterpolatedAsync($"""
                INSERT INTO Users (Id, Username, NormalizedUsername, PasswordHash, Role, CreatedAt, IsEnabled, AccessMode, AccessRevision, PinProtectionEnabled, ProfileRevision)
                VALUES ({userId}, 'Kept', 'KEPT', 'unchanged-password-hash', 'User', 1, 1, 'EntireLibrary', 3, 0, 0);
                """);
            // The table of the first attempt (1.7.0 to 1.7.8) was dropped in 1.7.9 and must not exist here.
            Assert.Equal(0L, await ScalarAsync(database, "SELECT count(*) FROM sqlite_master WHERE name = 'MediaSegments'"));

            await database.Database.MigrateAsync();

            Assert.Equal(0, await database.MediaSegments.CountAsync());
            Assert.Equal(1L, await ScalarAsync(database,
                "SELECT count(*) FROM pragma_foreign_key_list('MediaSegments') WHERE \"table\" = 'MediaItems' AND on_delete = 'CASCADE'"));
            var user = await database.Users.AsNoTracking().SingleAsync(candidate => candidate.Id == userId);
            Assert.Equal(("unchanged-password-hash", 3), (user.PasswordHash, user.AccessRevision));
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    private static async Task<long> ScalarAsync(AureliaDbContext database, string sql)
    {
        var connection = database.Database.GetDbConnection();
        if (connection.State != System.Data.ConnectionState.Open) await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        return (long)(await command.ExecuteScalarAsync())!;
    }

    [Fact]
    public async Task OptionalPinMigrationPreservesProtectedAndPendingProfilesWithoutChangingCredentials()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var options = new DbContextOptionsBuilder<AureliaDbContext>()
            .UseSqlite($"Data Source={Path.Combine(root, "aurelia.db")};Pooling=False").Options;
        try
        {
            await using var database = new AureliaDbContext(options);
            await database.Database.GetService<IMigrator>().MigrateAsync("20261013052618_ProfilesAndSceneNotes");
            var protectedId = Guid.NewGuid();
            var pendingId = Guid.NewGuid();
            await database.Database.ExecuteSqlInterpolatedAsync($"""
                INSERT INTO Users (Id, Username, NormalizedUsername, PasswordHash, Role, CreatedAt, IsEnabled, AccessMode, AccessRevision, PinHash)
                VALUES ({protectedId}, 'Protected', 'PROTECTED', 'unchanged-password-hash', 'User', 1, 1, 'LegacyLibraries', 7, 'unchanged-pin-hash');
                """);
            await database.Database.ExecuteSqlInterpolatedAsync($"""
                INSERT INTO Users (Id, Username, NormalizedUsername, PasswordHash, Role, CreatedAt, IsEnabled, AccessMode, AccessRevision, PinHash)
                VALUES ({pendingId}, 'Pending', 'PENDING', 'pending-password-hash', 'User', 1, 1, 'SelectedTitles', 9, NULL);
                """);
            await database.Database.MigrateAsync();
            var users = await database.Users.AsNoTracking().ToDictionaryAsync(user => user.Id);
            Assert.True(users[protectedId].PinProtectionEnabled);
            Assert.Equal("unchanged-pin-hash", users[protectedId].PinHash);
            Assert.Equal("unchanged-password-hash", users[protectedId].PasswordHash);
            Assert.Equal(7, users[protectedId].AccessRevision);
            Assert.Equal(ProfileAccessMode.LegacyLibraries, users[protectedId].AccessMode);
            Assert.True(users[pendingId].PinProtectionEnabled);
            Assert.Null(users[pendingId].PinHash);
            Assert.True(ProfileService.ToSummary(users[pendingId]).NeedsPinSetup);
            Assert.Equal("pending-password-hash", users[pendingId].PasswordHash);
            Assert.Equal(9, users[pendingId].AccessRevision);
            Assert.Equal(0, users[pendingId].ProfileRevision);
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    [Fact]
    public async Task ProgressProtocolUpgradePreservesExistingPositionsAndInstallsRevision()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var options = new DbContextOptionsBuilder<AureliaDbContext>()
            .UseSqlite($"Data Source={Path.Combine(root, "aurelia.db")};Pooling=False").Options;
        try
        {
            await using var database = new AureliaDbContext(options);
            await database.Database.MigrateAsync();
            var now = DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            var user = new ServerUser { Id = Guid.NewGuid(), Username = "synthetic", NormalizedUsername = "SYNTHETIC", PasswordHash = "synthetic", Role = UserRole.User, CreatedAt = now };
            var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", Path = root, NormalizedPath = MediaPath.Normalize(root), Kind = LibraryKind.Movies, CreatedAt = now };
            var media = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRoot = library,
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = Path.Combine(root, "Offline.mkv"),
                NormalizedSourcePath = MediaPath.Normalize(Path.Combine(root, "Offline.mkv")),
                DetectedTitle = "Synthetic",
                Category = "",
                CreatedAt = now,
                UpdatedAt = now
            };
            database.PlaybackProgress.Add(new PlaybackProgress
            {
                Id = Guid.NewGuid(),
                User = user,
                UserId = user.Id,
                MediaItem = media,
                MediaItemId = media.Id,
                PositionMilliseconds = 45_000,
                DurationMilliseconds = 300_000,
                LastPlayedAt = now,
                UpdatedAt = now,
                Revision = 7,
                LastMutationId = Guid.NewGuid(),
                LastMutationFingerprint = "synthetic"
            });
            await database.SaveChangesAsync();
            await database.Database.GetService<IMigrator>().MigrateAsync("20261004150000_DurableSyncHistory");
            database.ChangeTracker.Clear();
            await database.Database.MigrateAsync();
            var progress = await database.PlaybackProgress.SingleAsync();
            Assert.Equal(45_000, progress.PositionMilliseconds);
            Assert.Equal(300_000, progress.DurationMilliseconds);
            Assert.Equal(now, progress.LastPlayedAt);
            Assert.Equal(now, progress.UpdatedAt);
            Assert.Equal(user.Id, progress.UserId);
            Assert.Equal(media.Id, progress.MediaItemId);
            Assert.Equal(1, progress.Revision);
            Assert.Null(progress.LastMutationId);
            Assert.Null(progress.LastMutationFingerprint);
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    [Fact]
    public async Task AccessMigrationGrantsExistingLibrariesOnceWithoutSharingNewLibraries()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={Path.Combine(root, "aurelia.db")};Pooling=False").Options;
        try
        {
            await using var database = new AureliaDbContext(options);
            await database.Database.MigrateAsync();
            var user = new ServerUser { Id = Guid.NewGuid(), Username = "existing viewer", NormalizedUsername = "EXISTING VIEWER", PasswordHash = "synthetic", Role = UserRole.User, CreatedAt = DateTimeOffset.UtcNow };
            var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Existing", Path = Path.Combine(root, "existing"), NormalizedPath = Path.Combine(root, "existing"), Kind = LibraryKind.Movies, CreatedAt = DateTimeOffset.UtcNow };
            database.Users.Add(user); database.LibraryRoots.Add(library);
            await database.SaveChangesAsync();
            var migrations = (await database.Database.GetAppliedMigrationsAsync()).ToArray();
            await database.Database.GetService<IMigrator>().MigrateAsync(migrations.TakeWhile(migration => !migration.EndsWith("_ServerAccessFoundation", StringComparison.Ordinal)).Last());
            database.ChangeTracker.Clear();
            await database.Database.MigrateAsync();
            var grant = await database.UserLibraryGrants.SingleAsync();
            Assert.Equal(user.Id, grant.UserId); Assert.Equal(library.Id, grant.LibraryRootId);
            database.LibraryRoots.Add(new LibraryRoot { Id = Guid.NewGuid(), Name = "New private library", Path = Path.Combine(root, "new"), NormalizedPath = Path.Combine(root, "new"), Kind = LibraryKind.Movies, CreatedAt = DateTimeOffset.UtcNow });
            await database.SaveChangesAsync();
            await database.Database.MigrateAsync();
            Assert.Single(await database.UserLibraryGrants.ToListAsync());
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    [Fact]
    public async Task UnknownMigrationHistoryStopsStartupWithoutReplacingOrBackingUpDatabase()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var databasePath = Path.Combine(dataDirectory, "aurelia.db");

        try
        {
            var options = new DbContextOptionsBuilder<AureliaDbContext>()
                .UseSqlite($"Data Source={databasePath}")
                .Options;
            await using (var database = new AureliaDbContext(options))
            {
                await database.Database.MigrateAsync();
                await database.Database.ExecuteSqlRawAsync("""
                    INSERT INTO "__EFMigrationsHistory" ("MigrationId", "ProductVersion")
                    VALUES ('20991231000000_FutureSchema', '10.0.0');
                    """);
            }

            Exception? startupError = null;
            using (var factory = new AureliaServerFactory(dataDirectory))
            {
                try
                {
                    using var client = factory.CreateClient();
                    using var response = await client.GetAsync("/api/v1/health");
                }
                catch (Exception exception)
                {
                    startupError = exception;
                }
            }

            Assert.NotNull(startupError);
            Assert.Contains("verification failed", startupError.ToString(), StringComparison.OrdinalIgnoreCase);
            Assert.False(Directory.Exists(Path.Combine(dataDirectory, "Backups")));

            await using var verifyDatabase = new AureliaDbContext(options);
            Assert.Contains(
                await verifyDatabase.Database.GetAppliedMigrationsAsync(),
                migration => migration == "20991231000000_FutureSchema");
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task OrphanedMigrationLockIsRecoveredWithoutChangingServerData()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var databasePath = Path.Combine(dataDirectory, "aurelia.db");
        var serverId = Guid.NewGuid();

        try
        {
            var options = new DbContextOptionsBuilder<AureliaDbContext>()
                .UseSqlite($"Data Source={databasePath}")
                .Options;
            await using (var database = new AureliaDbContext(options))
            {
                await database.Database.MigrateAsync();
                database.ServerIdentities.Add(new ServerIdentity
                {
                    Id = 1,
                    ServerId = serverId,
                    CreatedAt = DateTimeOffset.UtcNow,
                });
                await database.SaveChangesAsync();
                await database.Database.ExecuteSqlRawAsync("""
                    CREATE TABLE IF NOT EXISTS "__EFMigrationsLock" (
                        "Id" INTEGER NOT NULL CONSTRAINT "PK___EFMigrationsLock" PRIMARY KEY,
                        "Timestamp" TEXT NOT NULL
                    );
                    INSERT OR REPLACE INTO "__EFMigrationsLock" ("Id", "Timestamp")
                    VALUES (1, 'interrupted-migration');
                    """);
            }

            using var factory = new AureliaServerFactory(dataDirectory);
            using var client = factory.CreateClient();
            var info = await client.GetFromJsonAsync<ServerInfoResponse>(
                "/api/v1/server/info",
                ApiTestClient.JsonOptions);

            Assert.NotNull(info);
            Assert.Equal(serverId, info.ServerId);
            await using var connection = new SqliteConnection(
                $"Data Source={databasePath};Mode=ReadOnly");
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT COUNT(*) FROM __EFMigrationsHistory;";
            Assert.Equal(CurrentMigrationCount(factory), await command.ExecuteScalarAsync());
            command.CommandText =
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='__EFMigrationsLock';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM __EFMigrationsLock;";
            Assert.Equal(0L, await command.ExecuteScalarAsync());
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task BuildTwelveDatabaseUpgradesWithReliableLibrarySchema()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var databasePath = Path.Combine(dataDirectory, "aurelia.db");

        try
        {
            var options = new DbContextOptionsBuilder<AureliaDbContext>()
                .UseSqlite($"Data Source={databasePath}")
                .Options;
            await using (var database = new AureliaDbContext(options))
            {
                var migrator = database.Database.GetService<IMigrator>();
                await migrator.MigrateAsync("20260909114305_Build9MetadataPresentation");
            }

            using var factory = new AureliaServerFactory(dataDirectory);
            using var client = factory.CreateClient();
            using var response = await client.GetAsync("/api/v1/health");
            response.EnsureSuccessStatusCode();

            var preMigrationBackup = Assert.Single(Directory.EnumerateFiles(
                Path.Combine(dataDirectory, "Backups"),
                "aurelia-database-pre-migration-*.db"));
            var backupVerification = await factory.Services
                .GetRequiredService<DatabaseBackupService>()
                .VerifyAsync(preMigrationBackup, CancellationToken.None);
            Assert.True(backupVerification.IsValid, backupVerification.Message);
            Assert.True(backupVerification.AppliedMigrationCount < 8);

            await using var connection = new SqliteConnection(
                $"Data Source={databasePath};Mode=ReadOnly");
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT COUNT(*) FROM __EFMigrationsHistory;";
            Assert.Equal(CurrentMigrationCount(factory), await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='SyncChanges';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='MediaSearchIndex';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM pragma_table_info('LibraryScans') WHERE name='LeaseExpiresAt';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task BuildFourDatabaseUpgradesWithPlaybackProgressTable()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var databasePath = Path.Combine(dataDirectory, "aurelia.db");

        try
        {
            var options = new DbContextOptionsBuilder<AureliaDbContext>()
                .UseSqlite($"Data Source={databasePath}")
                .Options;
            await using (var database = new AureliaDbContext(options))
            {
                var migrator = database.Database.GetService<IMigrator>();
                await migrator.MigrateAsync("20260905235120_Build3PlaybackStreaming");
            }

            using var factory = new AureliaServerFactory(dataDirectory);
            using var client = factory.CreateClient();
            using var response = await client.GetAsync("/api/v1/health");
            response.EnsureSuccessStatusCode();

            await using var connection = new SqliteConnection(
                $"Data Source={databasePath};Mode=ReadOnly");
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT COUNT(*) FROM __EFMigrationsHistory;";
            Assert.Equal(CurrentMigrationCount(factory), await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='PlaybackProgress';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='MediaMetadata';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='LibraryDiscoveries';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task BuildOneDatabaseUpgradesWithoutLosingItsIdentity()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var databasePath = Path.Combine(dataDirectory, "aurelia.db");
        var serverId = Guid.NewGuid();

        try
        {
            var options = new DbContextOptionsBuilder<AureliaDbContext>()
                .UseSqlite($"Data Source={databasePath}")
                .Options;
            await using (var database = new AureliaDbContext(options))
            {
                var migrator = database.Database.GetService<IMigrator>();
                await migrator.MigrateAsync("20260905190111_InitialFoundation");
                database.ServerIdentities.Add(new ServerIdentity
                {
                    Id = 1,
                    ServerId = serverId,
                    CreatedAt = DateTimeOffset.UtcNow,
                });
                await database.SaveChangesAsync();
            }

            using var factory = new AureliaServerFactory(dataDirectory);
            using var client = factory.CreateClient();
            var info = await client.GetFromJsonAsync<ServerInfoResponse>(
                "/api/v1/server/info",
                ApiTestClient.JsonOptions);
            Assert.NotNull(info);
            Assert.Equal(serverId, info.ServerId);

            await using var connection = new SqliteConnection(
                $"Data Source={databasePath};Mode=ReadOnly");
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT COUNT(*) FROM __EFMigrationsHistory;";
            Assert.Equal(CurrentMigrationCount(factory), await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='MediaItems';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='MetadataJobs';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='LibraryDiscoveries';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='PlaybackTickets';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='PlaybackProgress';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task BuildTwoDatabaseUpgradesWithoutLosingMedia()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var databasePath = Path.Combine(dataDirectory, "aurelia.db");
        var libraryId = Guid.NewGuid();
        var mediaId = Guid.NewGuid();

        try
        {
            var options = new DbContextOptionsBuilder<AureliaDbContext>()
                .UseSqlite($"Data Source={databasePath}")
                .Options;
            await using (var database = new AureliaDbContext(options))
            {
                var migrator = database.Database.GetService<IMigrator>();
                await migrator.MigrateAsync("20260905231955_Build2MediaLibrary");
                var now = DateTimeOffset.UtcNow;
                var timestamp = now.ToUnixTimeMilliseconds();
                var originalServerId = Guid.NewGuid();
                await database.Database.ExecuteSqlInterpolatedAsync($"""
                    INSERT INTO ServerIdentities (Id, ServerId, CreatedAt)
                    VALUES (1, {originalServerId}, {timestamp});
                    """);
                await database.Database.ExecuteSqlInterpolatedAsync($"""
                    INSERT INTO LibraryRoots
                        (Id, Name, Path, NormalizedPath, Kind, Availability, CreatedAt)
                    VALUES
                        ({libraryId}, {"Existing Movies"}, {"/Media/Movies"},
                         {MediaPath.Normalize("/Media/Movies")}, {"Movies"}, {"Available"}, {timestamp});
                    """);
                await database.Database.ExecuteSqlInterpolatedAsync($"""
                    INSERT INTO MediaItems
                        (Id, LibraryRootId, Kind, SourcePath, NormalizedSourcePath,
                         DetectedTitle, Category, Extension, FileSize, FileModifiedAt,
                         Availability, CreatedAt, UpdatedAt)
                    VALUES
                        ({mediaId}, {libraryId}, {"Movie"}, {"/Media/Movies/Existing.mkv"},
                         {MediaPath.Normalize("/Media/Movies/Existing.mkv")}, {"Existing"},
                         {string.Empty}, {".mkv"}, {123L}, {timestamp}, {"Available"},
                         {timestamp}, {timestamp});
                    """);
            }

            using var factory = new AureliaServerFactory(dataDirectory);
            using var client = factory.CreateClient();
            using var response = await client.GetAsync("/api/v1/health");
            response.EnsureSuccessStatusCode();

            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var media = await database.MediaItems.AsNoTracking().SingleAsync();
                Assert.Equal(mediaId, media.Id);
                Assert.Equal(libraryId, media.LibraryRootId);
                Assert.Empty(await database.PlaybackTickets.ToListAsync());
                Assert.Empty(await database.PlaybackProgress.ToListAsync());
            }
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    /// <summary>
    /// Writes a profile with only the columns an older schema has. The current model has newer columns
    /// (display name, picture, age limit), so EF cannot insert it before the upgrade runs.
    /// </summary>
    private static async Task SeedLegacyDeviceAsync(AureliaDbContext database, DeviceSession device)
    {
        await database.Database.ExecuteSqlInterpolatedAsync($"""
            INSERT INTO DeviceSessions (Id, UserId, DeviceName, TokenHash, CreatedAt, LastSeenAt, ExpiresAt, RevokedAt)
            VALUES ({device.Id}, {device.UserId}, {device.DeviceName}, {device.TokenHash}, {device.CreatedAt.ToUnixTimeMilliseconds()},
                {device.LastSeenAt.ToUnixTimeMilliseconds()}, {device.ExpiresAt.ToUnixTimeMilliseconds()}, NULL);
            """);
    }

    private static async Task SeedLegacyUserAsync(AureliaDbContext database, ServerUser user)
    {
        var created = user.CreatedAt.ToUnixTimeMilliseconds();
        var role = user.Role.ToString();
        var mode = user.AccessMode.ToString();
        await database.Database.ExecuteSqlInterpolatedAsync($"""
            INSERT INTO Users (Id, Username, NormalizedUsername, PasswordHash, Role, CreatedAt, IsEnabled, AccessMode, AccessRevision, PinHash, PinProtectionEnabled, ProfileRevision)
            VALUES ({user.Id}, {user.Username}, {user.NormalizedUsername}, {user.PasswordHash}, {role}, {created}, 1, {mode}, 0, NULL, 1, 1);
            """);
        database.Attach(user);
    }
}
