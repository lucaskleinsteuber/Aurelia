using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Net.Http.Json;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerBackupSecurityTests
{
    [Fact]
    public async Task BackupConfigurationEntriesAreBoundedBeforeEncryptionAndParsing()
    {
        var root = TestPaths.CreateDataDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(root);
        try
        {
            await File.WriteAllBytesAsync(Path.Combine(root, "aurelia.db"), [1]);
            await using (var file = File.Create(Path.Combine(root, ServerHostSettings.FileName)))
                file.SetLength(EncryptedBackupContainer.MaximumEntryBytes(ServerHostSettings.FileName) + 1);
            using var output = new MemoryStream();
            await Assert.ThrowsAsync<InvalidDataException>(() => EncryptedBackupContainer.EncryptAsync(root,
                ["aurelia.db", ServerHostSettings.FileName], Guid.NewGuid(), output, "long backup passphrase", CancellationToken.None));
            Assert.Equal(0, output.Length);
        }
        finally { Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData("future-schema")]
    [InlineData("missing-owner")]
    [InlineData("invalid-provider")]
    public async Task InvalidFullRestoreDoesNotReplaceTheActiveDatabaseOrConfiguration(string mutation)
    {
        var root = TestPaths.CreateDataDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(root);
        var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", root]);
        var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={runtime.DatabasePath};Pooling=False").Options;
        var serverId = Guid.NewGuid();
        try
        {
            await using (var database = new AureliaDbContext(options))
            {
                await database.Database.MigrateAsync();
                database.ServerIdentities.Add(new ServerIdentity { Id = 1, ServerId = serverId, CreatedAt = DateTimeOffset.UtcNow });
                database.Users.Add(new ServerUser { Id = Guid.NewGuid(), Username = "owner", NormalizedUsername = "OWNER", PasswordHash = "synthetic hash", Role = UserRole.Owner, CreatedAt = DateTimeOffset.UtcNow });
                await database.SaveChangesAsync();
            }
            var configuration = new ServerConfigurationStore(runtime);
            configuration.Update(configuration.Current with { DeviceSessionDays = 30 });
            var backups = new DatabaseBackupService(runtime, configuration);
            using var full = new FullServerBackupService(runtime, backups, configuration);
            var export = await full.ExportAsync("long backup passphrase", CancellationToken.None);
            var stage = Path.Combine(root, "invalid-backup-source");
            BackupManifest manifest;
            await using (var source = File.OpenRead(full.TransferPath(export.Id)))
                manifest = await EncryptedBackupContainer.DecryptAsync(source, stage, "long backup passphrase", CancellationToken.None);
            if (mutation == "invalid-provider")
                await File.WriteAllTextAsync(Path.Combine(stage, "metadata-settings.json"), "{\"version\":999}");
            else
            {
                await using var altered = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={Path.Combine(stage, "aurelia.db")};Pooling=False");
                await altered.OpenAsync();
                await using var change = altered.CreateCommand();
                change.CommandText = mutation == "future-schema"
                    ? "INSERT INTO __EFMigrationsHistory(MigrationId, ProductVersion) VALUES ('99999999999999_UnsupportedFutureSchema','10.0.0');"
                    : "UPDATE Users SET Role='User';";
                await change.ExecuteNonQueryAsync();
            }
            using var encrypted = new MemoryStream();
            var entries = manifest.Files.Select(file => file.Name)
                .Concat(mutation == "invalid-provider" ? ["metadata-settings.json"] : Array.Empty<string>()).Distinct(StringComparer.Ordinal).ToArray();
            await EncryptedBackupContainer.EncryptAsync(stage, entries, serverId, encrypted, "long backup passphrase", CancellationToken.None);
            encrypted.Position = 0;
            var upload = Guid.NewGuid();
            await full.UploadAsync(upload, encrypted, encrypted.Length, CancellationToken.None);
            var error = await Assert.ThrowsAsync<AccountException>(() => full.PrepareRestoreAsync(new(upload, "long backup passphrase", true), CancellationToken.None));
            Assert.Equal("backup_invalid", error.Code);
            await using var active = new AureliaDbContext(options);
            Assert.Equal(serverId, (await active.ServerIdentities.SingleAsync()).ServerId);
            Assert.Equal(UserRole.Owner, (await active.Users.SingleAsync()).Role);
            Assert.Equal(30, ServerHostSettings.Load(root)!.DeviceSessionDays);
            Assert.False(File.Exists(Path.Combine(root, ".full-restore.pending")));
            Assert.Empty(Directory.EnumerateDirectories(backups.BackupDirectory, ".restore-*"));
        }
        finally { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    [Fact]
    public void RoutineCertificateRenewalPreservesThePairedPublicKey()
    {
        var root = TestPaths.CreateDataDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(root);
        var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", root]);
        try
        {
            using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var request = new CertificateRequest("CN=Aurelia Server", key, HashAlgorithmName.SHA256);
            using var expired = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-60), DateTimeOffset.UtcNow.AddDays(-1));
            File.WriteAllText(runtime.CertificatePath, expired.ExportCertificatePem());
            File.WriteAllText(runtime.PrivateKeyPath, key.ExportPkcs8PrivateKeyPem());
            var expected = Convert.ToHexString(SHA256.HashData(key.ExportSubjectPublicKeyInfo()));
            using var renewed = ServerTlsIdentity.LoadOrCreate(runtime);
            Assert.Equal(expected, renewed.PublicKeyFingerprint);
            Assert.True(renewed.Certificate!.NotAfter.ToUniversalTime() > DateTime.UtcNow.AddYears(1));
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task InterruptedRestoreIsRecoveredBeforeStartupLoadsConfiguration()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", root]);
        try
        {
            var configuration = new ServerConfigurationStore(runtime with { ServerName = "Original server" });
            configuration.Update(configuration.Current);
            var id = Guid.NewGuid();
            var undo = Path.Combine(root, "Backups", ".restore-undo-" + id.ToString("N"));
            PrivateFilePermissions.CreatePrivateDirectory(undo);
            File.Move(Path.Combine(root, ServerHostSettings.FileName), Path.Combine(undo, ServerHostSettings.FileName));
            await File.WriteAllTextAsync(Path.Combine(root, ServerHostSettings.FileName), """{"version":2,"serverName":"Interrupted replacement","lanAccessEnabled":false,"lanHttpsPort":43111}""");
            await File.WriteAllTextAsync(Path.Combine(root, ".full-restore.pending"), JsonSerializer.Serialize(new
            { version = 1, id, originals = new[] { ServerHostSettings.FileName }, replacements = new[] { ServerHostSettings.FileName } }));
            using var factory = new AureliaServerFactory(root);
            using var client = factory.CreateClient();
            var info = await client.GetFromJsonAsync<ServerInfoResponse>("/api/v1/server/info", ApiTestClient.JsonOptions);
            Assert.Equal("Original server", info!.Name);
            Assert.False(File.Exists(Path.Combine(root, ".full-restore.pending")));
        }
        finally { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    [Fact]
    public async Task DuplicateAndFailedUploadsCannotDeleteExistingBackupOrTouchActiveData()
    {
        var root = TestPaths.CreateDataDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(root);
        var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", root]);
        try
        {
            var settings = new ServerConfigurationStore(runtime);
            using var full = new FullServerBackupService(runtime, new DatabaseBackupService(runtime), settings);
            var id = Guid.NewGuid();
            var original = new byte[] { 1, 2, 3, 4 };
            using (var input = new MemoryStream(original)) await full.UploadAsync(id, input, 4, CancellationToken.None);
            using (var second = new MemoryStream(new byte[] { 5, 6, 7, 8 }))
                await Assert.ThrowsAsync<IOException>(() => full.UploadAsync(id, second, 4, CancellationToken.None));
            Assert.Equal(original, await File.ReadAllBytesAsync(full.TransferPath(id)));
            var failed = Guid.NewGuid();
            using (var incomplete = new MemoryStream(new byte[] { 1 }))
                await Assert.ThrowsAsync<InvalidDataException>(() => full.UploadAsync(failed, incomplete, 4, CancellationToken.None));
            Assert.False(File.Exists(full.TransferPath(failed)));
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            using var source = new MemoryStream(original);
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => full.UploadAsync(Guid.NewGuid(), source, 4, cancelled.Token));
            Assert.False(File.Exists(runtime.DatabasePath));
        }
        finally { Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData("wrong-password")]
    [InlineData("truncated")]
    [InlineData("modified")]
    [InlineData("appended")]
    [InlineData("header")]
    public async Task EncryptedContainerRejectsPasswordIntegrityCompletenessAndManifestTampering(string mutation)
    {
        var root = TestPaths.CreateDataDirectory();
        var source = Path.Combine(root, "source");
        Directory.CreateDirectory(source);
        try
        {
            await File.WriteAllBytesAsync(Path.Combine(source, "aurelia.db"), RandomNumberGenerator.GetBytes(1024 * 1024 + 37));
            using var encrypted = new MemoryStream();
            await EncryptedBackupContainer.EncryptAsync(source, ["aurelia.db"], Guid.NewGuid(), encrypted, "long backup passphrase", CancellationToken.None);
            var bytes = encrypted.ToArray();
            var password = "long backup passphrase";
            switch (mutation)
            {
                case "wrong-password": password = "wrong backup passphrase"; break;
                case "truncated": bytes = bytes[..^8]; break;
                case "modified": bytes[^40] ^= 0x80; break;
                case "appended": bytes = [.. bytes, 0xff]; break;
                case "header": bytes[15] ^= 0x10; break;
            }
            using var damaged = new MemoryStream(bytes);
            var failed = await Record.ExceptionAsync(() => EncryptedBackupContainer.DecryptAsync(damaged, Path.Combine(root, "restore"), password, CancellationToken.None));
            Assert.NotNull(failed);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task EncryptedContainerRoundTripsMultipleBlocksAndExcludesUnsafeNames()
    {
        var root = TestPaths.CreateDataDirectory();
        var source = Path.Combine(root, "source");
        Directory.CreateDirectory(source);
        try
        {
            var original = RandomNumberGenerator.GetBytes(2 * 1024 * 1024 + 91);
            await File.WriteAllBytesAsync(Path.Combine(source, "aurelia.db"), original);
            using var encrypted = new MemoryStream();
            var serverId = Guid.NewGuid();
            await EncryptedBackupContainer.EncryptAsync(source, ["aurelia.db"], serverId, encrypted, "long backup passphrase", CancellationToken.None);
            encrypted.Position = 0;
            var restored = await EncryptedBackupContainer.DecryptAsync(encrypted, Path.Combine(root, "restore"), "long backup passphrase", CancellationToken.None);
            Assert.Equal(serverId, restored.ServerId);
            Assert.False(restored.IncludesMedia);
            Assert.False(restored.IncludesArtwork);
            Assert.Equal(original, await File.ReadAllBytesAsync(Path.Combine(root, "restore", "aurelia.db")));
            Assert.False(EncryptedBackupContainer.AllowedName("../server-private-key.pem"));
            Assert.False(EncryptedBackupContainer.AllowedName("Movies/example.mkv"));
            if (!OperatingSystem.IsWindows()) Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(Path.Combine(root, "restore", "aurelia.db")));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task FullRestorePreservesLibraryAndIdentityButRevokesOldDeviceTokens()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", root]);
        var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={runtime.DatabasePath};Pooling=False").Options;
        var ownerId = Guid.NewGuid();
        var libraryId = Guid.NewGuid();
        var serverId = Guid.NewGuid();
        var deviceId = Guid.NewGuid();
        try
        {
            await using (var database = new AureliaDbContext(options))
            {
                await database.Database.MigrateAsync();
                database.ServerIdentities.Add(new ServerIdentity { Id = 1, ServerId = serverId, CreatedAt = DateTimeOffset.UtcNow });
                var user = new ServerUser { Id = ownerId, Username = "owner", NormalizedUsername = "OWNER", PasswordHash = "synthetic hash", Role = UserRole.Owner, CreatedAt = DateTimeOffset.UtcNow };
                database.Users.Add(user);
                database.LibraryRoots.Add(new LibraryRoot { Id = libraryId, Name = "Synthetic library", Path = Path.Combine(root, "original-media"), NormalizedPath = Path.Combine(root, "original-media"), Kind = LibraryKind.Movies, CreatedAt = DateTimeOffset.UtcNow });
                database.DeviceSessions.Add(new DeviceSession { Id = deviceId, UserId = ownerId, User = user, DeviceName = "synthetic device", TokenHash = new string('a', 64), CreatedAt = DateTimeOffset.UtcNow, LastSeenAt = DateTimeOffset.UtcNow, ExpiresAt = DateTimeOffset.UtcNow.AddDays(90) });
                await database.SaveChangesAsync();
            }
            var configuration = new ServerConfigurationStore(runtime);
            configuration.Update(configuration.Current with { DeviceSessionDays = 30 });
            var backups = new DatabaseBackupService(runtime, configuration);
            using var full = new FullServerBackupService(runtime, backups, configuration);
            var export = await full.ExportAsync("long backup passphrase", CancellationToken.None);
            await using (var database = new AureliaDbContext(options))
            {
                var library = await database.LibraryRoots.SingleAsync();
                library.Name = "After backup";
                await database.SaveChangesAsync();
            }
            var prepared = await full.PrepareRestoreAsync(new(export.Id, "long backup passphrase", true), CancellationToken.None);
            using (ServerInstanceLock.Acquire(root)) await FullServerBackupService.ApplyPreparedAsync(runtime, prepared.Id, CancellationToken.None);
            await using (var database = new AureliaDbContext(options))
            {
                Assert.Equal("Synthetic library", (await database.LibraryRoots.SingleAsync()).Name);
                Assert.Equal(libraryId, (await database.LibraryRoots.SingleAsync()).Id);
                Assert.Equal(serverId, (await database.ServerIdentities.SingleAsync()).ServerId);
                Assert.NotNull((await database.DeviceSessions.SingleAsync()).RevokedAt);
            }
            Assert.Single(Directory.EnumerateDirectories(Path.Combine(root, "Backups"), "pre-full-restore-*"));
        }
        finally { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }
}
