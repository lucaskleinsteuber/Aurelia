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

        var searchIndex = scope.ServiceProvider.GetRequiredService<MediaSearchIndexService>();
        await searchIndex.RebuildAsync(cancellationToken);

        var playback = scope.ServiceProvider.GetRequiredService<PlaybackService>();
        await playback.PruneExpiredAsync(DateTimeOffset.UtcNow, cancellationToken);

        var artwork = scope.ServiceProvider.GetRequiredService<ArtworkStore>();
        await artwork.PruneOrphansAsync(database, cancellationToken);

        PrivateFilePermissions.ProtectFile(runtime.DatabasePath);
        PrivateFilePermissions.ProtectFile($"{runtime.DatabasePath}-wal");
        PrivateFilePermissions.ProtectFile($"{runtime.DatabasePath}-shm");
    }
}
