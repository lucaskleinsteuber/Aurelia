using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed partial class MaintenanceService(
    IServiceScopeFactory scopeFactory,
    ILogger<MaintenanceService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await RunAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception exception)
            {
                LogMaintenanceFailure(logger, exception.GetType().Name);
            }

            await Task.Delay(TimeSpan.FromMinutes(15), stoppingToken);
        }
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        await scope.ServiceProvider.GetRequiredService<PlaybackService>()
            .PruneExpiredAsync(now, cancellationToken);

        var pairingIds = await database.PairingCodes.AsNoTracking()
            .Where(code => code.ExpiresAt < now || code.ConsumedAt != null)
            .OrderBy(code => code.ExpiresAt).Select(code => code.Id).Take(100)
            .ToListAsync(cancellationToken);
        await database.PairingCodes.Where(code => pairingIds.Contains(code.Id))
            .ExecuteDeleteAsync(cancellationToken);

        var sessionCutoff = now.AddDays(-30);
        var sessionIds = await database.DeviceSessions.AsNoTracking()
            .Where(session => session.ExpiresAt < now
                || (session.RevokedAt != null && session.RevokedAt < sessionCutoff))
            .OrderBy(session => session.ExpiresAt).Select(session => session.Id).Take(100)
            .ToListAsync(cancellationToken);
        await database.DeviceSessions.Where(session => sessionIds.Contains(session.Id))
            .ExecuteDeleteAsync(cancellationToken);

        await scope.ServiceProvider.GetRequiredService<ArtworkStore>()
            .PruneOrphansAsync(database, cancellationToken);
        await scope.ServiceProvider.GetRequiredService<SyncChangeService>()
            .PruneAsync(cancellationToken);

        await PruneScanHistoryAsync(database, cancellationToken);
        await PruneMetadataHistoryAsync(database, cancellationToken);
        await database.Database.ExecuteSqlRawAsync("PRAGMA wal_checkpoint(PASSIVE);", cancellationToken);
    }

    private static async Task PruneScanHistoryAsync(
        AureliaDbContext database,
        CancellationToken cancellationToken)
    {
        var libraryIds = await database.LibraryRoots.AsNoTracking()
            .Select(library => library.Id).ToListAsync(cancellationToken);
        foreach (var libraryId in libraryIds)
        {
            var stale = await database.LibraryScans.AsNoTracking()
                .Where(scan => scan.LibraryRootId == libraryId
                    && scan.State != LibraryScanState.Queued
                    && scan.State != LibraryScanState.Running
                    && scan.State != LibraryScanState.WaitingForStorage)
                .OrderByDescending(scan => scan.CreatedAt).Skip(25)
                .Select(scan => scan.Id).Take(100).ToListAsync(cancellationToken);
            await database.LibraryScans.Where(scan => stale.Contains(scan.Id))
                .ExecuteDeleteAsync(cancellationToken);
        }
    }

    private static async Task PruneMetadataHistoryAsync(
        AureliaDbContext database,
        CancellationToken cancellationToken)
    {
        var stale = await database.MetadataJobs.AsNoTracking()
            .Where(job => job.State != MetadataJobState.Queued && job.State != MetadataJobState.Running)
            .OrderByDescending(job => job.CreatedAt).Skip(100)
            .Select(job => job.Id).Take(100).ToListAsync(cancellationToken);
        await database.MetadataJobs.Where(job => stale.Contains(job.Id))
            .ExecuteDeleteAsync(cancellationToken);
    }

    [LoggerMessage(LogLevel.Warning, "Aurelia maintenance failed with {ErrorType}.")]
    private static partial void LogMaintenanceFailure(ILogger logger, string errorType);
}
