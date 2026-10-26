using Microsoft.Data.Sqlite;

namespace Aurelia.Server.Data;

/// <summary>The host's pooled SQLite connections and database-scoped release before replacement.</summary>
public static class SqliteConnections
{
    public static string ConnectionString(string databasePath) => new SqliteConnectionStringBuilder
    {
        DataSource = databasePath,
        Mode = SqliteOpenMode.ReadWriteCreate,
        // Shared-cache table locks defeat WAL reader/writer concurrency, even when
        // readers use deferred transactions. Each pooled connection needs a private cache.
        Cache = SqliteCacheMode.Private,
        ForeignKeys = true,
        Pooling = true,
    }.ToString();

    /// <summary>Other server instances in this process must keep their own connections intact.</summary>
    public static void ClearPool(string databasePath)
    {
        using var connection = new SqliteConnection(ConnectionString(databasePath));
        SqliteConnection.ClearPool(connection);
    }
}
