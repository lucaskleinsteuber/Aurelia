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

        // Program acquires ServerInstanceLock before initialization outside the isolated
        // test environment. EF Core's SQLite migration mutex is a database table whose
        // row can survive a force-quit, so no live migrator can own it at this point.
        // Removing only that coordination table lets EF recreate it instead of waiting
        // forever while leaving every Aurelia table and migration record untouched.
        await database.Database.ExecuteSqlRawAsync(
            "DROP TABLE IF EXISTS \"__EFMigrationsLock\";",
            cancellationToken);
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
