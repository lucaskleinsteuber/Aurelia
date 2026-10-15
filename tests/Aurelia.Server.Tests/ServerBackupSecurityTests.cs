using System.Security.Cryptography;
using System.Buffers.Binary;
using System.Security.Cryptography.X509Certificates;
using System.Net.Http.Json;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerBackupSecurityTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task EncryptedProfileRestorePreservesPinsAccessNotesAndIdsAcrossOptionalPinMigration(bool previousSchema)
    {
        var root = TestPaths.CreateDataDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(root);
        var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", root]);
        var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={runtime.DatabasePath};Pooling=False").Options;
        var serverId = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow;
        var owner = new ServerUser
        {
            Id = Guid.NewGuid(),
            Username = "owner",
            NormalizedUsername = "OWNER",
            PasswordHash = "synthetic-owner-hash",
            PinHash = "synthetic-owner-pin-hash",
            Role = UserRole.Owner,
            AccessMode = ProfileAccessMode.EntireLibrary,
            CreatedAt = now
        };
        var viewer = new ServerUser
        {
            Id = Guid.NewGuid(),
            Username = "viewer",
            NormalizedUsername = "VIEWER",
            PasswordHash = "unused-profile-password-hash",
            PinHash = "synthetic-viewer-pin-hash",
            Role = UserRole.User,
            AccessMode = ProfileAccessMode.SelectedTitles,
            CreatedAt = now
        };
        var pending = new ServerUser { Id = Guid.NewGuid(), Username = "pending", NormalizedUsername = "PENDING", PasswordHash = "pending-unused-hash", Role = UserRole.User, CreatedAt = now };
        var pinless = new ServerUser
        {
            Id = Guid.NewGuid(),
            Username = "pinless",
            NormalizedUsername = "PINLESS",
            PasswordHash = "pinless-unused-hash",
            PinProtectionEnabled = false,
            Role = UserRole.User,
            CreatedAt = now
        };
        var mediaId = Guid.NewGuid();
        var noteId = Guid.NewGuid();
        var deviceId = Guid.NewGuid();
        try
        {
            await using (var database = new AureliaDbContext(options))
            {
                await database.Database.MigrateAsync();
                database.ServerIdentities.Add(new ServerIdentity { Id = 1, ServerId = serverId, CreatedAt = now });
                database.AdministrationCredentials.Add(new ServerAdministrationCredential { PasswordHash = "synthetic-server-password-hash" });
                database.Users.AddRange(owner, viewer, pending);
                if (!previousSchema) database.Users.Add(pinless);
                var library = new LibraryRoot
                {
                    Id = Guid.NewGuid(),
                    Name = "Synthetic archive library",
                    Path = root,
                    NormalizedPath = MediaPath.Normalize(root),
                    Kind = LibraryKind.Movies,
                    CreatedAt = now
                };
                var media = new MediaItem
                {
                    Id = mediaId,
                    LibraryRoot = library,
                    LibraryRootId = library.Id,
                    Kind = MediaKind.Movie,
                    SourcePath = Path.Combine(root, "offline.mkv"),
                    NormalizedSourcePath = MediaPath.Normalize(Path.Combine(root, "offline.mkv")),
                    DetectedTitle = "Synthetic offline title",
                    Availability = MediaAvailability.Missing,
                    CreatedAt = now,
                    UpdatedAt = now
                };
                database.MediaItems.Add(media);
                database.UserTitleGrants.Add(new UserTitleGrant { User = viewer, UserId = viewer.Id, MediaItem = media, MediaItemId = mediaId });
                database.SceneNotes.Add(new SceneNote
                {
                    Id = noteId,
                    User = viewer,
                    UserId = viewer.Id,
                    MediaItem = media,
                    MediaItemId = mediaId,
                    StartMilliseconds = 330_000,
                    EndMilliseconds = 367_000,
                    Text = "Synthetic private marker"
                });
                database.PlaybackProgress.Add(new PlaybackProgress
                {
                    Id = Guid.NewGuid(),
                    User = viewer,
                    UserId = viewer.Id,
                    MediaItem = media,
                    MediaItemId = mediaId,
                    PositionMilliseconds = 123_000,
                    DurationMilliseconds = 400_000,
                    LastPlayedAt = now,
                    UpdatedAt = now,
                    Revision = 7
                });
                database.DeviceSessions.Add(new DeviceSession
                {
                    Id = deviceId,
                    User = owner,
                    UserId = owner.Id,
                    DeviceName = "Synthetic archived device",
                    TokenHash = "synthetic-device-hash",
                    CreatedAt = now,
                    LastSeenAt = now,
                    ExpiresAt = now.AddDays(90)
                });
                if (!previousSchema)
                {
                    var jobId = Guid.NewGuid();
                    database.MetadataJobs.Add(new MetadataJob { Id = jobId, RequestedByUserId = owner.Id, WorklistInitialized = true, State = MetadataJobState.Queued, ItemsTotal = 1, NextAttemptAt = now.AddMinutes(20), WaitReason = "tmdb" });
                    database.MetadataJobItems.Add(new MetadataJobItem { JobId = jobId, MediaItemId = mediaId, State = MetadataWorkState.Pending, Attempt = 2 });
                    database.MetadataProviderCooldowns.Add(new MetadataProviderCooldown { NotBefore = now.AddMinutes(20), WaitReason = "tmdb" });
                    database.ContinueWatchingStates.Add(new ContinueWatchingState { UserId = viewer.Id, User = viewer, MediaItemId = mediaId, MediaItem = media, IsHidden = true, Revision = 4 });
                    database.LibraryStateMutations.Add(new LibraryStateMutation { UserId = viewer.Id, User = viewer, ClientMutationId = noteId, Fingerprint = "synthetic-state-receipt", ResponseJson = "synthetic-replay-snapshot", AccessRevision = viewer.AccessRevision });
                }
                await database.SaveChangesAsync();
                if (previousSchema) await database.Database.GetService<IMigrator>().MigrateAsync("20261013052618_ProfilesAndSceneNotes");
            }
            var configuration = new ServerConfigurationStore(runtime);
            var backups = new DatabaseBackupService(runtime, configuration);
            using var full = new FullServerBackupService(runtime, backups, configuration);
            var export = await full.ExportAsync("long synthetic backup passphrase", CancellationToken.None);
            var prepared = await full.PrepareRestoreAsync(new(export.Id, "long synthetic backup passphrase", true), CancellationToken.None);
            await FullServerBackupService.ApplyPreparedAsync(runtime, prepared.Id, CancellationToken.None);
            await using var restored = new AureliaDbContext(options);
            await restored.Database.MigrateAsync();
            var users = await restored.Users.AsNoTracking().ToDictionaryAsync(user => user.Id);
            Assert.Equal(previousSchema ? 3 : 4, users.Count);
            Assert.Equal(owner.PinHash, users[owner.Id].PinHash);
            Assert.Equal(viewer.PinHash, users[viewer.Id].PinHash);
            Assert.True(users[owner.Id].PinProtectionEnabled);
            Assert.True(users[viewer.Id].PinProtectionEnabled);
            Assert.True(users[pending.Id].PinProtectionEnabled);
            Assert.True(ProfileService.ToSummary(users[pending.Id]).NeedsPinSetup);
            if (!previousSchema) Assert.False(users[pinless.Id].PinProtectionEnabled);
            Assert.Equal(ProfileAccessMode.SelectedTitles, users[viewer.Id].AccessMode);
            var grant = await restored.UserTitleGrants.SingleAsync();
            Assert.Equal(viewer.Id, grant.UserId);
            Assert.Equal(mediaId, grant.MediaItemId);
            var note = await restored.SceneNotes.SingleAsync();
            Assert.Equal(noteId, note.Id);
            Assert.Equal(viewer.Id, note.UserId);
            Assert.Equal(mediaId, note.MediaItemId);
            Assert.Equal("Synthetic private marker", note.Text);
            Assert.Equal(330_000, note.StartMilliseconds);
            Assert.Equal(123_000, (await restored.PlaybackProgress.SingleAsync()).PositionMilliseconds);
            if (!previousSchema)
            {
                var restoredJob = await restored.MetadataJobs.SingleAsync();
                Assert.True(restoredJob.WorklistInitialized);
                Assert.Equal(owner.Id, restoredJob.RequestedByUserId);
                Assert.Equal("tmdb", restoredJob.WaitReason);
                Assert.Equal(now.AddMinutes(20).ToUnixTimeMilliseconds(), restoredJob.NextAttemptAt!.Value.ToUnixTimeMilliseconds());
                var work = await restored.MetadataJobItems.SingleAsync();
                Assert.Equal(mediaId, work.MediaItemId);
                Assert.Equal(2, work.Attempt);
                Assert.Equal(MetadataWorkState.Pending, work.State);
                Assert.Equal(restoredJob.NextAttemptAt, (await restored.MetadataProviderCooldowns.SingleAsync()).NotBefore);
                var hidden = await restored.ContinueWatchingStates.SingleAsync();
                Assert.Equal(viewer.Id, hidden.UserId); Assert.Equal(mediaId, hidden.MediaItemId); Assert.True(hidden.IsHidden); Assert.Equal(4, hidden.Revision);
                var receipt = await restored.LibraryStateMutations.SingleAsync();
                Assert.Equal(noteId, receipt.ClientMutationId); Assert.Equal("synthetic-replay-snapshot", receipt.ResponseJson);
            }
            Assert.NotNull((await restored.DeviceSessions.SingleAsync(session => session.Id == deviceId)).RevokedAt);
            Assert.Equal("synthetic-server-password-hash", (await restored.AdministrationCredentials.SingleAsync()).PasswordHash);
            Assert.Equal(serverId, (await restored.ServerIdentities.SingleAsync()).ServerId);
            Assert.Equal(17, (await backups.VerifyAsync(runtime.DatabasePath, CancellationToken.None)).AppliedMigrationCount);
            Assert.False(File.Exists(Path.Combine(root, "offline.mkv")));
        }
        finally { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    [Fact]
    public async Task FullBackupPreservesImportedArtworkOriginalsAndCropsWithoutVideosOrProviderCache()
    {
        var root = TestPaths.CreateDataDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(root);
        var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", root]);
        var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={runtime.DatabasePath};Pooling=False").Options;
        var media = Guid.NewGuid(); var manual = Guid.NewGuid(); var provider = Guid.NewGuid();
        SyncChangeService.HistoryState originalHistory;
        var png = MediaEditingTests.Png(120, 180);
        var original = MediaEditingTests.Png(180, 180);
        try
        {
            var artwork = Path.Combine(root, "Artwork"); PrivateFilePermissions.CreatePrivateDirectory(artwork);
            await File.WriteAllBytesAsync(Path.Combine(artwork, manual.ToString("N") + ".png"), png);
            await File.WriteAllBytesAsync(Path.Combine(artwork, manual.ToString("N") + ".original.png"), original);
            await File.WriteAllBytesAsync(Path.Combine(artwork, provider.ToString("N") + ".png"), png);
            var movies = Path.Combine(root, "Videos"); Directory.CreateDirectory(movies);
            var video = Path.Combine(movies, "Synthetic.mkv"); await File.WriteAllBytesAsync(video, [4, 5, 6]);
            await using (var database = new AureliaDbContext(options))
            {
                await database.Database.MigrateAsync();
                database.ServerIdentities.Add(new ServerIdentity { Id = 1, ServerId = Guid.NewGuid(), CreatedAt = DateTimeOffset.UtcNow });
                database.Users.Add(new ServerUser { Id = Guid.NewGuid(), Username = "owner", NormalizedUsername = "OWNER", PasswordHash = "synthetic hash", Role = UserRole.Owner, CreatedAt = DateTimeOffset.UtcNow });
                var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", Path = movies, NormalizedPath = MediaPath.Normalize(movies), Kind = LibraryKind.Movies, CreatedAt = DateTimeOffset.UtcNow };
                database.LibraryRoots.Add(library);
                var metadata = new MediaMetadata { MediaItemId = media, ManualTitle = "Corrected title", ManualFieldsJson = "[\"title\",\"poster\"]", ManualPosterId = manual, UpdatedAt = DateTimeOffset.UtcNow };
                metadata.Artwork.Add(new ArtworkAsset
                {
                    Id = manual,
                    MediaItemId = media,
                    IsManual = true,
                    Kind = ArtworkKind.Poster,
                    ProviderPath = "manual/" + manual.ToString("N"),
                    RelativeFilePath = manual.ToString("N") + ".png",
                    OriginalFilePath = manual.ToString("N") + ".original.png",
                    CropJson = "{\"x\":0.1666666667,\"y\":0,\"width\":0.6666666666,\"height\":1,\"rotation\":90}",
                    ContentType = "image/png",
                    ContentLength = png.Length,
                    CreatedAt = DateTimeOffset.UtcNow
                });
                metadata.Artwork.Add(new ArtworkAsset { Id = provider, MediaItemId = media, Kind = ArtworkKind.Poster, ProviderPath = "/provider.png", RelativeFilePath = provider.ToString("N") + ".png", ContentType = "image/png", ContentLength = png.Length, CreatedAt = DateTimeOffset.UtcNow });
                database.MediaItems.Add(new MediaItem { Id = media, LibraryRootId = library.Id, Kind = MediaKind.Movie, SourcePath = video, NormalizedSourcePath = MediaPath.Normalize(video), DetectedTitle = "Synthetic", Metadata = metadata, CreatedAt = DateTimeOffset.UtcNow, UpdatedAt = DateTimeOffset.UtcNow });
                await database.SaveChangesAsync();
                originalHistory = await new SyncChangeService(database, new DatabaseChangeSignal()).HistoryAsync(CancellationToken.None);
            }
            var configuration = new ServerConfigurationStore(runtime); var backups = new DatabaseBackupService(runtime, configuration);
            using var full = new FullServerBackupService(runtime, backups, configuration);
            var export = await full.ExportAsync("long backup passphrase", CancellationToken.None);
            Assert.True(export.IncludesArtwork); Assert.False(export.IncludesMedia);
            var stage = Path.Combine(root, "inspection");
            BackupManifest manifest;
            await using (var encrypted = File.OpenRead(full.TransferPath(export.Id)))
                manifest = await EncryptedBackupContainer.DecryptAsync(encrypted, stage, "long backup passphrase", CancellationToken.None);
            Assert.Equal(2, manifest.Version); Assert.True(manifest.IncludesArtwork);
            Assert.Contains(manifest.Files, file => file.Name == "Artwork/" + manual.ToString("N") + ".original.png");
            Assert.DoesNotContain(manifest.Files, file => file.Name.Contains(provider.ToString("N"), StringComparison.Ordinal) || file.Name.Contains(".mkv", StringComparison.Ordinal));
            Assert.Equal(original, await File.ReadAllBytesAsync(Path.Combine(stage, "Artwork", manual.ToString("N") + ".original.png")));
            var prepared = await full.PrepareRestoreAsync(new(export.Id, "long backup passphrase", true), CancellationToken.None);
            await File.WriteAllBytesAsync(Path.Combine(artwork, manual.ToString("N") + ".png"), [0]);
            await FullServerBackupService.ApplyPreparedAsync(runtime, prepared.Id, CancellationToken.None);
            await using var restored = new AureliaDbContext(options);
            var restoredChanges = new SyncChangeService(restored, new DatabaseChangeSignal());
            var restoredHistory = await restoredChanges.HistoryAsync(CancellationToken.None);
            Assert.NotEqual(originalHistory.Generation, restoredHistory.Generation);
            var restoredOwner = await restored.Users.SingleAsync();
            Assert.True((await restoredChanges.ChangesAsync(restoredOwner.Id, true, originalHistory.HighWater, 0,
                originalHistory.Generation, CancellationToken.None)).ResetRequired);
            Assert.Equal("Corrected title", (await restored.MediaMetadata.SingleAsync()).ManualTitle);
            Assert.Contains("\"rotation\":90", (await restored.ArtworkAssets.SingleAsync(asset => asset.Id == manual)).CropJson!, StringComparison.Ordinal);
            Assert.Equal(png, await File.ReadAllBytesAsync(Path.Combine(artwork, manual.ToString("N") + ".png")));
            Assert.Equal(original, await File.ReadAllBytesAsync(Path.Combine(artwork, manual.ToString("N") + ".original.png")));
            Assert.Equal(new byte[] { 4, 5, 6 }, await File.ReadAllBytesAsync(video));
        }
        finally { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    [Fact]
    public async Task VersionOneContainerRemainsReadableWithItsOriginalAuthenticatedFormat()
    {
        var root = TestPaths.CreateDataDirectory(); Directory.CreateDirectory(root);
        try
        {
            var plaintext = new byte[] { 1, 2, 3, 4, 5 };
            var salt = RandomNumberGenerator.GetBytes(16); var noncePrefix = RandomNumberGenerator.GetBytes(8);
            var manifest = new BackupManifest(1, 1_048_576, 600_000, Convert.ToBase64String(salt), Convert.ToBase64String(noncePrefix), Guid.NewGuid(), DateTimeOffset.UtcNow,
                [new BackupManifestFile("aurelia.db", plaintext.Length, Convert.ToHexString(SHA256.HashData(plaintext)))]);
            var header = JsonSerializer.SerializeToUtf8Bytes(manifest, ApiTestClient.JsonOptions);
            using var encrypted = new MemoryStream(); encrypted.Write("AURBK001"u8);
            var length = new byte[4]; BinaryPrimitives.WriteInt32BigEndian(length, header.Length); encrypted.Write(length); encrypted.Write(header);
            var key = Rfc2898DeriveBytes.Pbkdf2("long backup passphrase", salt, 600_000, HashAlgorithmName.SHA256, 32);
            try
            {
                using var aes = new AesGcm(key, 16); var headerHash = SHA256.HashData(header);
                for (uint index = 0; index < 2; index++)
                {
                    var count = index == 0 ? plaintext.Length : 0;
                    var nonce = new byte[12]; noncePrefix.CopyTo(nonce, 0); BinaryPrimitives.WriteUInt32BigEndian(nonce.AsSpan(8), index);
                    var aad = new byte[40]; headerHash.CopyTo(aad, 0); BinaryPrimitives.WriteUInt32BigEndian(aad.AsSpan(32), index); BinaryPrimitives.WriteInt32BigEndian(aad.AsSpan(36), count);
                    var ciphertext = new byte[count]; var tag = new byte[16];
                    aes.Encrypt(nonce, count == 0 ? [] : plaintext, ciphertext, tag, aad);
                    BinaryPrimitives.WriteInt32BigEndian(length, count); encrypted.Write(length); encrypted.Write(tag); encrypted.Write(ciphertext);
                }
            }
            finally { CryptographicOperations.ZeroMemory(key); }
            encrypted.Position = 0;
            var restored = await EncryptedBackupContainer.DecryptAsync(encrypted, Path.Combine(root, "restore"), "long backup passphrase", CancellationToken.None);
            Assert.Equal(1, restored.Version); Assert.False(restored.IncludesArtwork);
            Assert.Equal(plaintext, await File.ReadAllBytesAsync(Path.Combine(root, "restore", "aurelia.db")));
        }
        finally { Directory.Delete(root, true); }
    }

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
