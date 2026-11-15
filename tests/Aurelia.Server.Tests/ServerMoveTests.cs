using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Endpoints;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// Moving a whole server (docs/SERVER_MOVE.md) between two in-process servers with synthetic data:
/// the old server's code rules, both ways of moving, the new server's setup-time import, Storage
/// Location Moved and a moved server's answers. Synthetic media files are only ever stat-ed.
/// </summary>
public sealed class ServerMoveTests
{
    private const string Password = "correct horse battery staple";
    private const string MovePassphrase = "a long synthetic moving passphrase";

    [Fact]
    public void MoveCodesNormalizeAndProofsBindTheObservedKey()
    {
        var code = ServerMoveCrypto.NewCode();
        Assert.Equal(12, code.Length);
        Assert.Matches("^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$", ServerMoveCrypto.Display(code));
        Assert.Equal("01AB11CD0123", ServerMoveCrypto.Normalize("oiab-lIcd 0123"));
        Assert.Equal(code, ServerMoveCrypto.Normalize(ServerMoveCrypto.Display(code).ToLowerInvariant()));
        Assert.Null(ServerMoveCrypto.Normalize("ABCD-EFGH-JKM"));
        Assert.Null(ServerMoveCrypto.Normalize("ABCD-EFGH-JKMU"));
        var nonce = RandomNumberGenerator.GetBytes(32);
        var clientNonce = RandomNumberGenerator.GetBytes(32);
        var spki = RandomNumberGenerator.GetBytes(32);
        var other = RandomNumberGenerator.GetBytes(32);
        Assert.Equal(ServerMoveCrypto.Proof(code, nonce, clientNonce, spki), ServerMoveCrypto.Proof(code, nonce, clientNonce, spki));
        Assert.NotEqual(ServerMoveCrypto.Proof(code, nonce, clientNonce, spki), ServerMoveCrypto.Proof(code, nonce, clientNonce, other));
        Assert.NotEqual(ServerMoveCrypto.BundleKey(code, nonce, clientNonce, spki), ServerMoveCrypto.BundleKey(code, nonce, clientNonce, other));
        Assert.Equal(32, ServerMoveCrypto.BundleKey(code, nonce, clientNonce, spki).Length);
        Assert.Null(ServerMoveCrypto.DecodeNonce(Convert.ToBase64String(new byte[16])));
        Assert.Equal(new Uri("https://192.168.1.20:43111/"), ServerMoveTransport.ParseAddress("192.168.1.20"));
        Assert.Equal(new Uri("https://server.local:443/"), ServerMoveTransport.ParseAddress("server.local:443"));
        Assert.Null(ServerMoveTransport.ParseAddress("http://192.168.1.20"));
        Assert.Null(ServerMoveTransport.ParseAddress("https://user:secret@server.local"));
        Assert.Null(ServerMoveTransport.ParseAddress("https://server.local/path"));
    }

    [Fact]
    public void ReissuedCertificateKeepsThePinnedKeyAndMoveCommandsParse()
    {
        var root = TestPaths.CreateDataDirectory();
        try
        {
            PrivateFilePermissions.CreatePrivateDirectory(root);
            var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", root, "--lan"]);
            string fingerprint;
            string thumbprint;
            using (var identity = ServerTlsIdentity.LoadOrCreate(runtime))
            {
                fingerprint = identity.PublicKeyFingerprint!;
                thumbprint = identity.Certificate!.Thumbprint;
                Assert.Equal(fingerprint, Convert.ToHexString(ServerMoveCrypto.SpkiSha256(identity.Certificate)));
            }
            Assert.True(ServerTlsIdentity.ReissueForThisComputer(runtime));
            using (var renewed = ServerTlsIdentity.LoadOrCreate(runtime))
            {
                Assert.Equal(fingerprint, renewed.PublicKeyFingerprint);
                Assert.NotEqual(thumbprint, renewed.Certificate!.Thumbprint);
            }
        }
        finally { Directory.Delete(root, true); }

        var export = ServerCommandLine.Parse(["move", "export", "/media/usb/old.aureliamove", "--username", "owner"]);
        Assert.Equal("move", export.Command);
        Assert.Equal("export", export.Action);
        Assert.Equal(["/media/usb/old.aureliamove"], export.Positionals);
        Assert.Equal("owner", export.Username);
        Assert.Empty(ServerCommandLine.Parse(["move", "status"]).Positionals);
    }

    [Fact]
    public void MovedServerAnswersOnlyWhatFindsTheNewOneAndUndoesTheMove()
    {
        var id = Guid.NewGuid();
        Assert.True(ServerMoveGuard.Allowed("GET", "/api/v1/server/info"));
        Assert.True(ServerMoveGuard.Allowed("GET", "/api/v1/server/move"));
        Assert.True(ServerMoveGuard.Allowed("DELETE", "/api/v1/server/move/"));
        Assert.True(ServerMoveGuard.Allowed("POST", "/api/v1/move/arrived"));
        Assert.True(ServerMoveGuard.Allowed("POST", "/api/v1/server/approval"));
        Assert.True(ServerMoveGuard.Allowed("POST", $"/api/v1/profiles/{id}/unlock"));
        Assert.True(ServerMoveGuard.Allowed("POST", $"/api/v1/web/profiles/{id}/unlock"));
        Assert.False(ServerMoveGuard.Allowed("POST", "/api/v1/server/move"));
        Assert.False(ServerMoveGuard.Allowed("POST", "/api/v1/server/move/mark-moved"));
        Assert.False(ServerMoveGuard.Allowed("GET", "/api/v1/move/hello"));
        Assert.False(ServerMoveGuard.Allowed("GET", "/api/v1/catalog/movies"));
        Assert.False(ServerMoveGuard.Allowed("POST", $"/api/v1/profiles/{id}/initialize"));
        Assert.False(ServerMoveGuard.Allowed("GET", $"/api/v1/profiles/{id}/picture"));
        Assert.False(ServerMoveGuard.Allowed("GET", "/api/v1/sync/changes"));
    }

    [Fact]
    public async Task SuggestionsFindTheFolderThatHoldsTheSameFiles()
    {
        var root = TestPaths.CreateDataDirectory();
        try
        {
            var samples = new List<MoveSample>();
            var moved = Path.Combine(root, "disk2", "Media", "Movies");
            var decoy = Path.Combine(root, "backup", "Movies");
            for (var index = 0; index < 6; index++)
            {
                var relative = $"Film {index} (200{index})/Film {index}.mkv";
                samples.Add(new(relative, 4096 + index));
                await WriteSyntheticAsync(Path.Combine(moved, relative), 4096 + index);
                // Same names, other sizes: only one of them counts there.
                await WriteSyntheticAsync(Path.Combine(decoy, relative), index == 0 ? 4096 : 10);
            }
            var before = Snapshot(root);
            var found = ServerMoveLocations.Suggest(samples, "/old-computer/Movies", [root], TimeSpan.FromSeconds(10), CancellationToken.None);
            Assert.Equal(moved, found[0].Path);
            Assert.Equal(6, found[0].Matched);
            Assert.Contains(found, suggestion => suggestion.Path == decoy && suggestion.Matched == 1);
            Assert.Equal(6, ServerMoveLocations.CountMatches(moved, samples));
            Assert.Equal(0, ServerMoveLocations.CountMatches(root, samples));
            Assert.Equal(before, Snapshot(root));
            Assert.Equal("Film 1 (2001)/Film 1.mkv", ServerMoveLocations.Relative("/old/Movies/", "/old/Movies/Film 1 (2001)/Film 1.mkv"));
            Assert.Null(ServerMoveLocations.Relative("/old/Movies", "/old/Movies2/x.mkv"));
            Assert.False(ServerMoveLocations.SafeRelative("../etc/passwd"));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task RewritingPathsMovesTitlesBindingsAndExclusionsAndClearsTheirIdentities()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var databasePath = Path.Combine(root, "aurelia.db");
        var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={databasePath};Pooling=False").Options;
        var movies = Guid.NewGuid();
        var series = Guid.NewGuid();
        var swappedA = Guid.NewGuid();
        var swappedB = Guid.NewGuid();
        var film = Guid.NewGuid();
        var bound = Guid.NewGuid();
        var episode = Guid.NewGuid();
        try
        {
            await using (var database = new AureliaDbContext(options))
            {
                await database.Database.MigrateAsync();
                database.ServerIdentities.Add(new ServerIdentity { Id = 1, ServerId = Guid.NewGuid(), CreatedAt = DateTimeOffset.UtcNow });
                database.LibraryRoots.AddRange(
                    Root(movies, "Movies", "/old/Movies"), Root(series, "Series", "/old/Series"),
                    Root(swappedA, "A", "/old/A"), Root(swappedB, "B", "/old/B"));
                database.MediaItems.AddRange(
                    Item(film, movies, "/old/Movies/Film (2001)/Film.mkv", "1:2"),
                    Item(bound, movies, "/old/Movies/Other/chosen by hand.mkv", "1:3", manual: true),
                    Item(episode, series, "/old/Series/Show/S01E01.mkv", "1:4", MediaKind.Episode),
                    Item(Guid.NewGuid(), swappedA, "/old/A/a.mkv", null), Item(Guid.NewGuid(), swappedB, "/old/B/b.mkv", null));
                database.MediaExclusions.Add(new MediaExclusion
                {
                    Id = Guid.NewGuid(),
                    LibraryRootId = movies,
                    RelativePath = "Film (2001)/sample.mkv",
                    NormalizedSourcePath = MediaPath.Normalize("/old/Movies/Film (2001)/sample.mkv"),
                    FileSystemIdentity = "1:9",
                });
                await database.SaveChangesAsync();
            }
            await using (var connection = new SqliteConnection($"Data Source={databasePath};Pooling=False"))
            {
                await connection.OpenAsync();
                await using var transaction = await connection.BeginTransactionAsync();
                var changed = await ServerMoveLocations.RewriteAsync(connection, transaction,
                    [new(movies, "/new/disk/Movies"), new(series, null), new(swappedA, "/old/B"), new(swappedB, "/old/A")], renormalizeAll: true, CancellationToken.None);
                await transaction.CommitAsync();
                Assert.Equal(4, changed.Count);
                Assert.Contains(film, changed);
                Assert.Contains(bound, changed);
                Assert.DoesNotContain(episode, changed);
            }
            await using (var database = new AureliaDbContext(options))
            {
                var library = await database.LibraryRoots.SingleAsync(candidate => candidate.Id == movies);
                Assert.Equal("/new/disk/Movies", library.Path);
                Assert.Equal(MediaPath.Normalize("/new/disk/Movies"), library.NormalizedPath);
                Assert.Equal(1, library.ImportAssignmentRevision);
                Assert.Equal("/old/Series", (await database.LibraryRoots.SingleAsync(candidate => candidate.Id == series)).Path);
                Assert.Equal("/old/B", (await database.LibraryRoots.SingleAsync(candidate => candidate.Id == swappedA)).Path);
                var moved = await database.MediaItems.IgnoreQueryFilters().SingleAsync(item => item.Id == film);
                Assert.Equal(Path.Join("/new/disk/Movies", "Film (2001)", "Film.mkv"), moved.SourcePath);
                Assert.Equal(MediaPath.Normalize(moved.SourcePath), moved.NormalizedSourcePath);
                Assert.Null(moved.FileSystemIdentity);
                var manual = await database.MediaItems.IgnoreQueryFilters().SingleAsync(item => item.Id == bound);
                Assert.True(manual.ManualSourceBinding);
                Assert.Equal(Path.Join("/new/disk/Movies", "Other", "chosen by hand.mkv"), manual.SourcePath);
                Assert.Null(manual.FileSystemIdentity);
                var kept = await database.MediaItems.IgnoreQueryFilters().SingleAsync(item => item.Id == episode);
                Assert.Equal("/old/Series/Show/S01E01.mkv", kept.SourcePath);
                Assert.Equal("1:4", kept.FileSystemIdentity);
                var exclusion = await database.MediaExclusions.SingleAsync();
                Assert.Equal(MediaPath.Normalize(Path.Join("/new/disk/Movies", "Film (2001)", "sample.mkv")), exclusion.NormalizedSourcePath);
                Assert.Null(exclusion.FileSystemIdentity);
            }
            await using (var connection = new SqliteConnection($"Data Source={databasePath};Pooling=False"))
            {
                await connection.OpenAsync();
                await using var transaction = await connection.BeginTransactionAsync();
                var overlap = await Assert.ThrowsAsync<AccountException>(() => ServerMoveLocations.RewriteAsync(connection, transaction,
                    [new(series, "/new/disk/Movies/Series")], renormalizeAll: false, CancellationToken.None));
                Assert.Equal("locations_overlap", overlap.Code);
            }
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    [Fact]
    public async Task MoveBundleKeepsEveryDeviceSignedInWhileARestoreSignsThemOut()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", root]);
        var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={runtime.DatabasePath};Pooling=False").Options;
        var serverId = Guid.NewGuid();
        try
        {
            await using (var database = new AureliaDbContext(options))
            {
                await database.Database.MigrateAsync();
                database.ServerIdentities.Add(new ServerIdentity { Id = 1, ServerId = serverId, CreatedAt = DateTimeOffset.UtcNow });
                var user = new ServerUser { Id = Guid.NewGuid(), Username = "owner", NormalizedUsername = "OWNER", PasswordHash = "synthetic hash", Role = UserRole.Owner, CreatedAt = DateTimeOffset.UtcNow };
                database.Users.Add(user);
                database.DeviceSessions.Add(new DeviceSession { Id = Guid.NewGuid(), UserId = user.Id, User = user, DeviceName = "synthetic TV", TokenHash = new string('b', 64), CreatedAt = DateTimeOffset.UtcNow, LastSeenAt = DateTimeOffset.UtcNow, ExpiresAt = DateTimeOffset.UtcNow.AddDays(90) });
                await database.SaveChangesAsync();
            }
            var configuration = new ServerConfigurationStore(runtime);
            var backups = new DatabaseBackupService(runtime, configuration);
            using var full = new FullServerBackupService(runtime, backups, configuration);
            var manifest = new MoveManifest(1, serverId, "Synthetic", "synthetic-move-token", [], []);
            var key = RandomNumberGenerator.GetBytes(32);
            var bundle = await full.ExportMoveAsync((stage, names, id, stream, token) =>
                EncryptedBackupContainer.EncryptWithKeyAsync(stage, names, id, stream, key, token),
                (_, _) => Task.FromResult(ServerMoveLocations.Serialize(manifest)), CancellationToken.None);
            // A move bundle never opens with a passphrase, and never without its key.
            await using (var source = File.OpenRead(full.TransferPath(bundle.Id)))
                await Assert.ThrowsAsync<InvalidDataException>(() => EncryptedBackupContainer.DecryptAsync(source, Path.Combine(root, "wrong"), MovePassphrase, CancellationToken.None));
            await using (var source = File.OpenRead(full.TransferPath(bundle.Id)))
                await Assert.ThrowsAnyAsync<Exception>(() => EncryptedBackupContainer.DecryptWithKeyAsync(source, Path.Combine(root, "wrong-key"), RandomNumberGenerator.GetBytes(32), CancellationToken.None));
            var prepared = await full.PrepareMoveAsync(bundle.Id, (source, stage, token) =>
                EncryptedBackupContainer.DecryptWithKeyAsync(source, stage, key, token), CancellationToken.None);
            Assert.True(prepared.KeepsSessions);
            Assert.False(prepared.RevokesAllSessions);
            Assert.True(File.Exists(Path.Combine(full.RestoreStagePath(prepared.Id), EncryptedBackupContainer.MoveManifestName)));
            Assert.Equal("synthetic-move-token", ServerMoveLocations.Parse(Path.Combine(full.RestoreStagePath(prepared.Id), EncryptedBackupContainer.MoveManifestName)).MoveToken);
            using (ServerInstanceLock.Acquire(root)) await FullServerBackupService.ApplyPreparedAsync(runtime, prepared.Id, CancellationToken.None);
            Assert.False(File.Exists(Path.Combine(root, EncryptedBackupContainer.MoveManifestName)));
            await using (var database = new AureliaDbContext(options))
                Assert.Null((await database.DeviceSessions.SingleAsync()).RevokedAt);

            var restore = await full.ExportAsync(MovePassphrase, CancellationToken.None);
            var restored = await full.PrepareRestoreAsync(new(restore.Id, MovePassphrase, true), CancellationToken.None);
            using (ServerInstanceLock.Acquire(root)) await FullServerBackupService.ApplyPreparedAsync(runtime, restored.Id, CancellationToken.None);
            await using (var database = new AureliaDbContext(options))
                Assert.NotNull((await database.DeviceSessions.SingleAsync()).RevokedAt);
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    [Fact]
    public async Task MoveCodeExpiresAndFiveWrongProofsEndIt()
    {
        var clock = new MoveClock();
        using var old = OldServer(services => { services.RemoveAll<TimeProvider>(); services.AddSingleton<TimeProvider>(clock); });
        using var client = Https(old);
        var owner = await ApiTestClient.SetupOwnerAsync(client, password: Password);
        using (var hello = await client.GetAsync("/api/v1/move/hello"))
            await AssertProblemAsync(hello, HttpStatusCode.NotFound, "move_not_waiting");
        using (var claim = await client.PostAsJsonAsync("/api/v1/move/claim", new MoveClaimRequest(Nonce(), Nonce(), Nonce())))
            await AssertProblemAsync(claim, HttpStatusCode.NotFound, "move_not_waiting");
        using (var plain = old.CreateClient())
        using (var insecure = await plain.GetAsync("/api/v1/move/hello"))
            await AssertProblemAsync(insecure, HttpStatusCode.Forbidden, "https_required");

        var started = await StartMoveAsync(client, owner, new StartServerMoveRequest("network"));
        Assert.Equal(clock.GetUtcNow().Add(ServerMoveService.CodeLifetime), started.ExpiresAt);
        clock.Advance(TimeSpan.FromMinutes(16));
        using (var hello = await client.GetAsync("/api/v1/move/hello"))
            await AssertProblemAsync(hello, HttpStatusCode.NotFound, "move_not_waiting");
        Assert.Equal("none", (await StatusAsync(client, owner)).State);
        // The Server Password unlock lasts ten minutes, so the owner unlocks again.
        using (var unlock = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/unlock", owner.Token, new UnlockManagementRequest(Password)))
        using (var unlocked = await client.SendAsync(unlock))
            unlocked.EnsureSuccessStatusCode();

        started = await StartMoveAsync(client, owner, new StartServerMoveRequest("network"));
        var code = ServerMoveCrypto.Normalize(started.Code)!;
        var spki = Convert.FromHexString(old.Services.GetRequiredService<ServerTlsIdentity>().PublicKeyFingerprint!);
        MoveHelloResponse greeting;
        using (var hello = await client.GetAsync("/api/v1/move/hello"))
            greeting = await ApiTestClient.ReadAsync<MoveHelloResponse>(hello);
        var nonce = Convert.FromBase64String(greeting.Nonce);
        // A machine in the middle shows its own key: the proof names that key and fails.
        for (var attempt = 1; attempt <= ServerMoveService.MaximumProofAttempts; attempt++)
        {
            var clientNonce = RandomNumberGenerator.GetBytes(32);
            var proof = ServerMoveCrypto.Proof(code, nonce, clientNonce, RandomNumberGenerator.GetBytes(32));
            using var claim = await client.PostAsJsonAsync("/api/v1/move/claim", new MoveClaimRequest(greeting.Nonce, Convert.ToBase64String(clientNonce), Convert.ToBase64String(proof)));
            await AssertProblemAsync(claim, HttpStatusCode.Forbidden, attempt < ServerMoveService.MaximumProofAttempts ? "move_proof_invalid" : "move_ended");
        }
        // Even the right proof is too late now.
        var lateNonce = RandomNumberGenerator.GetBytes(32);
        using (var late = await client.PostAsJsonAsync("/api/v1/move/claim", new MoveClaimRequest(greeting.Nonce, Convert.ToBase64String(lateNonce),
            Convert.ToBase64String(ServerMoveCrypto.Proof(code, nonce, lateNonce, spki)))))
            await AssertProblemAsync(late, HttpStatusCode.NotFound, "move_not_waiting");
        Assert.Equal("none", (await StatusAsync(client, owner)).State);

        // A moving file waits for its file, not for a network claim.
        var file = await StartMoveAsync(client, owner, new StartServerMoveRequest("file", MovePassphrase));
        Assert.Equal("waiting", file.State);
        Assert.NotNull(file.TransferId);
        using (var hello = await client.GetAsync("/api/v1/move/hello"))
            await AssertProblemAsync(hello, HttpStatusCode.NotFound, "move_not_waiting");
        using (var cancel = ApiTestClient.Authorized(HttpMethod.Delete, "/api/v1/server/move", owner.Token))
        using (var cancelled = await ApiTestClient.SendAsync(client, cancel))
            Assert.Equal("none", (await ApiTestClient.ReadAsync<ServerMoveStatus>(cancelled)).State);
        Assert.False(File.Exists(old.Services.GetRequiredService<FullServerBackupService>().TransferPath(file.TransferId!.Value)));

        // Starting a move needs the Server Password's approval like a restore.
        using var unapproved = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/move", owner.Token, new StartServerMoveRequest("network"));
        using var refused = await client.SendAsync(unapproved);
        await AssertProblemAsync(refused, HttpStatusCode.Forbidden, "approval_required");
    }

    [Fact]
    public async Task SetupMoveNeedsTheSetupCodeOrAnAppHostsTokenAndNoOwner()
    {
        using var fresh = NewServer(null, new InProcessTransport(() => throw new HttpRequestException("unreachable"), () => new byte[32]));
        using var client = fresh.CreateClient();
        using (var missing = await client.GetAsync("/api/v1/setup/move"))
            await AssertProblemAsync(missing, HttpStatusCode.Forbidden, "setup_code_invalid");
        using (var wrong = Setup(HttpMethod.Get, "/api/v1/setup/move", "WRONG-CODE0"))
        using (var refused = await client.SendAsync(wrong))
            await AssertProblemAsync(refused, HttpStatusCode.Forbidden, "setup_code_invalid");
        var code = fresh.Services.GetRequiredService<BrowserSetup>().Current();
        using (var right = Setup(HttpMethod.Get, "/api/v1/setup/move", BrowserSetup.Display(code)))
        using (var status = await client.SendAsync(right))
            Assert.Equal("idle", (await ApiTestClient.ReadAsync<SetupMoveStatus>(status)).State);
        using (var host = new HttpRequestMessage(HttpMethod.Get, "/api/v1/setup/move"))
        {
            host.Headers.Add(BootstrapSetupAuthorizer.HeaderName, ApiTestClient.BootstrapToken);
            using var status = await client.SendAsync(host);
            Assert.Equal(HttpStatusCode.OK, status.StatusCode);
        }
        using (var badHost = new HttpRequestMessage(HttpMethod.Get, "/api/v1/setup/move"))
        {
            badHost.Headers.Add(BootstrapSetupAuthorizer.HeaderName, "not-the-token");
            using var status = await client.SendAsync(badHost);
            await AssertProblemAsync(status, HttpStatusCode.Forbidden, "bootstrap_required");
        }
        using (var invalid = Setup(HttpMethod.Post, "/api/v1/setup/move/network", code, new SetupMoveNetworkRequest("192.168.1.20", "ABCD")))
        using (var answer = await client.SendAsync(invalid))
            await AssertProblemAsync(answer, HttpStatusCode.BadRequest, "move_code_invalid");
        using (var unreachable = Setup(HttpMethod.Post, "/api/v1/setup/move/network", code, new SetupMoveNetworkRequest("192.168.1.20", "ABCD-EFGH-JKMN")))
        using (var answer = await client.SendAsync(unreachable))
            await AssertProblemAsync(answer, HttpStatusCode.BadGateway, "move_source_unreachable");
        using (var finish = Setup(HttpMethod.Post, "/api/v1/setup/move/finish", code, new SetupMoveFinishRequest([])))
        using (var answer = await client.SendAsync(finish))
            await AssertProblemAsync(answer, HttpStatusCode.Conflict, "move_not_received");

        await ApiTestClient.SetupOwnerAsync(client, password: Password);
        using (var after = Setup(HttpMethod.Get, "/api/v1/setup/move", code))
        using (var refused = await client.SendAsync(after))
            await AssertProblemAsync(refused, HttpStatusCode.Conflict, "server_already_setup");
        using (var file = new HttpRequestMessage(HttpMethod.Put, "/api/v1/setup/move/file") { Content = new ByteArrayContent(new byte[64]) })
        {
            file.Headers.Add(ServerMoveEndpoints.SetupCodeHeader, code);
            using var refused = await client.SendAsync(file);
            await AssertProblemAsync(refused, HttpStatusCode.Conflict, "server_already_setup");
        }
    }

    [Fact]
    public async Task NetworkMoveArrivesWithIdentitySessionsAndChosenFoldersAndTheOldServerStepsAside()
    {
        var workspace = TestPaths.CreateDataDirectory();
        var newData = Path.Combine(workspace, "new-server");
        Directory.CreateDirectory(newData);
        var newMedia = Path.Combine(workspace, "disk2", "Media");
        try
        {
            using var old = OldServer();
            using var oldClient = Https(old);
            var (deviceToken, owner) = await SetupOwnerWithDeviceAsync(oldClient);
            var seeded = await SeedLibraryAsync(old, "/old-computer/media/Movies", "/old-computer/media/Series", newMedia);
            var mediaBefore = Snapshot(workspace);
            var oldId = (await InfoAsync(oldClient)).ServerId;
            var started = await StartMoveAsync(oldClient, owner, new StartServerMoveRequest("network"));
            Assert.Equal("waiting", (await StatusAsync(oldClient, owner)).State);

            var oldSpki = Convert.FromHexString(old.Services.GetRequiredService<ServerTlsIdentity>().PublicKeyFingerprint!);
            var transport = new InProcessTransport(old.Server.CreateHandler, () => oldSpki);
            var applier = new RecordingApplier();
            Guid restoreId;
            using (var fresh = NewServer(newData, transport, applier, [workspace]))
            {
                using var client = fresh.CreateClient();
                var code = fresh.Services.GetRequiredService<BrowserSetup>().Current();
                using (var start = Setup(HttpMethod.Post, "/api/v1/setup/move/network", code, new SetupMoveNetworkRequest("old.test", started.Code)))
                using (var answer = await client.SendAsync(start))
                {
                    Assert.Equal(HttpStatusCode.OK, answer.StatusCode);
                    var fetching = await ApiTestClient.ReadAsync<SetupMoveStatus>(answer);
                    Assert.Equal(oldId, fetching.Source?.ServerId);
                }
                var status = await WaitForSetupAsync(client, code, "received");
                Assert.Equal(2, status.Locations.Count);
                var movies = status.Locations.Single(location => location.Id == seeded.Movies);
                Assert.Equal("/old-computer/media/Movies", movies.OldPath);
                Assert.Equal(3, movies.Sampled);
                Assert.Contains(movies.Suggestions, suggestion => suggestion.Path == Path.Combine(newMedia, "Movies") && suggestion.Matched == 3);
                Assert.Equal("transferring", (await StatusAsync(oldClient, owner)).State);

                using (var preview = Setup(HttpMethod.Post, "/api/v1/setup/move/locations/preview", code, new SetupMovePreviewRequest(seeded.Movies, Path.Combine(newMedia, "Movies"))))
                using (var answer = await client.SendAsync(preview))
                    Assert.Equal(new MoveLocationMatch(3, 3), await ApiTestClient.ReadAsync<MoveLocationMatch>(answer));
                using (var preview = Setup(HttpMethod.Post, "/api/v1/setup/move/locations/preview", code, new SetupMovePreviewRequest(seeded.Movies, workspace)))
                using (var answer = await client.SendAsync(preview))
                    Assert.Equal(new MoveLocationMatch(3, 0), await ApiTestClient.ReadAsync<MoveLocationMatch>(answer));

                using (var finish = Setup(HttpMethod.Post, "/api/v1/setup/move/finish", code,
                    new SetupMoveFinishRequest([new(seeded.Movies, Path.Combine(newMedia, "Movies")), new(seeded.Series, null)])))
                using (var answer = await client.SendAsync(finish))
                    Assert.Equal("done", (await ApiTestClient.ReadAsync<SetupMoveStatus>(answer)).State);
                restoreId = Assert.Single(applier.Applied);
                var arrival = ServerMoveArrival.Read(newData);
                Assert.NotNull(arrival);
                Assert.Equal(oldId, arrival.ServerId);
                Assert.Contains("https://old.test:43111", arrival.Addresses);

                // The staged database already points at this computer's folders.
                var stage = fresh.Services.GetRequiredService<FullServerBackupService>().RestoreStagePath(restoreId);
                await AssertStagedPathsAsync(Path.Combine(stage, "aurelia.db"), seeded, Path.Combine(newMedia, "Movies"));
            }

            // What the host does next: apply the staged data and start the server again.
            SqliteConnection.ClearAllPools();
            var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", newData]);
            using (ServerInstanceLock.Acquire(newData)) await FullServerBackupService.ApplyPreparedAsync(runtime, restoreId, CancellationToken.None);
            using (var moved = NewServer(newData, transport))
            {
                using var client = Https(moved);
                var info = await InfoAsync(client);
                Assert.Equal(oldId, info.ServerId);
                Assert.True(info.IsSetup);
                Assert.Equal(Convert.ToHexString(oldSpki), moved.Services.GetRequiredService<ServerTlsIdentity>().PublicKeyFingerprint);
                // The old device credential works here: devices stay signed in.
                using (var profiles = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/profiles", deviceToken))
                using (var answer = await client.SendAsync(profiles))
                    Assert.Equal(HttpStatusCode.OK, answer.StatusCode);
                await using (var scope = moved.Services.CreateAsyncScope())
                {
                    var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                    Assert.Equal(Path.Combine(newMedia, "Movies"), (await database.LibraryRoots.SingleAsync(root => root.Id == seeded.Movies)).Path);
                    Assert.Equal("/old-computer/media/Series", (await database.LibraryRoots.SingleAsync(root => root.Id == seeded.Series)).Path);
                }
                using (var setup = Setup(HttpMethod.Get, "/api/v1/setup/move", "ANYCODE000"))
                using (var refused = await client.SendAsync(setup))
                    await AssertProblemAsync(refused, HttpStatusCode.Conflict, "server_already_setup");

                // The new server reports its arrival; the old one steps aside.
                var oldStatus = await WaitForOldAsync(oldClient, owner, "moved");
                Assert.Equal(oldId, oldStatus.MovedTo?.ServerId);
                var deadline = DateTime.UtcNow.AddSeconds(10);
                while (ServerMoveArrival.Read(newData) is not null && DateTime.UtcNow < deadline) await Task.Delay(50);
                Assert.Null(ServerMoveArrival.Read(newData));
            }

            using (var catalog = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/catalog/movies", owner.Token))
            using (var answer = await oldClient.SendAsync(catalog))
            {
                Assert.Equal(HttpStatusCode.Conflict, answer.StatusCode);
                using var problem = JsonDocument.Parse(await answer.Content.ReadAsStringAsync());
                Assert.Equal("server_moved", problem.RootElement.GetProperty("code").GetString());
                Assert.Equal(oldId, problem.RootElement.GetProperty("movedTo").GetProperty("serverId").GetGuid());
            }
            using (var hello = await oldClient.GetAsync("/api/v1/move/hello"))
                await AssertProblemAsync(hello, HttpStatusCode.Conflict, "server_moved");
            using (var info = await oldClient.GetAsync("/api/v1/server/info"))
            {
                Assert.Equal(HttpStatusCode.OK, info.StatusCode);
                using var document = JsonDocument.Parse(await info.Content.ReadAsStringAsync());
                Assert.Equal(oldId, document.RootElement.GetProperty("moved").GetProperty("serverId").GetGuid());
                Assert.Equal(oldId, document.RootElement.GetProperty("serverId").GetGuid());
            }
            Assert.True(old.Services.GetRequiredService<ServerMoveService>().IsMoved);

            // Undo Move: the old server answers again.
            using (var undo = ApiTestClient.Authorized(HttpMethod.Delete, "/api/v1/server/move", owner.Token))
            using (var answer = await ApiTestClient.SendAsync(oldClient, undo))
                Assert.Equal("none", (await ApiTestClient.ReadAsync<ServerMoveStatus>(answer)).State);
            using (var catalog = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/catalog/movies", owner.Token))
            using (var answer = await oldClient.SendAsync(catalog))
                Assert.Equal(HttpStatusCode.OK, answer.StatusCode);
            using (var info = await oldClient.GetAsync("/api/v1/server/info"))
            using (var document = JsonDocument.Parse(await info.Content.ReadAsStringAsync()))
                Assert.False(document.RootElement.TryGetProperty("moved", out _));
            Assert.Equal(mediaBefore, Snapshot(workspace, excluding: newData));
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(workspace, true); }
    }

    [Fact]
    public async Task MovingFileArrivesAndMarkAsMovedLearnsTheAddressesLater()
    {
        var workspace = TestPaths.CreateDataDirectory();
        var newData = Path.Combine(workspace, "new-server");
        Directory.CreateDirectory(newData);
        var newMedia = Path.Combine(workspace, "usb", "Media");
        try
        {
            using var old = OldServer();
            using var oldClient = Https(old);
            var (_, owner) = await SetupOwnerWithDeviceAsync(oldClient);
            var seeded = await SeedLibraryAsync(old, "/Volumes/Old/Movies", "/Volumes/Old/Series", newMedia);
            var mediaBefore = Snapshot(workspace);
            var started = await StartMoveAsync(oldClient, owner, new StartServerMoveRequest("file", MovePassphrase));
            byte[] movingFile;
            using (var download = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/server/backups/transfers/{started.TransferId}", owner.Token))
            using (var answer = await oldClient.SendAsync(download))
            {
                Assert.Equal(HttpStatusCode.OK, answer.StatusCode);
                movingFile = await answer.Content.ReadAsByteArrayAsync();
            }
            // Not reachable from the new server: the owner marks the move by hand.
            using (var mark = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/move/mark-moved", owner.Token))
            using (var answer = await ApiTestClient.SendAsync(oldClient, mark))
            {
                var marked = await ApiTestClient.ReadAsync<ServerMoveStatus>(answer);
                Assert.Equal("moved", marked.State);
                Assert.Empty(marked.MovedTo!.Addresses);
            }

            var oldSpki = Convert.FromHexString(old.Services.GetRequiredService<ServerTlsIdentity>().PublicKeyFingerprint!);
            var transport = new InProcessTransport(old.Server.CreateHandler, () => oldSpki);
            var applier = new RecordingApplier();
            using (var fresh = NewServer(newData, transport, applier, [workspace]))
            {
                using var client = fresh.CreateClient();
                var code = fresh.Services.GetRequiredService<BrowserSetup>().Current();
                SetupMoveUpload upload;
                using (var put = new HttpRequestMessage(HttpMethod.Put, "/api/v1/setup/move/file") { Content = new ByteArrayContent(movingFile) })
                {
                    put.Headers.Add(ServerMoveEndpoints.SetupCodeHeader, code);
                    using var answer = await client.SendAsync(put);
                    upload = await ApiTestClient.ReadAsync<SetupMoveUpload>(answer);
                }
                using (var wrong = Setup(HttpMethod.Post, $"/api/v1/setup/move/file/{upload.UploadId}/open", code, new SetupMoveOpenRequest("not the right passphrase")))
                using (var answer = await client.SendAsync(wrong))
                    await AssertProblemAsync(answer, HttpStatusCode.BadRequest, "backup_invalid");
                using (var open = Setup(HttpMethod.Post, $"/api/v1/setup/move/file/{upload.UploadId}/open", code, new SetupMoveOpenRequest(MovePassphrase)))
                using (var answer = await client.SendAsync(open))
                    Assert.Equal(HttpStatusCode.OK, answer.StatusCode);
                var status = await WaitForSetupAsync(client, code, "received");
                Assert.Contains(status.Locations.Single(location => location.Id == seeded.Movies).Suggestions,
                    suggestion => suggestion.Path == Path.Combine(newMedia, "Movies"));
                using (var finish = Setup(HttpMethod.Post, "/api/v1/setup/move/finish", code, new SetupMoveFinishRequest([new(seeded.Movies, "/does/not/exist")])))
                using (var answer = await client.SendAsync(finish))
                    await AssertProblemAsync(answer, HttpStatusCode.BadRequest, "folder_invalid");
                using (var finish = Setup(HttpMethod.Post, "/api/v1/setup/move/finish", code, new SetupMoveFinishRequest([new(seeded.Movies, Path.Combine(newMedia, "Movies"))])))
                using (var answer = await client.SendAsync(finish))
                    Assert.Equal("done", (await ApiTestClient.ReadAsync<SetupMoveStatus>(answer)).State);
            }
            SqliteConnection.ClearAllPools();
            var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", newData]);
            using (ServerInstanceLock.Acquire(newData)) await FullServerBackupService.ApplyPreparedAsync(runtime, Assert.Single(applier.Applied), CancellationToken.None);
            IReadOnlyList<string> reported;
            using (var moved = NewServer(newData, transport))
            {
                using var client = Https(moved);
                Assert.Equal((await InfoAsync(oldClient)).ServerId, (await InfoAsync(client)).ServerId);
                var movedRuntime = moved.Services.GetRequiredService<ServerRuntimeOptions>();
                reported = movedRuntime.LanAccessEnabled ? ServerMoveTransport.LocalAddresses(movedRuntime.LanHttpsPort) : [];
                // A late report reaches a server already marked as moved and only adds where it went.
                var deadline = DateTime.UtcNow.AddSeconds(20);
                while (ServerMoveArrival.Read(newData) is not null && DateTime.UtcNow < deadline) await Task.Delay(100);
                Assert.Null(ServerMoveArrival.Read(newData));
            }
            var after = await StatusAsync(oldClient, owner);
            Assert.Equal("moved", after.State);
            Assert.Equal(reported, after.MovedTo!.Addresses);
            Assert.Equal(mediaBefore, Snapshot(workspace, excluding: newData));
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(workspace, true); }
    }

    [Fact]
    public async Task MovingInFailsCleanlyWhenTheOldServersKeyIsNotTheOneSeen()
    {
        var workspace = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(workspace);
        try
        {
            using var old = OldServer();
            using var oldClient = Https(old);
            var (_, owner) = await SetupOwnerWithDeviceAsync(oldClient);
            var started = await StartMoveAsync(oldClient, owner, new StartServerMoveRequest("network"));
            // Someone in between answers with another key: hello works, the claim's proof fails.
            var stranger = RandomNumberGenerator.GetBytes(32);
            using var fresh = NewServer(null, new InProcessTransport(old.Server.CreateHandler, () => stranger), new RecordingApplier(), [workspace]);
            using var client = fresh.CreateClient();
            var code = fresh.Services.GetRequiredService<BrowserSetup>().Current();
            using (var start = Setup(HttpMethod.Post, "/api/v1/setup/move/network", code, new SetupMoveNetworkRequest("old.test", started.Code)))
            using (var answer = await client.SendAsync(start))
                Assert.Equal(HttpStatusCode.OK, answer.StatusCode);
            var failed = await WaitForSetupAsync(client, code, "failed");
            Assert.Contains("not right", failed.Error, StringComparison.Ordinal);
            Assert.Empty(failed.Locations);
            Assert.Equal("waiting", (await StatusAsync(oldClient, owner)).State);
            using (var discard = Setup(HttpMethod.Delete, "/api/v1/setup/move", code))
            using (var answer = await client.SendAsync(discard))
                Assert.Equal("idle", (await ApiTestClient.ReadAsync<SetupMoveStatus>(answer)).State);
            var backups = Path.Combine(fresh.DataDirectory, "Backups");
            Assert.True(!Directory.Exists(backups) || !Directory.EnumerateDirectories(backups, ".restore-*").Any());
        }
        finally { Directory.Delete(workspace, true); }
    }

    [Fact]
    public async Task StorageLocationMovedPreviewsCountsAndRewritesThenScans()
    {
        var workspace = TestPaths.CreateDataDirectory();
        var newMedia = Path.Combine(workspace, "nas", "Media");
        try
        {
            using var factory = new AureliaServerFactory(configureServices: services => Quiet(services, new FixedOptions([workspace])));
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client, password: Password);
            var seeded = await SeedLibraryAsync(factory, "/old-disk/Movies", "/old-disk/Series", newMedia);
            Directory.CreateDirectory(Path.Combine(workspace, "empty"));
            var mediaBefore = Snapshot(workspace);
            var target = Path.Combine(newMedia, "Movies");

            using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/libraries/{seeded.Movies}/relocate/suggestions", owner.Token))
            using (var answer = await client.SendAsync(request))
            {
                var suggestions = await ApiTestClient.ReadAsync<MoveLocationSuggestions>(answer);
                Assert.Equal(3, suggestions.Sampled);
                Assert.Equal(target, suggestions.Suggestions[0].Path);
                Assert.Equal(3, suggestions.Suggestions[0].Matched);
            }
            using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/libraries/{seeded.Movies}/relocate/preview", owner.Token, new LibraryRelocatePreviewRequest(target)))
            using (var answer = await client.SendAsync(request))
                Assert.Equal(new MoveLocationMatch(3, 3), await ApiTestClient.ReadAsync<MoveLocationMatch>(answer));
            using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/libraries/{seeded.Movies}/relocate/preview", owner.Token, new LibraryRelocatePreviewRequest(Path.Combine(workspace, "empty"))))
            using (var answer = await client.SendAsync(request))
                Assert.Equal(new MoveLocationMatch(3, 0), await ApiTestClient.ReadAsync<MoveLocationMatch>(answer));
            using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/libraries/{seeded.Movies}/relocate", owner.Token, new LibraryRelocateRequest(Path.Combine(workspace, "empty"))))
            using (var answer = await ApiTestClient.SendAsync(client, request))
                await AssertProblemAsync(answer, HttpStatusCode.Conflict, "relocate_no_matches");
            using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/libraries/{seeded.Movies}/relocate", owner.Token, new LibraryRelocateRequest(target)))
            using (var answer = await client.SendAsync(request))
                await AssertProblemAsync(answer, HttpStatusCode.Forbidden, "approval_required");
            LibraryRelocateResult result;
            using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/libraries/{seeded.Movies}/relocate", owner.Token, new LibraryRelocateRequest(target)))
            using (var answer = await ApiTestClient.SendAsync(client, request))
                result = await ApiTestClient.ReadAsync<LibraryRelocateResult>(answer);
            Assert.Equal(new LibraryRelocateResult(3, 3, 3, result.ScanId), result);
            Assert.NotNull(result.ScanId);
            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                Assert.Equal(target, (await database.LibraryRoots.SingleAsync(root => root.Id == seeded.Movies)).Path);
                var bound = await database.MediaItems.IgnoreQueryFilters().AsNoTracking().SingleAsync(item => item.Id == seeded.Bound);
                Assert.Equal(Path.Combine(target, "Extras", "Director's cut.mkv"), bound.SourcePath);
            }
            await WaitForScanAsync(client, owner, result.ScanId!.Value);
            Assert.Equal(mediaBefore, Snapshot(workspace));
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(workspace, true); }
    }

    [Fact]
    public async Task AnArrivalForAnotherIdentityIsDroppedWithoutReporting()
    {
        var directory = TestPaths.CreateDataDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(directory);
        try
        {
            // A move whose data could not be applied leaves the server as it was: nothing to report.
            ServerMoveArrival.Write(directory, new MoveArrivalRecord(1, Guid.NewGuid(), "synthetic-token", ["https://old.test:43111"], false));
            var calls = 0;
            var transport = new InProcessTransport(() => { Interlocked.Increment(ref calls); throw new HttpRequestException("unexpected"); }, () => new byte[32]);
            using var factory = NewServer(directory, transport);
            using var client = factory.CreateClient();
            Assert.False((await InfoAsync(client)).IsSetup);
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (File.Exists(Path.Combine(directory, ServerMoveArrival.FileName)) && DateTime.UtcNow < deadline) await Task.Delay(50);
            Assert.False(File.Exists(Path.Combine(directory, ServerMoveArrival.FileName)));
            Assert.Equal(0, calls);
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(directory, true); }
    }

    private sealed record Seeded(Guid Movies, Guid Series, Guid Bound);

    /// <summary>
    /// Two storage locations at paths of the "old computer" (which need not exist here) and the same
    /// synthetic files below <paramref name="newMedia"/>, as if the disk had moved.
    /// </summary>
    private static async Task<Seeded> SeedLibraryAsync(AureliaServerFactory factory, string moviesPath, string seriesPath, string newMedia)
    {
        var movies = Guid.NewGuid();
        var series = Guid.NewGuid();
        var bound = Guid.NewGuid();
        string[] films = ["Alpha (2001)/Alpha.mkv", "Beta (2002)/Beta.mkv", "Extras/Director's cut.mkv"];
        await using var scope = factory.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        database.LibraryRoots.AddRange(Root(movies, "Movies", moviesPath), Root(series, "Series", seriesPath));
        for (var index = 0; index < films.Length; index++)
        {
            var size = 2048 + index * 7;
            await WriteSyntheticAsync(Path.Combine(newMedia, "Movies", films[index]), size);
            var item = Item(index == 2 ? bound : Guid.NewGuid(), movies, moviesPath + "/" + films[index], $"7:{index}", manual: index == 2);
            item.FileSize = size;
            database.MediaItems.Add(item);
        }
        var episode = Item(Guid.NewGuid(), series, seriesPath + "/Show/S01E01.mkv", "7:9", MediaKind.Episode);
        episode.FileSize = 4000;
        database.MediaItems.Add(episode);
        await database.SaveChangesAsync();
        return new(movies, series, bound);
    }

    private static async Task AssertStagedPathsAsync(string databasePath, Seeded seeded, string movies)
    {
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = databasePath, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT Id, LibraryRootId, SourcePath, NormalizedSourcePath, FileSystemIdentity, ManualSourceBinding FROM MediaItems;";
        await using var reader = await command.ExecuteReaderAsync();
        var rows = 0;
        while (await reader.ReadAsync())
        {
            rows++;
            var root = Guid.Parse(reader.GetString(1));
            var source = reader.GetString(2);
            Assert.Equal(MediaPath.Normalize(source), reader.GetString(3));
            if (root == seeded.Movies)
            {
                Assert.StartsWith(movies + Path.DirectorySeparatorChar, source, StringComparison.Ordinal);
                Assert.True(File.Exists(source));
                Assert.True(reader.IsDBNull(4));
                if (Guid.Parse(reader.GetString(0)) == seeded.Bound) Assert.True(reader.GetBoolean(5));
            }
            else
            {
                Assert.StartsWith("/old-computer/media/Series/", source, StringComparison.Ordinal);
                Assert.Equal("7:9", reader.GetString(4));
            }
        }
        Assert.Equal(4, rows);
    }

    private static LibraryRoot Root(Guid id, string name, string path) => new()
    {
        Id = id,
        Name = name,
        Path = path,
        NormalizedPath = MediaPath.Normalize(path),
        Kind = LibraryKind.Movies,
        MonitoringEnabled = false,
        CreatedAt = DateTimeOffset.UtcNow,
    };

    private static MediaItem Item(Guid id, Guid root, string path, string? identity, MediaKind kind = MediaKind.Movie, bool manual = false) => new()
    {
        Id = id,
        LibraryRootId = root,
        Kind = kind,
        SourcePath = path,
        NormalizedSourcePath = MediaPath.Normalize(path),
        DetectedTitle = Path.GetFileNameWithoutExtension(path),
        Category = kind == MediaKind.Movie ? "Movies" : "Series",
        Extension = ".mkv",
        FileSize = 1234,
        FileSystemIdentity = identity,
        ManualSourceBinding = manual,
        Availability = MediaAvailability.Available,
        CreatedAt = DateTimeOffset.UtcNow,
        UpdatedAt = DateTimeOffset.UtcNow,
    };

    private static async Task WriteSyntheticAsync(string path, int size)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await File.WriteAllBytesAsync(path, RandomNumberGenerator.GetBytes(size));
    }

    /// <summary>Size and modification time of every file, to prove the server only read them.</summary>
    private static string Snapshot(string root, string? excluding = null) => string.Join('\n', Directory
        .EnumerateFiles(root, "*", SearchOption.AllDirectories)
        .Where(path => excluding is null || !path.StartsWith(excluding + Path.DirectorySeparatorChar, StringComparison.Ordinal))
        .Order(StringComparer.Ordinal)
        .Select(path => $"{path}|{new FileInfo(path).Length}|{File.GetLastWriteTimeUtc(path).Ticks}"));

    private static AureliaServerFactory OldServer(Action<IServiceCollection>? configure = null) => new(
        configureServices: services =>
        {
            Quiet(services, null);
            configure?.Invoke(services);
        },
        settings: new Dictionary<string, string> { ["Aurelia:LanAccessEnabled"] = "true" });

    private static AureliaServerFactory NewServer(string? directory, ServerMoveTransport transport, ServerMoveApplier? applier = null,
        IReadOnlyList<string>? searchRoots = null) => new(directory, configureServices: services =>
        {
            Quiet(services, new FixedOptions(searchRoots ?? []));
            services.RemoveAll<ServerMoveTransport>();
            services.AddSingleton(transport);
            if (applier is not null)
            {
                services.RemoveAll<ServerMoveApplier>();
                services.AddSingleton<ServerMoveApplier>(applier);
            }
        });

    /// <summary>No Bonjour announcements on the real network from tests; suggestions search only the test folder.</summary>
    private static void Quiet(IServiceCollection services, ServerMoveOptions? options)
    {
        foreach (var descriptor in services.Where(descriptor => descriptor.ServiceType == typeof(IHostedService)
            && descriptor.ImplementationType == typeof(BonjourAdvertisementService)).ToArray())
            services.Remove(descriptor);
        services.RemoveAll<ServerMoveOptions>();
        services.AddSingleton(options ?? new FixedOptions([]));
    }

    /// <summary>A client whose requests arrive as HTTPS, as the move's calls between servers must.</summary>
    private static HttpClient Https(AureliaServerFactory factory)
    {
        var client = factory.CreateClient(new Microsoft.AspNetCore.Mvc.Testing.WebApplicationFactoryClientOptions { BaseAddress = new Uri("https://localhost") });
        return client;
    }

    private static async Task<(string DeviceToken, AuthenticationResponse Profile)> SetupOwnerWithDeviceAsync(HttpClient client)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/setup/owner");
        request.Headers.Add(BootstrapSetupAuthorizer.HeaderName, ApiTestClient.BootstrapToken);
        request.Content = JsonContent.Create(new SetupOwnerRequest("lucas", Password, "Test Mac"), options: ApiTestClient.JsonOptions);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        var device = await ApiTestClient.ReadAsync<AuthenticationResponse>(response);
        using var initialize = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/profiles/initialize", device.Token, new InitializeProfilesRequest(Password, ApiTestClient.TestPin));
        using var initialized = await client.SendAsync(initialize);
        initialized.EnsureSuccessStatusCode();
        return (device.Token, await ApiTestClient.UnlockDeviceAsync(client, device, device.User.Id));
    }

    private static async Task<ServerMoveStarted> StartMoveAsync(HttpClient client, AuthenticationResponse owner, StartServerMoveRequest request)
    {
        using var start = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/move", owner.Token, request);
        using var response = await ApiTestClient.SendAsync(client, start);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await ApiTestClient.ReadAsync<ServerMoveStarted>(response);
    }

    private static async Task<ServerMoveStatus> StatusAsync(HttpClient client, AuthenticationResponse owner)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/move", owner.Token);
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await ApiTestClient.ReadAsync<ServerMoveStatus>(response);
    }

    private static async Task<ServerInfoResponse> InfoAsync(HttpClient client)
    {
        using var response = await client.GetAsync("/api/v1/server/info");
        return await ApiTestClient.ReadAsync<ServerInfoResponse>(response);
    }

    private static HttpRequestMessage Setup(HttpMethod method, string path, string code, object? body = null)
    {
        var request = new HttpRequestMessage(method, path);
        request.Headers.Add(ServerMoveEndpoints.SetupCodeHeader, code);
        if (body is not null) request.Content = JsonContent.Create(body, options: ApiTestClient.JsonOptions);
        return request;
    }

    private static async Task<SetupMoveStatus> WaitForSetupAsync(HttpClient client, string code, string state)
    {
        var deadline = DateTime.UtcNow.AddSeconds(60);
        while (true)
        {
            using var request = Setup(HttpMethod.Get, "/api/v1/setup/move", code);
            using var response = await client.SendAsync(request);
            var status = await ApiTestClient.ReadAsync<SetupMoveStatus>(response);
            if (status.State == state) return status;
            Assert.True(status.State is "fetching" && DateTime.UtcNow < deadline, $"The move is {status.State}: {status.Error}");
            await Task.Delay(50);
        }
    }

    private static async Task<ServerMoveStatus> WaitForOldAsync(HttpClient client, AuthenticationResponse owner, string state)
    {
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (true)
        {
            var status = await StatusAsync(client, owner);
            if (status.State == state || DateTime.UtcNow > deadline) return status;
            await Task.Delay(100);
        }
    }

    private static async Task WaitForScanAsync(HttpClient client, AuthenticationResponse owner, Guid scanId)
    {
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (DateTime.UtcNow < deadline)
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/scans/{scanId}", owner.Token);
            using var response = await client.SendAsync(request);
            var scan = await ApiTestClient.ReadAsync<LibraryScanSummary>(response);
            if (scan.State is not (LibraryScanState.Queued or LibraryScanState.Running)) return;
            await Task.Delay(100);
        }
    }

    private static async Task AssertProblemAsync(HttpResponseMessage response, HttpStatusCode status, string code)
    {
        var text = await response.Content.ReadAsStringAsync();
        Assert.True(response.StatusCode == status, $"Expected {(int)status} {code}, got {(int)response.StatusCode}: {text}");
        using var document = JsonDocument.Parse(text);
        Assert.Equal(code, document.RootElement.GetProperty("code").GetString());
    }

    private static string Nonce() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));

    private sealed class MoveClock : TimeProvider
    {
        private long ticks = DateTimeOffset.UtcNow.UtcTicks;
        public override DateTimeOffset GetUtcNow() => new(Interlocked.Read(ref ticks), TimeSpan.Zero);
        public void Advance(TimeSpan interval) => Interlocked.Add(ref ticks, interval.Ticks);
    }

    private sealed class FixedOptions(IReadOnlyList<string> roots) : ServerMoveOptions
    {
        public override IReadOnlyList<string> SearchRoots => roots;
        public override TimeSpan SearchBudget => TimeSpan.FromSeconds(10);
    }

    /// <summary>Records the restore a finished move asks for, instead of restarting the test host.</summary>
    private sealed class RecordingApplier() : ServerMoveApplier(null!, null!, null!)
    {
        public List<Guid> Applied { get; } = [];
        public override Task ApplyAsync(Guid restoreId, CancellationToken token)
        {
            Applied.Add(restoreId);
            return Task.CompletedTask;
        }
    }

    /// <summary>
    /// Reaches another in-process server as if over HTTPS: reports the key that server "shows" and,
    /// like TLS with a pinned key, refuses a connection whose key is not the pinned one.
    /// </summary>
    private sealed class InProcessTransport(Func<HttpMessageHandler> handler, Func<byte[]> shownKey) : ServerMoveTransport
    {
        public override HttpClient Create(Action<byte[]> observedSpki, byte[]? pinnedSpki)
        {
            var key = shownKey();
            if (pinnedSpki is not null && !pinnedSpki.AsSpan().SequenceEqual(key)) return new HttpClient(new Refusing());
            observedSpki(key);
            return new HttpClient(handler());
        }

        private sealed class Refusing : HttpMessageHandler
        {
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
                throw new HttpRequestException("The server's key is not the pinned one.");
        }
    }
}
