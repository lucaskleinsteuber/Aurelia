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
            Assert.Equal(8L, await command.ExecuteScalarAsync());
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

            await using var connection = new SqliteConnection(
                $"Data Source={databasePath};Mode=ReadOnly");
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT COUNT(*) FROM __EFMigrationsHistory;";
            Assert.Equal(8L, await command.ExecuteScalarAsync());
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
            Assert.Equal(8L, await command.ExecuteScalarAsync());
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
            Assert.Equal(8L, await command.ExecuteScalarAsync());
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
}
