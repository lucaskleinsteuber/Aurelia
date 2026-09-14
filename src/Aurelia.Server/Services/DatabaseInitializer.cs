using Aurelia.Server.Data;
using Aurelia.Contracts;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public static class DatabaseInitializer
{
    public static async Task InitializeAsync(IServiceProvider services, CancellationToken cancellationToken)
    {
        await using var scope = services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var runtime = scope.ServiceProvider.GetRequiredService<ServerRuntimeOptions>();

        await database.Database.MigrateAsync(cancellationToken);

        if (!await database.ServerIdentities.AnyAsync(cancellationToken))
        {
            database.ServerIdentities.Add(new ServerIdentity
            {
                Id = 1,
                ServerId = Guid.NewGuid(),
                CreatedAt = DateTimeOffset.UtcNow,
            });
            await database.SaveChangesAsync(cancellationToken);
        }

        await database.Database.ExecuteSqlRawAsync(
            "PRAGMA journal_mode=WAL;",
            cancellationToken);
        await database.Database.ExecuteSqlRawAsync(
            "PRAGMA foreign_keys=ON;",
            cancellationToken);

        var playback = scope.ServiceProvider.GetRequiredService<PlaybackService>();
        await playback.PruneExpiredAsync(DateTimeOffset.UtcNow, cancellationToken);

        var interruptedAt = DateTimeOffset.UtcNow;
        await database.LibraryScans
            .Where(scan => scan.State == LibraryScanState.Queued
                || scan.State == LibraryScanState.Running)
            .ExecuteUpdateAsync(updates => updates
                .SetProperty(scan => scan.State, LibraryScanState.Interrupted)
                .SetProperty(scan => scan.CompletedAt, interruptedAt)
                .SetProperty(scan => scan.Error, "The server stopped before the scan completed."),
                cancellationToken);

        await database.MetadataJobs
            .Where(job => job.State == MetadataJobState.Queued
                || job.State == MetadataJobState.Running)
            .ExecuteUpdateAsync(updates => updates
                .SetProperty(job => job.State, MetadataJobState.Interrupted)
                .SetProperty(job => job.CompletedAt, interruptedAt)
                .SetProperty(job => job.Error, "The server stopped before metadata enrichment completed."),
                cancellationToken);

        var artwork = scope.ServiceProvider.GetRequiredService<ArtworkStore>();
        await artwork.PruneOrphansAsync(database, cancellationToken);

        PrivateFilePermissions.ProtectFile(runtime.DatabasePath);
        PrivateFilePermissions.ProtectFile($"{runtime.DatabasePath}-wal");
        PrivateFilePermissions.ProtectFile($"{runtime.DatabasePath}-shm");
    }
}
