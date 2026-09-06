using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Data;
using Aurelia.Home.Server.Services;
using System.Net.Http.Json;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Home.Server.Tests;

public sealed class MigrationUpgradeTests
{
    [Fact]
    public async Task BuildOneDatabaseUpgradesWithoutLosingItsIdentity()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var databasePath = Path.Combine(dataDirectory, "aurelia-home.db");
        var serverId = Guid.NewGuid();

        try
        {
            var options = new DbContextOptionsBuilder<AureliaHomeDbContext>()
                .UseSqlite($"Data Source={databasePath}")
                .Options;
            await using (var database = new AureliaHomeDbContext(options))
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

            using var factory = new AureliaHomeServerFactory(dataDirectory);
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
            Assert.Equal(3L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='MediaItems';";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='PlaybackTickets';";
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
        var databasePath = Path.Combine(dataDirectory, "aurelia-home.db");
        var libraryId = Guid.NewGuid();
        var mediaId = Guid.NewGuid();

        try
        {
            var options = new DbContextOptionsBuilder<AureliaHomeDbContext>()
                .UseSqlite($"Data Source={databasePath}")
                .Options;
            await using (var database = new AureliaHomeDbContext(options))
            {
                var migrator = database.Database.GetService<IMigrator>();
                await migrator.MigrateAsync("20260905231955_Build2MediaLibrary");
                var now = DateTimeOffset.UtcNow;
                database.ServerIdentities.Add(new ServerIdentity
                {
                    Id = 1,
                    ServerId = Guid.NewGuid(),
                    CreatedAt = now,
                });
                var library = new LibraryRoot
                {
                    Id = libraryId,
                    Name = "Existing Movies",
                    Path = "/Media/Movies",
                    NormalizedPath = MediaPath.Normalize("/Media/Movies"),
                    Kind = LibraryKind.Movies,
                    Availability = LibraryAvailability.Available,
                    CreatedAt = now,
                };
                database.MediaItems.Add(new MediaItem
                {
                    Id = mediaId,
                    LibraryRoot = library,
                    LibraryRootId = library.Id,
                    Kind = MediaKind.Movie,
                    SourcePath = "/Media/Movies/Existing.mkv",
                    NormalizedSourcePath = MediaPath.Normalize("/Media/Movies/Existing.mkv"),
                    DetectedTitle = "Existing",
                    Category = string.Empty,
                    Extension = ".mkv",
                    FileSize = 123,
                    FileModifiedAt = now,
                    Availability = MediaAvailability.Available,
                    CreatedAt = now,
                    UpdatedAt = now,
                });
                await database.SaveChangesAsync();
            }

            using var factory = new AureliaHomeServerFactory(dataDirectory);
            using var client = factory.CreateClient();
            using var response = await client.GetAsync("/api/v1/health");
            response.EnsureSuccessStatusCode();

            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
                var media = await database.MediaItems.AsNoTracking().SingleAsync();
                Assert.Equal(mediaId, media.Id);
                Assert.Equal(libraryId, media.LibraryRootId);
                Assert.Empty(await database.PlaybackTickets.ToListAsync());
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
