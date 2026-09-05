using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Data;
using System.Net.Http.Json;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
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
            Assert.Equal(2L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='MediaItems';";
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
}
