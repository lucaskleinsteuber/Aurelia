using System.Data.Common;
using System.Runtime.CompilerServices;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace Aurelia.Server.Services;

/// <summary>
/// In WAL mode, NORMAL synchronisation keeps the database consistent after a crash or
/// power loss and avoids a disk flush on every commit. Only the last moments of
/// changes (for example a few seconds of playback progress) can be lost on power loss.
/// Connections that are not (yet) in WAL mode keep SQLite's default FULL mode.
/// </summary>
public sealed class SqliteWriteMode : DbConnectionInterceptor
{
    private const string Query = "SELECT CASE WHEN journal_mode = 'wal' THEN 1 ELSE 0 END FROM pragma_journal_mode;";
    private static readonly object Marker = new();
    private readonly ConditionalWeakTable<SQLitePCL.sqlite3, object> configuredHandles = new();
    private int pragmaExecutions;

    public static SqliteWriteMode Interceptor { get; } = new();

    internal int PragmaExecutions => Volatile.Read(ref pragmaExecutions);

    public override void ConnectionOpened(DbConnection connection, ConnectionEndEventData eventData)
    {
        var handle = NativeHandle(connection);
        if (handle is not null && configuredHandles.TryGetValue(handle, out _)) return;
        using var command = connection.CreateCommand();
        command.CommandText = Query;
        if (Convert.ToInt64(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) != 1) return;
        command.CommandText = "PRAGMA synchronous=NORMAL;";
        command.ExecuteNonQuery();
        Interlocked.Increment(ref pragmaExecutions);
        if (handle is not null) configuredHandles.AddOrUpdate(handle, Marker);
    }

    public override async Task ConnectionOpenedAsync(DbConnection connection, ConnectionEndEventData eventData,
        CancellationToken cancellationToken = default)
    {
        var handle = NativeHandle(connection);
        if (handle is not null && configuredHandles.TryGetValue(handle, out _)) return;
        await using var command = connection.CreateCommand();
        command.CommandText = Query;
        if (Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken), System.Globalization.CultureInfo.InvariantCulture) != 1) return;
        command.CommandText = "PRAGMA synchronous=NORMAL;";
        await command.ExecuteNonQueryAsync(cancellationToken);
        Interlocked.Increment(ref pragmaExecutions);
        if (handle is not null) configuredHandles.AddOrUpdate(handle, Marker);
    }

    private static SQLitePCL.sqlite3? NativeHandle(DbConnection connection) =>
        connection is SqliteConnection sqlite ? sqlite.Handle : null;
}
