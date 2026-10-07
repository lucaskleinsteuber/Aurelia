using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

// Recovery applies only after the database was initialized successfully. A
// corrupt/incompatible database must still stop the host, never become an empty
// catalog or an endlessly retried authentication success.
internal sealed partial class StorageRecovery(ILogger logger, string operation,
    Func<CancellationToken, Task>? delay = null)
{
    internal static bool IsRecoverableDatabase(Exception error) => error switch
    {
        SqliteException sqlite => sqlite.SqliteErrorCode is 5 or 6 or 8 or 10 or 13 or 14,
        DbUpdateException { InnerException: { } inner } => IsRecoverableDatabase(inner),
        _ => false
    };

    internal static bool IsCorruptDatabase(Exception error) => error switch
    {
        SqliteException sqlite => sqlite.SqliteErrorCode is 11 or 26,
        DbUpdateException { InnerException: { } inner } => IsCorruptDatabase(inner),
        _ => false
    };

    internal static bool IsRecoverable(Exception error) => IsRecoverableDatabase(error)
        || error is IOException or UnauthorizedAccessException;

    public async Task RunAsync(Func<Task> action, CancellationToken token) =>
        await RunAsync(async () => { await action(); return true; }, token);

    public async Task<T> RunAsync<T>(Func<Task<T>> action, CancellationToken token)
    {
        var reported = false;
        while (true)
        {
            token.ThrowIfCancellationRequested();
            try
            {
                var result = await action();
                if (reported) StorageAvailable(logger, operation);
                return result;
            }
            catch (Exception error) when (IsRecoverable(error))
            {
                if (!reported) StorageUnavailable(logger, operation, error.GetType().Name);
                reported = true;
                await (delay?.Invoke(token) ?? Task.Delay(TimeSpan.FromSeconds(5), token));
            }
        }
    }

    [LoggerMessage(LogLevel.Warning, "{Operation} is waiting for writable storage ({ErrorType}); authoritative state is retained.")]
    internal static partial void StorageUnavailable(ILogger logger, string operation, string errorType);
    [LoggerMessage(LogLevel.Information, "Storage became available again for {Operation}.")]
    private static partial void StorageAvailable(ILogger logger, string operation);
}

internal sealed class MaintenancePhaseRunner(ILogger logger)
{
    private readonly HashSet<string> failures = [];
    internal async Task RunAsync(string name, Func<Task> action, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        try { await action(); failures.Remove(name); }
        catch (Exception error) when (StorageRecovery.IsRecoverable(error))
        {
            if (failures.Add(name)) StorageRecovery.StorageUnavailable(logger, name, error.GetType().Name);
        }
    }
}
