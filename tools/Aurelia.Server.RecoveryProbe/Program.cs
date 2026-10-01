using System.Security.Cryptography;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;

// Run only on a fresh, explicitly supplied disposable disk-image volume.
if (args.Length != 1 || !Directory.Exists(args[0]) || Directory.Exists(Path.Combine(args[0], "Data")))
    throw new ArgumentException("Supply a fresh disposable recovery-probe volume.");
var root = Path.Combine(Path.GetFullPath(args[0]), "Data");
PrivateFilePermissions.CreatePrivateDirectory(root);
var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["run", "--data-dir", root]);
var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={runtime.DatabasePath};Pooling=False").Options;
await using (var database = new AureliaDbContext(options))
{
    await database.Database.MigrateAsync();
    database.ServerIdentities.Add(new ServerIdentity { Id = 1, ServerId = Guid.NewGuid(), CreatedAt = DateTimeOffset.UtcNow });
    var owner = new ServerUser { Id = Guid.NewGuid(), Username = "synthetic-owner", NormalizedUsername = "SYNTHETIC-OWNER", PasswordHash = "synthetic probe hash", Role = UserRole.Owner, CreatedAt = DateTimeOffset.UtcNow };
    database.Users.Add(owner);
    database.DeviceSessions.Add(new DeviceSession { Id = Guid.NewGuid(), UserId = owner.Id, User = owner, DeviceName = "synthetic device", TokenHash = new string('a', 64), CreatedAt = DateTimeOffset.UtcNow, LastSeenAt = DateTimeOffset.UtcNow, ExpiresAt = DateTimeOffset.UtcNow.AddDays(90) });
    database.LibraryRoots.Add(new LibraryRoot { Id = Guid.NewGuid(), Name = "Original synthetic library", Path = Path.Combine(root, "NoMedia"), NormalizedPath = Path.Combine(root, "NoMedia"), Kind = LibraryKind.Movies, CreatedAt = DateTimeOffset.UtcNow });
    await database.SaveChangesAsync();
}
var configuration = new ServerConfigurationStore(runtime);
configuration.Update(configuration.Current);
var backups = new DatabaseBackupService(runtime, configuration);
using var full = new FullServerBackupService(runtime, backups, configuration);
var export = await full.ExportAsync("isolated recovery probe passphrase", CancellationToken.None);
var prepared = await full.PrepareRestoreAsync(new(export.Id, "isolated recovery probe passphrase", true), CancellationToken.None);
await using (var database = new AureliaDbContext(options))
{
    var library = await database.LibraryRoots.SingleAsync();
    library.Name = "Current synthetic library";
    await database.SaveChangesAsync();
}
SqliteConnection.ClearAllPools();
var filler = Path.Combine(args[0], "probe-disk-full.bin");
var exhausted = false;
try
{
    // This file is confined to the supplied small disk image, never the host disk.
    await using (var fill = PrivateFilePermissions.OpenNewPrivateFile(filler))
    {
        var bytes = RandomNumberGenerator.GetBytes(1024 * 1024);
        try
        {
            for (var i = 0; i < 1024; i++) await fill.WriteAsync(bytes);
            fill.Flush(flushToDisk: true);
        }
        catch (IOException) { exhausted = true; }
    }
    if (!exhausted) throw new InvalidOperationException("The probe volume did not run out of space; no disk-full result can be claimed.");
    Exception? failure = null;
    try { using (ServerInstanceLock.Acquire(root)) await FullServerBackupService.ApplyPreparedAsync(runtime, prepared.Id, CancellationToken.None); }
    catch (Exception exception) when (exception is IOException || exception is SqliteException { SqliteErrorCode: 13 }) { failure = exception; }
    if (failure is null) throw new InvalidOperationException("Restore unexpectedly succeeded on the exhausted volume.");
    await AssertUnchangedAsync();
    Console.WriteLine("PASS: actual disk exhaustion rejects restore before active state replacement; library and device session remain unchanged.");
}
finally { if (File.Exists(filler)) File.Delete(filler); }
using (var cancelled = new CancellationTokenSource())
{
    cancelled.Cancel();
    var rejected = false;
    try { using (ServerInstanceLock.Acquire(root)) await FullServerBackupService.ApplyPreparedAsync(runtime, prepared.Id, cancelled.Token); }
    catch (OperationCanceledException) { rejected = true; }
    if (!rejected) throw new InvalidOperationException("Cancelled restore was not rejected.");
    await AssertUnchangedAsync();
    Console.WriteLine("PASS: cancellation before activation leaves current state intact.");
}
using (ServerInstanceLock.Acquire(root)) await FullServerBackupService.ApplyPreparedAsync(runtime, prepared.Id, CancellationToken.None);
await using (var database = new AureliaDbContext(options))
{
    if ((await database.LibraryRoots.SingleAsync()).Name != "Original synthetic library" || (await database.DeviceSessions.SingleAsync()).RevokedAt is null)
        throw new InvalidOperationException("Restored state did not match the validated snapshot and revocation policy.");
}
Console.WriteLine("PASS: after freeing disposable disk space, the verified restore succeeds and revokes the old session.");
SqliteConnection.ClearAllPools();

async Task AssertUnchangedAsync()
{
    await using var database = new AureliaDbContext(options);
    if ((await database.LibraryRoots.SingleAsync()).Name != "Current synthetic library" || (await database.DeviceSessions.SingleAsync()).RevokedAt is not null
        || File.Exists(Path.Combine(root, ".full-restore.pending")))
        throw new InvalidOperationException("A rejected restore changed active state.");
}
