using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

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
            var response = await ReadAsync(userId, isAdministrator, after, cancellationToken);
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
        await database.SyncChanges.AsNoTracking()
            .Where(change => (change.UserId == null || change.UserId == userId)
                && (isAdministrator || change.Area != SyncChangeArea.Libraries))
            .MaxAsync(change => (long?)change.Cursor, cancellationToken) ?? 0;

    public async Task PruneAsync(CancellationToken cancellationToken)
    {
        var cutoff = DateTimeOffset.UtcNow.AddDays(-7);
        var newestRetainedCursor = await database.SyncChanges
            .AsNoTracking()
            .OrderByDescending(change => change.Cursor)
            .Skip(9_999)
            .Select(change => (long?)change.Cursor)
            .FirstOrDefaultAsync(cancellationToken);
        await database.SyncChanges
            .Where(change => change.CreatedAt < cutoff
                || (newestRetainedCursor.HasValue && change.Cursor < newestRetainedCursor.Value))
            .ExecuteDeleteAsync(cancellationToken);
    }

    private async Task<SyncChangesResponse> ReadAsync(
        Guid userId,
        bool isAdministrator,
        long after,
        CancellationToken cancellationToken)
    {
        var visible = database.SyncChanges.AsNoTracking().Where(change =>
            (change.UserId == null || change.UserId == userId)
            && (isAdministrator || change.Area != SyncChangeArea.Libraries));
        var oldest = await visible.OrderBy(change => change.Cursor)
            .Select(change => (long?)change.Cursor)
            .FirstOrDefaultAsync(cancellationToken);
        var latest = await visible.OrderByDescending(change => change.Cursor)
            .Select(change => (long?)change.Cursor)
            .FirstOrDefaultAsync(cancellationToken) ?? 0;
        if (after > 0 && oldest.HasValue && after < oldest.Value - 1)
        {
            return new SyncChangesResponse(latest, true, [], []);
        }

        var changes = await visible.Where(change => change.Cursor > after)
            .OrderBy(change => change.Cursor)
            .Take(1_000)
            .ToListAsync(cancellationToken);
        return new SyncChangesResponse(
            changes.Count == 0 ? latest : changes[^1].Cursor,
            false,
            changes.Select(change => change.Area).Distinct().ToList(),
            changes.Where(change => change.MediaItemId.HasValue)
                .Select(change => change.MediaItemId!.Value)
                .Distinct()
                .Take(MaximumChangedMediaIds)
                .ToList());
    }
}
