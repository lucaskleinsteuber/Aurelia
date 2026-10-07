using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class RestoreActivationTests
{
    [Theory]
    [InlineData((int)RestoreActivationStep.JournalWritten, 0)]
    [InlineData((int)RestoreActivationStep.OriginalMoved, 1)]
    [InlineData((int)RestoreActivationStep.OriginalMoved, 150)]
    [InlineData((int)RestoreActivationStep.ReplacementMoved, 1)]
    [InlineData((int)RestoreActivationStep.ReplacementMoved, 150)]
    [InlineData((int)RestoreActivationStep.Verified, 0)]
    public async Task FailedArtworkRichActivationRestoresAllOriginalStateAndCanRestart(int step, int position)
    {
        using var fixture = new RestoreFixture();
        await fixture.SeedAsync();
        using var full = fixture.Service();
        var exported = await full.ExportAsync(RestoreFixture.Passphrase, CancellationToken.None);
        var prepared = await full.PrepareRestoreAsync(new(exported.Id, RestoreFixture.Passphrase, true), CancellationToken.None);
        await fixture.ChangeCurrentStateAsync();
        var before = await fixture.SnapshotAsync();
        await Assert.ThrowsAsync<IOException>(() => FullServerBackupService.ApplyPreparedCoreAsync(
            fixture.Runtime, prepared.Id, CancellationToken.None, (current, count) =>
            {
                if ((int)current == step && count == position) throw new IOException("Synthetic activation interruption.");
            }));
        Assert.False(File.Exists(Path.Combine(fixture.Root, ".full-restore.pending")));
        await fixture.AssertCurrentStateAsync();
        foreach (var (name, bytes) in before)
            Assert.Equal(bytes, await File.ReadAllBytesAsync(Path.Combine(fixture.Root, name)));
        await FullServerBackupService.RecoverInterruptedRestoreAsync(fixture.Runtime, CancellationToken.None);
        using var restarted = new AureliaServerFactory(fixture.Root);
        using var client = restarted.CreateClient();
        Assert.True((await client.GetAsync("/api/v1/server/info")).IsSuccessStatusCode);
        await fixture.AssertCurrentStateAsync();
    }

    [Fact]
    public async Task SuccessfulArtworkRichRestoreRevokesOldSessionAndPreservesImages()
    {
        using var fixture = new RestoreFixture();
        await fixture.SeedAsync();
        using var full = fixture.Service();
        var exported = await full.ExportAsync(RestoreFixture.Passphrase, CancellationToken.None);
        var prepared = await full.PrepareRestoreAsync(new(exported.Id, RestoreFixture.Passphrase, true), CancellationToken.None);
        await fixture.ChangeCurrentStateAsync();
        await FullServerBackupService.ApplyPreparedAsync(fixture.Runtime, prepared.Id, CancellationToken.None);
        await using var database = new AureliaDbContext(fixture.Options);
        Assert.Equal("Original library", (await database.LibraryRoots.SingleAsync()).Name);
        Assert.NotNull((await database.DeviceSessions.SingleAsync()).RevokedAt);
        Assert.Equal(150, await database.ArtworkAssets.CountAsync());
        Assert.Equal(300, Directory.EnumerateFiles(Path.Combine(fixture.Root, "Artwork")).Count());
        Assert.False(File.Exists(Path.Combine(fixture.Root, ".full-restore.pending")));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(175)]
    [InlineData(302)]
    public async Task StartupRecoversPartiallyMovedLargeJournalIdempotently(int originalsMoved)
    {
        var root = TestPaths.CreateDataDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(root);
        var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", root]);
        try
        {
            var id = Guid.NewGuid();
            var undo = Path.Combine(root, "Backups", ".restore-undo-" + id.ToString("N"));
            PrivateFilePermissions.CreatePrivateDirectory(Path.Combine(root, "Artwork"));
            PrivateFilePermissions.CreatePrivateDirectory(Path.Combine(undo, "Artwork"));
            var names = Enumerable.Range(0, 302).Select(_ => "Artwork/" + Guid.NewGuid().ToString("N") + ".png").ToArray();
            foreach (var name in names) await File.WriteAllBytesAsync(Path.Combine(root, name), [1, 2, 3]);
            foreach (var name in names.Take(originalsMoved))
            {
                File.Move(Path.Combine(root, name), Path.Combine(undo, name));
                await File.WriteAllBytesAsync(Path.Combine(root, name), [4, 5]);
            }
            var newName = "Artwork/" + Guid.NewGuid().ToString("N") + ".png";
            await File.WriteAllBytesAsync(Path.Combine(root, newName), [6]);
            await File.WriteAllTextAsync(Path.Combine(root, ".full-restore.pending"), JsonSerializer.Serialize(
                new RestoreActivationJournal(1, id, names, [.. names, newName]), ApiTestClient.JsonOptions));
            await FullServerBackupService.RecoverInterruptedRestoreAsync(runtime, CancellationToken.None);
            await FullServerBackupService.RecoverInterruptedRestoreAsync(runtime, CancellationToken.None);
            Assert.False(File.Exists(Path.Combine(root, newName)));
            foreach (var name in names) Assert.Equal(new byte[] { 1, 2, 3 }, await File.ReadAllBytesAsync(Path.Combine(root, name)));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task DuplicateOrOversizedJournalCannotChangeActiveFiles()
    {
        var root = TestPaths.CreateDataDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(root);
        var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", root]);
        try
        {
            var marker = Path.Combine(root, ".full-restore.pending");
            var sentinel = Path.Combine(root, ServerHostSettings.FileName);
            await File.WriteAllBytesAsync(sentinel, [1, 2]);
            foreach (var entries in new[] { new[] { ServerHostSettings.FileName, ServerHostSettings.FileName },
                Enumerable.Repeat(ServerHostSettings.FileName, EncryptedBackupContainer.MaximumEntries + 3).ToArray() })
            {
                await File.WriteAllTextAsync(marker, JsonSerializer.Serialize(
                    new RestoreActivationJournal(1, Guid.NewGuid(), entries, []), ApiTestClient.JsonOptions));
                await Assert.ThrowsAsync<InvalidDataException>(() => FullServerBackupService.RecoverInterruptedRestoreAsync(runtime, CancellationToken.None));
                Assert.Equal(new byte[] { 1, 2 }, await File.ReadAllBytesAsync(sentinel));
            }
        }
        finally { Directory.Delete(root, true); }
    }

    private sealed class RestoreFixture : IDisposable
    {
        public const string Passphrase = "synthetic activation test passphrase";
        public string Root { get; } = TestPaths.CreateDataDirectory();
        public ServerRuntimeOptions Runtime { get; }
        public DbContextOptions<AureliaDbContext> Options { get; }
        public RestoreFixture()
        {
            PrivateFilePermissions.CreatePrivateDirectory(Root);
            Runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", Root]);
            Options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={Runtime.DatabasePath};Pooling=False").Options;
        }
        public FullServerBackupService Service()
        {
            var configuration = new ServerConfigurationStore(Runtime);
            configuration.Update(configuration.Current);
            return new(Runtime, new DatabaseBackupService(Runtime, configuration), configuration);
        }
        public async Task SeedAsync()
        {
            await using var database = new AureliaDbContext(Options);
            await database.Database.MigrateAsync();
            var now = DateTimeOffset.UtcNow;
            var owner = new ServerUser { Id = Guid.NewGuid(), Username = "owner", NormalizedUsername = "OWNER", PasswordHash = "synthetic test hash", Role = UserRole.Owner, CreatedAt = now };
            var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Original library", Path = Path.Combine(Root, "SyntheticMedia"), NormalizedPath = Path.Combine(Root, "SyntheticMedia"), Kind = LibraryKind.Movies, CreatedAt = now };
            Directory.CreateDirectory(library.Path);
            database.ServerIdentities.Add(new ServerIdentity { Id = 1, ServerId = Guid.NewGuid(), CreatedAt = now });
            database.Users.Add(owner); database.LibraryRoots.Add(library);
            database.DeviceSessions.Add(new DeviceSession { Id = Guid.NewGuid(), User = owner, UserId = owner.Id, DeviceName = "synthetic device", TokenHash = new string('a', 64), CreatedAt = now, LastSeenAt = now, ExpiresAt = now.AddDays(90) });
            var artwork = Path.Combine(Root, "Artwork"); PrivateFilePermissions.CreatePrivateDirectory(artwork);
            var bytes = MediaEditingTests.Png(12, 18);
            for (var index = 0; index < 150; index++)
            {
                var media = Guid.NewGuid(); var asset = Guid.NewGuid();
                var metadata = new MediaMetadata { MediaItemId = media, ManualFieldsJson = "[\"poster\"]", ManualPosterId = asset, UpdatedAt = now };
                metadata.Artwork.Add(new ArtworkAsset { Id = asset, MediaItemId = media, Kind = ArtworkKind.Poster, IsManual = true, ProviderPath = "manual/" + asset.ToString("N"), RelativeFilePath = asset.ToString("N") + ".png", OriginalFilePath = asset.ToString("N") + ".original.png", ContentType = "image/png", ContentLength = bytes.Length, CreatedAt = now });
                var path = Path.Combine(library.Path, index + ".mkv");
                database.MediaItems.Add(new MediaItem { Id = media, LibraryRootId = library.Id, Kind = MediaKind.Movie, DetectedTitle = "Synthetic " + index, SourcePath = path, NormalizedSourcePath = MediaPath.Normalize(path), Metadata = metadata, CreatedAt = now, UpdatedAt = now });
                await File.WriteAllBytesAsync(Path.Combine(artwork, asset.ToString("N") + ".png"), bytes);
                await File.WriteAllBytesAsync(Path.Combine(artwork, asset.ToString("N") + ".original.png"), bytes);
            }
            await database.SaveChangesAsync();
        }
        public async Task ChangeCurrentStateAsync()
        {
            await using var database = new AureliaDbContext(Options);
            (await database.LibraryRoots.SingleAsync()).Name = "Current library";
            await database.SaveChangesAsync();
            foreach (var path in Directory.EnumerateFiles(Path.Combine(Root, "Artwork"))) await File.WriteAllBytesAsync(path, [7, 8, 9]);
        }
        public async Task AssertCurrentStateAsync()
        {
            await using var database = new AureliaDbContext(Options);
            Assert.Equal("Current library", (await database.LibraryRoots.SingleAsync()).Name);
            Assert.Null((await database.DeviceSessions.SingleAsync()).RevokedAt);
        }
        public async Task<Dictionary<string, byte[]>> SnapshotAsync()
        {
            var result = new Dictionary<string, byte[]>();
            foreach (var path in Directory.EnumerateFiles(Path.Combine(Root, "Artwork")))
                result[Path.GetRelativePath(Root, path)] = await File.ReadAllBytesAsync(path);
            result[ServerHostSettings.FileName] = await File.ReadAllBytesAsync(Path.Combine(Root, ServerHostSettings.FileName));
            return result;
        }
        public void Dispose() { SqliteConnection.ClearAllPools(); if (Directory.Exists(Root)) Directory.Delete(Root, true); }
    }
}
