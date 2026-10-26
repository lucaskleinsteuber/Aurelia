using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Xunit;

namespace Aurelia.Server.Tests;

[Collection(SqlitePoolIsolationRuns.Name)]
public sealed class SqlitePoolIsolationTests
{
    [Fact]
    public async Task ReleasingOneServerDatabaseKeepsAnotherServersPooledConnection()
    {
        var root = TestPaths.CreateDataDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(root);
        var first = Path.Combine(root, "First synthetic server.db");
        var second = Path.Combine(root, "Second synthetic server.db");
        try
        {
            var settings = new SqliteConnectionStringBuilder(SqliteConnections.ConnectionString(first));
            Assert.Equal(first, settings.DataSource);
            Assert.Equal(SqliteOpenMode.ReadWriteCreate, settings.Mode);
            Assert.Equal(SqliteCacheMode.Private, settings.Cache);
            Assert.True(settings.ForeignKeys);
            Assert.True(settings.Pooling);
            await AddMarkerAsync(first);
            await AddMarkerAsync(second);

            SqliteConnections.ClearPool(first);

            // TEMP state belongs to a physical connection, not the database file. A global clear
            // loses both markers; clearing just the first pool must leave the second one alive.
            Assert.Equal(0, await MarkerCountAsync(first));
            Assert.Equal(1, await MarkerCountAsync(second));
        }
        finally
        {
            SqliteConnections.ClearPool(first);
            SqliteConnections.ClearPool(second);
            Directory.Delete(root, recursive: true);
        }
    }

    private static async Task AddMarkerAsync(string path)
    {
        await using var connection = new SqliteConnection(SqliteConnections.ConnectionString(path));
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "CREATE TEMP TABLE pool_marker (value INTEGER);";
        await command.ExecuteNonQueryAsync();
    }

    private static async Task<long> MarkerCountAsync(string path)
    {
        await using var connection = new SqliteConnection(SqliteConnections.ConnectionString(path));
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT count(*) FROM sqlite_temp_master WHERE name='pool_marker';";
        return (long)(await command.ExecuteScalarAsync())!;
    }
}

[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class SqlitePoolIsolationRuns
{
    public const string Name = "SQLite pool isolation";
}
