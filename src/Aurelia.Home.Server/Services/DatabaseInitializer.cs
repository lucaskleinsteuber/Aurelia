using Aurelia.Home.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Home.Server.Services;

public static class DatabaseInitializer
{
    public static async Task InitializeAsync(IServiceProvider services, CancellationToken cancellationToken)
    {
        await using var scope = services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
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

        PrivateFilePermissions.ProtectFile(runtime.DatabasePath);
        PrivateFilePermissions.ProtectFile($"{runtime.DatabasePath}-wal");
        PrivateFilePermissions.ProtectFile($"{runtime.DatabasePath}-shm");
    }
}
