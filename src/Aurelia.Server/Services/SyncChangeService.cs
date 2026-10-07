using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
using System.Text;

namespace Aurelia.Server.Services;

public sealed class SyncChangeService(AureliaDbContext database, DatabaseChangeSignal signal)
{
    private const int MaximumChangedMediaIds = 200;

    public async Task<SyncChangesResponse> ChangesAsync(
        Guid userId,
        bool isAdministrator,
        long after,
        int waitSeconds,
        CancellationToken cancellationToken)
        => await ChangesAsync(userId, isAdministrator, after, waitSeconds, null, cancellationToken);

    public async Task<SyncChangesResponse> ChangesAsync(
        Guid userId, bool isAdministrator, long after, int waitSeconds, string? generation,
        CancellationToken cancellationToken)
    {
        if (after < 0 || waitSeconds is < 0 or > 30)
        {
            throw new MetadataException(
                "invalid_sync_cursor",
                "The sync cursor must be zero or greater and waitSeconds must be between 0 and 30.",
                StatusCodes.Status400BadRequest);
        }

        var deadline = DateTimeOffset.UtcNow.AddSeconds(waitSeconds);
        while (true)
        {
            var wake = signal.Snapshot();
            var response = await ReadAsync(userId, isAdministrator, after, generation, cancellationToken);
            if (response.ResetRequired || response.Cursor > after || DateTimeOffset.UtcNow >= deadline)
            {
                return response;
            }

            var remaining = deadline - DateTimeOffset.UtcNow;
            if (remaining <= TimeSpan.Zero) return response;
            try { await wake.WaitAsync(remaining < TimeSpan.FromSeconds(5) ? remaining : TimeSpan.FromSeconds(5), cancellationToken); }
            catch (TimeoutException) { /* Low-frequency reconciliation if an external writer changed SQLite. */ }
        }
    }

    public async Task<long> CurrentCursorAsync(
        Guid userId,
        bool isAdministrator,
        CancellationToken cancellationToken) =>
        (await HistoryAsync(cancellationToken)).HighWater;

    public async Task PruneAsync(CancellationToken cancellationToken)
    {
        await using var transaction = await database.Database.BeginTransactionAsync(cancellationToken);
        var cutoff = DateTimeOffset.UtcNow.AddDays(-7);
        var newestRetainedCursor = await database.SyncChanges.IgnoreQueryFilters()
            .AsNoTracking()
            .OrderByDescending(change => change.Cursor)
            .Skip(9_999)
            .Select(change => (long?)change.Cursor)
            .FirstOrDefaultAsync(cancellationToken);
        var expired = database.SyncChanges.IgnoreQueryFilters()
            .Where(change => change.CreatedAt < cutoff
                || (newestRetainedCursor.HasValue && change.Cursor < newestRetainedCursor.Value));
        var floor = await expired.MaxAsync(change => (long?)change.Cursor, cancellationToken) ?? 0;
        await database.Database.ExecuteSqlInterpolatedAsync(
            $"UPDATE \"SyncHistoryState\" SET \"RetainedFloor\" = max(\"RetainedFloor\", {floor}) WHERE \"Id\" = 1", cancellationToken);
        await expired.ExecuteDeleteAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
    }

    public sealed record HistoryState(string Generation, long RetainedFloor, long HighWater);

    public Task<HistoryState> HistoryAsync(CancellationToken token) => database.Database
        .SqlQueryRaw<HistoryState>("SELECT \"Generation\", \"RetainedFloor\", \"HighWater\" FROM \"SyncHistoryState\" WHERE \"Id\" = 1")
        .SingleAsync(token);

    // A restored database must not accept cursors from the previously active history.
    public const string RotateGenerationSql = "UPDATE \"SyncHistoryState\" SET \"Generation\" = lower(hex(randomblob(16))) WHERE \"Id\" = 1";

    public async Task<PagedResponse<T>> PageAsync<T>(Guid userId, string? revision,
        Func<Task<PagedResponse<T>>> read, CancellationToken token)
        => await SnapshotAsync(userId, async actual =>
    {
        if (revision is not null && !string.Equals(revision, actual, StringComparison.Ordinal))
            throw new MetadataException("catalog_changed", "The library changed while loading. Reload it to obtain a consistent result.", 409);
        var page = await read();
        return page with { Revision = actual };
    }, token);

    // Conditional responses and their bodies must observe the same database snapshot.
    // A page nested inside a conditional response reuses that transaction.
    public async Task<T> SnapshotAsync<T>(Guid userId, Func<string, Task<T>> read, CancellationToken token)
        => await ReadSnapshotAsync(async () =>
    {
        var history = await HistoryAsync(token);
        var revision = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{history.Generation}:{history.HighWater}:{userId}")));
        return await read(revision);
    }, token);

    private async Task<T> ReadSnapshotAsync<T>(Func<Task<T>> read, CancellationToken token)
    {
        if (database.Database.CurrentTransaction is not null) return await read();
        await database.Database.OpenConnectionAsync(token);
        try
        {
            // EF's default SQLite transaction reserves a writer. A deferred WAL
            // snapshot lets other readers and the writer continue while a GET reads.
            var connection = (SqliteConnection)database.Database.GetDbConnection();
            await using var native = connection.BeginTransaction(deferred: true);
            await using var tracked = await database.Database.UseTransactionAsync(native, token);
            var result = await read();
            await native.CommitAsync(token);
            return result;
        }
        finally { await database.Database.CloseConnectionAsync(); }
    }

    private async Task<SyncChangesResponse> ReadAsync(
        Guid userId,
        bool isAdministrator,
        long after,
        string? generation,
        CancellationToken cancellationToken)
        => await ReadSnapshotAsync(async () =>
    {
        var history = await HistoryAsync(cancellationToken);
        var visible = database.SyncChanges.AsNoTracking().Where(change =>
            (change.UserId == null || change.UserId == userId)
            && (isAdministrator || change.Area != SyncChangeArea.Libraries));
        if ((generation is not null && generation != history.Generation)
            || after > history.HighWater || (after > 0 && after < history.RetainedFloor))
        {
            return new SyncChangesResponse(history.HighWater, true, [], [], history.Generation);
        }

        var changes = await visible.Where(change => change.Cursor > after)
            .OrderBy(change => change.Cursor)
            .Take(1_000)
            .ToListAsync(cancellationToken);
        return new SyncChangesResponse(
            changes.Count < 1_000 ? history.HighWater : changes[^1].Cursor,
            false,
            changes.Select(change => change.Area).Distinct().ToList(),
            changes.Where(change => change.MediaItemId.HasValue)
                .Select(change => change.MediaItemId!.Value)
                .Distinct()
                .Take(MaximumChangedMediaIds)
                .ToList(), history.Generation);
    }, cancellationToken);
}
