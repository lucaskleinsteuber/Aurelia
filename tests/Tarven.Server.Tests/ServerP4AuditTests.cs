using System.Net;
using System.Text;
using Tarven.Contracts;
using Tarven.Server.Data;
using Tarven.Server.Services;
using Tarven.Server.Services.FileChecks;
using Tarven.Server.Services.Speech;
using Microsoft.AspNetCore.Http;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Tarven.Server.Tests;

/// <summary>
/// Targeted regression tests for Server P4 audit findings (2026-11-21):
/// DYN-API-006, DYN-API-010, DYN-SAFE-002, SRV-API-015, SRV-BG-014..016,
/// SRV-DATA-008..013, SRV-LIB-010..012, SRV-PLAY-012..014, SRV-SEC-005,
/// SRV-SEC-010, and VERIFY-SRV-101.
/// </summary>
public sealed class ServerP4AuditTests
{
    [Fact]
    public async Task InvisibleDeviceNamesAreRejectedAndDeletingUnknownHistoryReturns404()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // DYN-API-006: Zero-width and format-only device names contain no visible characters.
        foreach (var invisible in new[] { "\u200B", "\u200B \uFEFF\u2060", "\u00AD\u200C" })
        {
            using var start = new HttpRequestMessage(HttpMethod.Post, "/api/v1/auth/device-pairings")
            {
                Content = System.Net.Http.Json.JsonContent.Create(new DeviceAuthorizationStartRequest(invisible), options: ApiTestClient.JsonOptions),
            };
            using var refused = await client.SendAsync(start);
            Assert.Equal(HttpStatusCode.BadRequest, refused.StatusCode);
            Assert.Equal("invalid_device_name", (await ApiTestClient.ReadAsync<ApiProblem>(refused)).Code);
        }

        // A visible name (including emoji) still succeeds.
        using (var validStart = new HttpRequestMessage(HttpMethod.Post, "/api/v1/auth/device-pairings")
        {
            Content = System.Net.Http.Json.JsonContent.Create(new DeviceAuthorizationStartRequest("Living Room 🎬"), options: ApiTestClient.JsonOptions),
        })
        using (var accepted = await client.SendAsync(validStart))
        {
            Assert.Equal(HttpStatusCode.OK, accepted.StatusCode);
        }

        // DYN-API-006: Deleting a nonexistent or foreign watch history item returns 404.
        using (var missing = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/history/{Guid.NewGuid()}", owner.Token))
        using (var missingResp = await ApiTestClient.SendAsync(client, missing))
        {
            Assert.Equal(HttpStatusCode.NotFound, missingResp.StatusCode);
            Assert.Equal("history_item_not_found", (await ApiTestClient.ReadAsync<ApiProblem>(missingResp)).Code);
        }
    }

    [Fact]
    public async Task ForeignSceneNoteIdDoesNotConflictOrDiscloseExistence()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var movieId = await SeedMovieAsync(factory, "Scene Note Isolation Film");

        using var createViewer = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("note-viewer-a", "", UserRole.User, ApiTestClient.TestPin, AccessMode: ProfileAccessMode.EntireLibrary));
        using var viewerResp = await ApiTestClient.SendAsync(client, createViewer);
        viewerResp.EnsureSuccessStatusCode();
        var viewer = await ApiTestClient.ReadAsync<UserSummary>(viewerResp);
        var viewerToken = await IssueSeparateDeviceProfileTokenAsync(factory, viewer.Id);

        var sharedNoteId = Guid.NewGuid();
        var foreignOnlyId = Guid.NewGuid();
        var route = $"/api/v1/media/{movieId}/notes";

        // Owner creates two scene notes.
        using (var ownerSave1 = ApiTestClient.Authorized(HttpMethod.Put, $"{route}/{sharedNoteId}", owner.Token,
                   new SaveSceneNoteRequest(10_000, 20_000, "Owner secret note", 0)))
        using (var r1 = await ApiTestClient.SendAsync(client, ownerSave1))
            r1.EnsureSuccessStatusCode();

        using (var ownerSave2 = ApiTestClient.Authorized(HttpMethod.Put, $"{route}/{foreignOnlyId}", owner.Token,
                   new SaveSceneNoteRequest(30_000, null, "Owner second note", 0)))
        using (var r2 = await ApiTestClient.SendAsync(client, ownerSave2))
            r2.EnsureSuccessStatusCode();

        // DYN-API-010: Another profile saving revision 0 with the same GUID creates its own note (200), never 409.
        using (var viewerSave = ApiTestClient.Authorized(HttpMethod.Put, $"{route}/{sharedNoteId}", viewerToken,
                   new SaveSceneNoteRequest(5_000, null, "Viewer own note", 0)))
        using (var viewerSaveResp = await ApiTestClient.SendAsync(client, viewerSave))
        {
            Assert.Equal(HttpStatusCode.OK, viewerSaveResp.StatusCode);
            var created = await ApiTestClient.ReadAsync<SceneNoteSummary>(viewerSaveResp);
            Assert.Equal(1, created.Revision);
            Assert.Equal("Viewer own note", created.Text);
        }

        // Updating with revision 1 for a GUID owned only by another profile returns 404.
        using (var viewerStale = ApiTestClient.Authorized(HttpMethod.Put, $"{route}/{foreignOnlyId}", viewerToken,
                   new SaveSceneNoteRequest(5_000, null, "Attempted overwrite", 1)))
        using (var staleResp = await ApiTestClient.SendAsync(client, viewerStale))
        {
            Assert.Equal(HttpStatusCode.NotFound, staleResp.StatusCode);
        }

        // Owner's original note is completely untouched.
        using var ownerListReq = ApiTestClient.Authorized(HttpMethod.Get, route, owner.Token);
        using var ownerListResp = await ApiTestClient.SendAsync(client, ownerListReq);
        var ownerNotes = await ApiTestClient.ReadAsync<List<SceneNoteSummary>>(ownerListResp);
        Assert.Equal("Owner secret note", Assert.Single(ownerNotes, n => n.Id == sharedNoteId).Text);
    }

    [Fact]
    public async Task ContractValidationHardeningCoversWishesTrailersSpeechSessionsCapabilitiesAndGuard()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var movieId = await SeedMovieAsync(factory, "Validation Film");

        // SRV-API-015: numeric wish state and catalog kind rejected with 400.
        foreach (var badState in new[] { "7", "0", "-1", "bogus" })
        {
            using var req = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/wishes?state={badState}", owner.Token);
            using var resp = await ApiTestClient.SendAsync(client, req);
            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
            Assert.Equal("invalid_wish_state", (await ApiTestClient.ReadAsync<ApiProblem>(resp)).Code);
        }

        foreach (var badKind in new[] { "99", "0", "bogus" })
        {
            using var req = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/catalog/items?kind={badKind}", owner.Token);
            using var resp = await ApiTestClient.SendAsync(client, req);
            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
            Assert.Equal("invalid_catalog_kind", (await ApiTestClient.ReadAsync<ApiProblem>(resp)).Code);
        }

        // SRV-API-015: out-of-range cinema trailer count returns 400 instead of silently clamping.
        foreach (var badCount in new[] { -1, 4, 10 })
        {
            using var req = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{movieId}/cinema-trailers?count={badCount}", owner.Token);
            using var resp = await ApiTestClient.SendAsync(client, req);
            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
            Assert.Equal("invalid_trailer_count", (await ApiTestClient.ReadAsync<ApiProblem>(resp)).Code);
        }

        // SRV-API-015: unknown media speech status and unknown user sessions return 404.
        using (var speechReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{Guid.NewGuid()}/speech", owner.Token))
        using (var speechResp = await ApiTestClient.SendAsync(client, speechReq))
        {
            Assert.Equal(HttpStatusCode.NotFound, speechResp.StatusCode);
            Assert.Equal("media_not_found", (await ApiTestClient.ReadAsync<ApiProblem>(speechResp)).Code);
        }

        using (var sessionsReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/server/sessions/{Guid.NewGuid()}", owner.Token))
        using (var sessionsResp = await ApiTestClient.SendAsync(client, sessionsReq))
        {
            Assert.Equal(HttpStatusCode.NotFound, sessionsResp.StatusCode);
            Assert.Equal("user_not_found", (await ApiTestClient.ReadAsync<ApiProblem>(sessionsResp)).Code);
        }

        // SRV-API-015: /api/v1/server/capabilities reports actual encoder availability.
        var live = factory.Services.GetRequiredService<LiveConversionService>();
        var tools = await live.ToolsAsync();
        var expectedTranscoding = tools is not null && live.ChooseEncoder(tools) is not null;
        using (var capReq = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/capabilities", owner.Token))
        using (var capResp = await ApiTestClient.SendAsync(client, capReq))
        {
            capResp.EnsureSuccessStatusCode();
            var caps = await ApiTestClient.ReadAsync<ServerManagementCapabilities>(capResp);
            Assert.Equal(expectedTranscoding, caps.Transcoding);
        }

        // SRV-API-015: removed /api/v1/server/automation/ rule is gone from ServerRequestGuard.
        var httpContext = new DefaultHttpContext();
        httpContext.Request.Method = HttpMethods.Post;
        httpContext.Request.Path = "/api/v1/server/automation/tokens";
        Assert.False(ServerRequestGuard.RequiresApproval(httpContext.Request));
    }

    [Fact]
    public async Task AdministratorCanReadMetadataProviderStatusAndNumericBodyReturns400()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var createAdmin = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("meta-admin", "", UserRole.Admin, ApiTestClient.TestPin, AccessMode: ProfileAccessMode.EntireLibrary));
        using var adminResp = await ApiTestClient.SendAsync(client, createAdmin);
        adminResp.EnsureSuccessStatusCode();
        var admin = await ApiTestClient.ReadAsync<UserSummary>(adminResp);

        using var createViewer = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("meta-viewer", "", UserRole.User, ApiTestClient.TestPin, AccessMode: ProfileAccessMode.EntireLibrary));
        using var viewerResp = await ApiTestClient.SendAsync(client, createViewer);
        viewerResp.EnsureSuccessStatusCode();
        var viewer = await ApiTestClient.ReadAsync<UserSummary>(viewerResp);

        var adminToken = await IssueSeparateDeviceProfileTokenAsync(factory, admin.Id);
        var viewerToken = await IssueSeparateDeviceProfileTokenAsync(factory, viewer.Id);

        // SRV-SEC-005: Administrator can read and update metadata provider status; viewer cannot.
        using (var adminGet = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/metadata/provider", adminToken))
        using (var adminGetResp = await ApiTestClient.SendAsync(client, adminGet))
        {
            Assert.Equal(HttpStatusCode.OK, adminGetResp.StatusCode);
            var status = await ApiTestClient.ReadAsync<MetadataProviderStatus>(adminGetResp);
            Assert.Equal("TMDB", status.Provider);
        }

        using (var viewerGet = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/metadata/provider", viewerToken))
        using (var viewerGetResp = await ApiTestClient.SendAsync(client, viewerGet))
            Assert.Equal(HttpStatusCode.Forbidden, viewerGetResp.StatusCode);

        // SRV-SEC-010: Non-object JSON body (numeric primitive) returns 400, not 500.
        using var numberReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token);
        numberReq.Content = new StringContent("1", Encoding.UTF8, "application/json");
        using var numberResp = await client.SendAsync(numberReq);
        Assert.Equal(HttpStatusCode.BadRequest, numberResp.StatusCode);
    }

    [Fact]
    public async Task TranscodingStatusReportsConfiguredMaximumVideoConversions()
    {
        // VERIFY-SRV-101: Tarven:MaximumVideoConversions=1 is reflected in /api/v1/server/transcoding.
        using var factory = new TarvenServerFactory(settings: new Dictionary<string, string>
        {
            ["Tarven:MaximumVideoConversions"] = "1",
        });
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var req = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/transcoding", owner.Token);
        using var resp = await ApiTestClient.SendAsync(client, req);
        resp.EnsureSuccessStatusCode();
        var status = await ApiTestClient.ReadAsync<TranscodingStatusResponse>(resp);
        Assert.Equal(1, status.VideoLimit);
    }

    [Fact]
    public async Task ScreenTimeEnforcerThrottlesRepeatedFailuresAndUsesLatestProgressTimestamp()
    {
        // SRV-BG-014: Repeated identical failures log only once until recovery.
        var logger = new RecordingLogger<ScreenTimeEnforcer>();
        var failingScopes = new FlakyScopeFactory { ShouldFail = true };
        var streams = new ActiveStreamRegistry();
        var sessions = new ProfileSessionStore(TimeProvider.System, new TokenService(), streams);
        var enforcer = new ScreenTimeEnforcer(failingScopes, TimeProvider.System, streams, sessions, logger);

        for (var i = 0; i < 5; i++)
            await enforcer.RunTickAsync(CancellationToken.None);
        Assert.Equal(1, logger.WarningCount);

        // Recovery clears throttle; a subsequent failure logs once again.
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        await ApiTestClient.SetupOwnerAsync(client);
        failingScopes.Inner = factory.Services.GetRequiredService<IServiceScopeFactory>();
        failingScopes.ShouldFail = false;
        await enforcer.RunTickAsync(CancellationToken.None);
        Assert.Equal(1, logger.WarningCount);

        failingScopes.ShouldFail = true;
        await enforcer.RunTickAsync(CancellationToken.None);
        await enforcer.RunTickAsync(CancellationToken.None);
        Assert.Equal(2, logger.WarningCount);
    }

    [Fact]
    public async Task SegmentDetectionInterruptsAudioReadWhenPlaybackStartsAndRetriesAfter()
    {
        // SRV-BG-015: Audio reading cancels when playback starts and retries cleanly once playback ends.
        using var factory = new TarvenServerFactory();
        var detection = factory.Services.GetRequiredService<SegmentDetectionService>();
        var streams = factory.Services.GetRequiredService<ActiveStreamRegistry>();

        var attempts = 0;
        var firstReadStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var firstReadCanceled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var readTask = detection.RunInterruptibleReadAsync("Episode 1", "Listening to the beginning", async token =>
        {
            var attempt = Interlocked.Increment(ref attempts);
            if (attempt == 1)
            {
                firstReadStarted.TrySetResult();
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(30), token);
                }
                catch (OperationCanceledException)
                {
                    firstReadCanceled.TrySetResult();
                    throw;
                }
            }
            return new short[] { 1, 2, 3 };
        }, CancellationToken.None);

        await firstReadStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        using (var lease = streams.Enter(Guid.NewGuid(), Guid.NewGuid(), 10, 10, CancellationToken.None))
        {
            Assert.NotNull(lease);
            await firstReadCanceled.Task.WaitAsync(TimeSpan.FromSeconds(10));
        }

        var samples = await readTask.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.NotNull(samples);
        Assert.Equal(2, attempts);
    }

    [Fact]
    public void WhisperRecognizerIsolatesWorkingDirectoryHomeAndTmpdir()
    {
        // SRV-BG-016: whisper-cli runs in the empty read-only Converter directory with isolated HOME/TMPDIR.
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var converter = Path.Combine(root, "Converter");
        try
        {
            var start = WhisperRecognizer.BuildStartInfo("/usr/bin/whisper-cli", "/models/base.bin", "en", 2, converter);
            Assert.Equal(converter, start.WorkingDirectory);
            Assert.True(Directory.Exists(converter));
            if (!OperatingSystem.IsWindows())
            {
                Assert.Equal("/usr/bin:/bin", start.Environment["PATH"]);
                Assert.Equal(converter, start.Environment["HOME"]);
                Assert.Equal(converter, start.Environment["TMPDIR"]);
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserExecute, File.GetUnixFileMode(converter));
            }
        }
        finally
        {
            if (Directory.Exists(converter) && !OperatingSystem.IsWindows())
                File.SetUnixFileMode(converter, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void FileCheckSanitizesLongLinesBeforeTruncatingAndStripsFilePrefix()
    {
        // SRV-LIB-011 & DYN-SAFE-002: Long stderr lines have the full path removed BEFORE 1024-char truncation.
        var checkedPath = "/Volumes/Personal Media Archive/Movies/Glass Harbor (2019)/Glass Harbor (2019) Remux.mkv";
        var padding = new string('x', 990);
        var rawLine = $"[matroska] {padding} file:{checkedPath}: Invalid data found";
        Assert.True(rawLine.Length > 1024);

        var sanitized = FileCheckService.SanitizeLine(rawLine, checkedPath);
        Assert.True(sanitized.Length <= 1024);
        Assert.DoesNotContain("Glass Harbor", sanitized, StringComparison.Ordinal);
        Assert.DoesNotContain("Personal Media Archive", sanitized, StringComparison.Ordinal);
        Assert.DoesNotContain("file:the file", sanitized, StringComparison.Ordinal);

        var output = new FfmpegCheckOutput(checkedPath);
        output.Add($"[mov,mp4 @ 0x7f1234] file:{checkedPath}: moov atom not found");
        var detail = Assert.Single(output.Lines);
        Assert.DoesNotContain("Glass Harbor", detail, StringComparison.Ordinal);
        Assert.DoesNotContain("file:the file", detail, StringComparison.Ordinal);
    }

    [Fact]
    public void SignalFilesAreCreatedWithOwnerOnlyPermissions()
    {
        if (OperatingSystem.IsWindows()) return;

        // SRV-LIB-012: last-use, work, and sleep-ready are all created with 0600 permissions.
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        try
        {
            var runtime = new ServerRuntimeOptions(root, Path.Combine(root, "unused.db"), "http://127.0.0.1:0", "Invented", false, 43111, "127.0.0.1", "synthetic", null, false);
            var clock = new TestClock(new DateTimeOffset(2026, 11, 24, 12, 0, 0, TimeSpan.Zero));
            var streams = new ActiveStreamRegistry();

            var useClock = new ServerUseClock(runtime, clock);
            Assert.True(useClock.Record());
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite,
                File.GetUnixFileMode(Path.Combine(root, ServerUseClock.FileName)));

            var workSignal = new ServerWorkSignal(runtime, clock, new RecordingLogger<ServerWorkSignal>());
            using (workSignal.KeepAwake())
            {
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite,
                    File.GetUnixFileMode(Path.Combine(root, ServerWorkSignal.FileName)));
            }

            var sleepSignal = new ServerSleepSignal(runtime, streams, clock);
            sleepSignal.SleepTimerEnded();
            clock.Advance(TimeSpan.FromMinutes(6));
            Assert.True(sleepSignal.Evaluate());
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite,
                File.GetUnixFileMode(Path.Combine(root, ServerSleepSignal.FileName)));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task DeletingUserRemovesPersistedWatchlistFile()
    {
        // SRV-DATA-011: Deleting a profile removes its Watchlist/<id>.json file.
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var movieId = await SeedMovieAsync(factory, "Watchlist Cleanup Film");

        using var createViewer = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("watchlist-viewer", "", UserRole.User, ApiTestClient.TestPin, AccessMode: ProfileAccessMode.EntireLibrary));
        using var viewerResp = await ApiTestClient.SendAsync(client, createViewer);
        viewerResp.EnsureSuccessStatusCode();
        var viewer = await ApiTestClient.ReadAsync<UserSummary>(viewerResp);
        var viewerToken = await IssueSeparateDeviceProfileTokenAsync(factory, viewer.Id);

        using (var addWatchlist = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{movieId}/watchlist", viewerToken,
                   new SetWatchlistRequest(true)))
        using (var addResp = await ApiTestClient.SendAsync(client, addWatchlist))
            addResp.EnsureSuccessStatusCode();

        var watchlistFile = Path.Combine(factory.DataDirectory, "Watchlist", $"{viewer.Id:N}.json");
        Assert.True(File.Exists(watchlistFile));

        using (var deleteUser = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/users/{viewer.Id}", owner.Token))
        using (var deleteResp = await ApiTestClient.SendAsync(client, deleteUser))
            Assert.Equal(HttpStatusCode.NoContent, deleteResp.StatusCode);

        Assert.False(File.Exists(watchlistFile));
    }

    [Fact]
    public async Task MaintenancePrunesOldWatchEventsLibraryStateReceiptsAndCompletedLibraryMutations()
    {
        // SRV-DATA-009 & SRV-DATA-010: Maintenance prunes stale WatchEvents (>3y), LibraryStateMutations (>30d),
        // and completed LibraryMutations (>30d) while preserving recent and still-cleaning entries.
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var movieId = await SeedMovieAsync(factory, "Maintenance Pruning Film");

        var now = DateTimeOffset.UtcNow;
        var oldWatchId = Guid.NewGuid();
        var recentWatchId = Guid.NewGuid();
        var oldStateId = Guid.NewGuid();
        var recentStateId = Guid.NewGuid();
        var oldCompletedMutationId = Guid.NewGuid();
        var recentCompletedMutationId = Guid.NewGuid();
        var oldCleaningMutationId = Guid.NewGuid();

        await using (var scope = factory.Services.CreateAsyncScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
            db.WatchEvents.AddRange(
                new WatchEvent { Id = oldWatchId, UserId = owner.User.Id, MediaItemId = movieId, Timestamp = now.AddYears(-4), PositionMilliseconds = 1000, DurationMilliseconds = 5000, SecondsWatched = 10 },
                new WatchEvent { Id = recentWatchId, UserId = owner.User.Id, MediaItemId = movieId, Timestamp = now.AddDays(-10), PositionMilliseconds = 1000, DurationMilliseconds = 5000, SecondsWatched = 10 });
            db.LibraryStateMutations.AddRange(
                new LibraryStateMutation { UserId = owner.User.Id, ClientMutationId = oldStateId, Fingerprint = "old", ResponseJson = "{}", CreatedAt = now.AddDays(-45) },
                new LibraryStateMutation { UserId = owner.User.Id, ClientMutationId = recentStateId, Fingerprint = "recent", ResponseJson = "{}", CreatedAt = now.AddDays(-5) });
            db.LibraryMutations.AddRange(
                new LibraryMutation { Id = oldCompletedMutationId, UserId = owner.User.Id, State = "completed", CreatedAt = now.AddDays(-45) },
                new LibraryMutation { Id = recentCompletedMutationId, UserId = owner.User.Id, State = "completed", CreatedAt = now.AddDays(-5) },
                new LibraryMutation { Id = oldCleaningMutationId, UserId = owner.User.Id, State = "cleaning", CreatedAt = now.AddDays(-45) });
            await db.SaveChangesAsync();
        }

        var maintenance = new MaintenanceService(factory.Services.GetRequiredService<IServiceScopeFactory>(), new RecordingLogger<MaintenanceService>());
        await maintenance.RunAsync(now, CancellationToken.None);

        await using var verifyScope = factory.Services.CreateAsyncScope();
        var verifyDb = verifyScope.ServiceProvider.GetRequiredService<TarvenDbContext>();
        Assert.Equal([recentWatchId], await verifyDb.WatchEvents.Select(e => e.Id).ToListAsync());
        Assert.Equal([recentStateId], await verifyDb.LibraryStateMutations.Select(m => m.ClientMutationId).ToListAsync());
        var remainingMutations = await verifyDb.LibraryMutations.Select(m => m.Id).ToListAsync();
        Assert.DoesNotContain(oldCompletedMutationId, remainingMutations);
        Assert.Contains(recentCompletedMutationId, remainingMutations);
        Assert.Contains(oldCleaningMutationId, remainingMutations);
    }

    [Fact]
    public async Task AuditSchemaHardeningMigrationConvertsLegacyProfilePhotosAndSupportsRoundTrip()
    {
        // SRV-DATA-012, SRV-DATA-009, SRV-DATA-010, DYN-API-010: Verify upgrade from prior schema and clean downgrade.
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var dbPath = Path.Combine(root, "tarven.db");
        var options = new DbContextOptionsBuilder<TarvenDbContext>()
            .UseSqlite($"Data Source={dbPath};Pooling=False").Options;
        try
        {
            var userId = Guid.NewGuid();
            var user2Id = Guid.NewGuid();
            var libraryId = Guid.NewGuid();
            var mediaId = Guid.NewGuid();
            var noteId = Guid.NewGuid();
            var stateMutationId = Guid.NewGuid();
            var libMutationId = Guid.NewGuid();

            await using (var db = new TarvenDbContext(options))
            {
                await db.Database.GetService<IMigrator>().MigrateAsync("20261117214942_RemoveSmartHome");
                var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                const string emptyJson = "{}";
                await db.Database.ExecuteSqlInterpolatedAsync($"""
                    INSERT INTO Users (Id, Username, NormalizedUsername, PasswordHash, Role, IsEnabled, CreatedAt, AccessMode, AccessRevision, PinProtectionEnabled, ProfileRevision, PictureRevision)
                    VALUES ({userId}, 'Owner', 'OWNER', 'hash', 'Owner', 1, {nowMs}, 'EntireLibrary', 1, 1, 1, 1);
                    INSERT INTO Users (Id, Username, NormalizedUsername, PasswordHash, Role, IsEnabled, CreatedAt, AccessMode, AccessRevision, PinProtectionEnabled, ProfileRevision, PictureRevision)
                    VALUES ({user2Id}, 'Viewer', 'VIEWER', 'hash', 'User', 1, {nowMs}, 'EntireLibrary', 1, 0, 1, 0);
                    INSERT INTO LibraryRoots (Id, Name, Path, NormalizedPath, Kind, MonitoringEnabled, ImportAssignmentRevision, ImportPreviewRequired, Availability, CreatedAt)
                    VALUES ({libraryId}, 'Movies', '/movies', '/movies', 'Movies', 0, 0, 0, 'Available', {nowMs});
                    INSERT INTO MediaItems (Id, LibraryRootId, Kind, DetectedTitle, Category, SourcePath, NormalizedSourcePath, Extension, FileSize, Availability, CreatedAt, UpdatedAt)
                    VALUES ({mediaId}, {libraryId}, 'Movie', 'Film', '', '/movies/film.mkv', '/movies/film.mkv', '.mkv', 100, 'Available', {nowMs}, {nowMs});
                    INSERT INTO ProfilePhotos (UserId, Jpeg, UpdatedAt)
                    VALUES ({userId}, X'FFD8FFD9', '2026-11-07 17:38:36.1234567+00:00');
                    INSERT INTO LibraryStateMutations (UserId, ClientMutationId, Fingerprint, ResponseJson, AccessRevision)
                    VALUES ({userId}, {stateMutationId}, 'fp', {emptyJson}, 1);
                    INSERT INTO LibraryMutations (Id, UserId, State, RemovedItems, FilesJson)
                    VALUES ({libMutationId}, {userId}, 'completed', 1, '[]');
                    INSERT INTO SceneNotes (Id, UserId, MediaItemId, StartMilliseconds, Text, Revision)
                    VALUES ({noteId}, {userId}, {mediaId}, 1000, 'Existing note', 1);
                    """);

                // Upgrade to latest migration.
                await db.Database.MigrateAsync();

                // Verify ProfilePhotos.UpdatedAt is now stored as SQLite INTEGER Unix-ms with exact millisecond precision.
                await using (var conn = new SqliteConnection($"Data Source={dbPath};Pooling=False"))
                {
                    await conn.OpenAsync();
                    await using var cmd = conn.CreateCommand();
                    cmd.CommandText = "SELECT typeof(UpdatedAt), UpdatedAt FROM ProfilePhotos;";
                    await using var reader = await cmd.ExecuteReaderAsync();
                    Assert.True(await reader.ReadAsync());
                    Assert.Equal("integer", reader.GetString(0));
                    Assert.Equal(new DateTimeOffset(2026, 11, 7, 17, 38, 36, 123, TimeSpan.Zero).ToUnixTimeMilliseconds(), reader.GetInt64(1));
                }

                var photo = await db.ProfilePhotos.AsNoTracking().SingleAsync();
                Assert.Equal(new DateTimeOffset(2026, 11, 7, 17, 38, 36, 123, TimeSpan.Zero), photo.UpdatedAt);

                // Existing mutation receipts were backfilled with non-zero CreatedAt timestamps.
                Assert.True((await db.LibraryStateMutations.AsNoTracking().SingleAsync()).CreatedAt.ToUnixTimeMilliseconds() > 0);
                Assert.True((await db.LibraryMutations.AsNoTracking().SingleAsync()).CreatedAt.ToUnixTimeMilliseconds() > 0);

                // Two profiles can share the same SceneNote GUID via composite PK (UserId, Id).
                db.SceneNotes.Add(new SceneNote { Id = noteId, UserId = user2Id, MediaItemId = mediaId, StartMilliseconds = 2000, Text = "Second user note" });
                await db.SaveChangesAsync();
                Assert.Equal(2, await db.SceneNotes.CountAsync());

                // Remove second user's duplicate before verifying clean downgrade.
                await db.SceneNotes.Where(n => n.UserId == user2Id).ExecuteDeleteAsync();
                await db.Database.GetService<IMigrator>().MigrateAsync("20261117214942_RemoveSmartHome");

                await using (var conn = new SqliteConnection($"Data Source={dbPath};Pooling=False"))
                {
                    await conn.OpenAsync();
                    await using var cmd = conn.CreateCommand();
                    cmd.CommandText = "SELECT typeof(UpdatedAt), UpdatedAt FROM ProfilePhotos;";
                    await using var reader = await cmd.ExecuteReaderAsync();
                    Assert.True(await reader.ReadAsync());
                    Assert.Equal("text", reader.GetString(0));
                    Assert.StartsWith("2026-11-07 17:38:36.123", reader.GetString(1), StringComparison.Ordinal);
                }
            }
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task SqliteWriteModeSetsPragmasOncePerPooledNativeConnection()
    {
        // SRV-DATA-013: Pooled opens reuse the same native sqlite3 handle without re-running WAL pragmas.
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var dbPath = Path.Combine(root, "pooled.db");
        var connectionString = $"Data Source={dbPath};Pooling=True";
        try
        {
            await using (var setup = new SqliteConnection(connectionString))
            {
                await setup.OpenAsync();
                await using var cmd = setup.CreateCommand();
                cmd.CommandText = "PRAGMA journal_mode=WAL; CREATE TABLE T(Id INTEGER PRIMARY KEY);";
                await cmd.ExecuteNonQueryAsync();
            }

            var writeMode = new SqliteWriteMode();
            var options = new DbContextOptionsBuilder<TarvenDbContext>()
                .UseSqlite(connectionString)
                .AddInterceptors(writeMode)
                .Options;

            for (var i = 0; i < 5; i++)
            {
                await using var db = new TarvenDbContext(options);
                await db.Database.ExecuteSqlRawAsync("SELECT 1;");
            }

            // First open sets PRAGMA synchronous=NORMAL; subsequent pooled opens skip both pragmas.
            Assert.Equal(1, writeMode.PragmaExecutions);

            await using (var verify = new SqliteConnection(connectionString))
            {
                await verify.OpenAsync();
                await using var cmd = verify.CreateCommand();
                cmd.CommandText = "PRAGMA synchronous;";
                // 1 == NORMAL
                Assert.Equal(1L, Convert.ToInt64(await cmd.ExecuteScalarAsync(), System.Globalization.CultureInfo.InvariantCulture));
            }
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void EpisodeParserFallsBackToEpisodeNumberInsteadOfRepeatingSeriesName()
    {
        // SRV-LIB-010: Missing episode title does not duplicate series name.
        var a = FilenameMetadataParser.Episode("Paper Lighthouse - S02E01.mkv", 2, "Paper Lighthouse");
        Assert.Equal((2, 1, "Episode 1"), (a.Season, a.Episode, a.Title));

        var b = FilenameMetadataParser.Episode("orbit.kitchen.1x04.720p.mkv", 1, "Orbit Kitchen");
        Assert.Equal((1, 4, "Episode 4"), (b.Season, b.Episode, b.Title));

        var c = FilenameMetadataParser.Episode("Paper Lighthouse (2020) - S02E03.mkv", 2, "Paper Lighthouse");
        Assert.Equal((2, 3, "Episode 3"), (c.Season, c.Episode, c.Title));

        var d = FilenameMetadataParser.Episode("Paper Lighthouse - S02E01 - Fog.mkv", 2, "Paper Lighthouse");
        Assert.Equal((2, 1, "Fog"), (d.Season, d.Episode, d.Title));

        // End-to-end scanner check for TvShows library.
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        try
        {
            var ep1 = Path.Combine(root, "Paper Lighthouse", "Season 2", "Paper Lighthouse - S02E01.mkv");
            var ep2 = Path.Combine(root, "Orbit Kitchen", "Season 1", "orbit.kitchen.1x04.720p.mkv");
            Directory.CreateDirectory(Path.GetDirectoryName(ep1)!);
            Directory.CreateDirectory(Path.GetDirectoryName(ep2)!);
            File.WriteAllBytes(ep1, [1, 2, 3, 4]);
            File.WriteAllBytes(ep2, [1, 2, 3, 4]);

            var scan = new MediaLibraryScanner().Scan(root, LibraryKind.TvShows, [], null, CancellationToken.None);
            var episodes = scan.Items.Where(i => i.Kind == MediaKind.Episode).ToDictionary(i => i.SourcePath, i => i.DetectedTitle);
            Assert.Equal("Episode 1", episodes[ep1]);
            Assert.Equal("Episode 4", episodes[ep2]);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void MediaProbeBlocksPlaylistContainersAndPlannerEmitsFormatWhitelist()
    {
        // SRV-PLAY-012: Playlist, manifest, metadata and image-sequence demuxers are disallowed.
        foreach (var bad in new[] { "hls", "applehttp", "hls,applehttp", "dash", "imf", "webm_dash_manifest", "ffmetadata", "image2", "image2pipe", "concat" })
        {
            Assert.True(MediaProbe.IsDisallowedContainer(bad), bad);
            Assert.Null(MediaProbe.SafeFormatWhitelist(bad));
        }

        Assert.Equal("matroska,webm", MediaProbe.SafeFormatWhitelist("matroska,webm"));
        Assert.Equal("mov,mp4,m4a,3gp,3g2,mj2", MediaProbe.SafeFormatWhitelist("mov,mp4,m4a,3gp,3g2,mj2"));
        Assert.Null(MediaProbe.SafeFormatWhitelist("mov;evil"));

        var args = LiveConversionPlanner.Arguments("/media/film.mkv",
            new LiveStreamOptions(0, new ProbedVideo(0, "h264", "High", 41, 1920, 1080, "yuv420p", 8), null, null, true, Container: "matroska,webm"));
        var whitelistIdx = args.ToList().IndexOf("-format_whitelist");
        var inputIdx = args.ToList().IndexOf("-i");
        Assert.True(whitelistIdx >= 0 && whitelistIdx < inputIdx);
        Assert.Equal("matroska,webm", args[whitelistIdx + 1]);
    }

    [Fact]
    public async Task DownloadTicketDoesNotCancelSleepTimerAndSidecarsDecodeCyrillicAndCentralEuropean()
    {
        // SRV-PLAY-014 (part 1): Download playback tickets do not cancel a pending sleep timer.
        var clock = new TestClock(DateTimeOffset.UtcNow);
        using var factory = new TarvenServerFactory(configureServices: services =>
        {
            services.AddSingleton<TimeProvider>(clock);
        });
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        var mediaRoot = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaRoot);
        var videoFile = Path.Combine(mediaRoot, "Sleep Film.mkv");
        await File.WriteAllBytesAsync(videoFile, [1, 2, 3, 4]);
        try
        {
            var movieId = await SeedMovieAsync(factory, "Sleep Film", mediaRoot, videoFile);
            var sleep = factory.Services.GetRequiredService<ServerSleepSignal>();

            sleep.SleepTimerEnded();
            using (var dlReq = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{movieId}/playback?purpose=download", owner.Token))
            using (var dlResp = await ApiTestClient.SendAsync(client, dlReq))
                dlResp.EnsureSuccessStatusCode();

            clock.Advance(TimeSpan.FromMinutes(6));
            Assert.True(sleep.Evaluate());

            // Starting real playback DOES cancel a pending sleep timer.
            sleep.SleepTimerEnded();
            using (var playReq = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{movieId}/playback?purpose=playback", owner.Token))
            using (var playResp = await ApiTestClient.SendAsync(client, playReq))
                playResp.EnsureSuccessStatusCode();

            clock.Advance(TimeSpan.FromMinutes(6));
            Assert.False(sleep.Evaluate());

            // SRV-PLAY-014 (part 2): CP1251 Cyrillic and CP1250 Central European SRTs decode cleanly.
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            const string russian = "1\n00:00:01,000 --> 00:00:03,000\nПривет, мир! Это проверка субтитров.\n";
            var cp1251 = Encoding.GetEncoding(1251).GetBytes(russian);
            Assert.Equal(russian, SidecarSubtitles.DecodeText(cp1251, "ru"));
            Assert.Equal(russian, SidecarSubtitles.DecodeText(cp1251)); // Unlabeled Cyrillic heuristic

            const string polish = "1\n00:00:01,000 --> 00:00:03,000\nZażółć gęślą jaźń\n";
            var cp1250Pl = Encoding.GetEncoding(1250).GetBytes(polish);
            Assert.Equal(polish, SidecarSubtitles.DecodeText(cp1250Pl, "pl"));

            const string czech = "1\n00:00:01,000 --> 00:00:03,000\nPříliš žluťoučký kůň\n";
            var cp1250Cs = Encoding.GetEncoding(1250).GetBytes(czech);
            Assert.Equal(czech, SidecarSubtitles.DecodeText(cp1250Cs, "cs"));

            // Sidecar ReadAsWebVttAsync infers trailing language tag from filename.
            var ruPath = Path.Combine(mediaRoot, "Sleep Film.ru.srt");
            var plPath = Path.Combine(mediaRoot, "Sleep Film.pl.srt");
            await File.WriteAllBytesAsync(ruPath, cp1251);
            await File.WriteAllBytesAsync(plPath, cp1250Pl);
            Assert.Contains("Привет, мир!", Encoding.UTF8.GetString(await SidecarSubtitles.ReadAsWebVttAsync(ruPath, CancellationToken.None)), StringComparison.Ordinal);
            Assert.Contains("Zażółć gęślą jaźń", Encoding.UTF8.GetString(await SidecarSubtitles.ReadAsWebVttAsync(plPath, CancellationToken.None)), StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(mediaRoot, recursive: true);
        }
    }

    private static async Task<string> IssueSeparateDeviceProfileTokenAsync(TarvenServerFactory factory, Guid userId)
    {
        var sessionId = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow;
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
            var tokens = scope.ServiceProvider.GetRequiredService<TokenService>();
            var user = await db.Users.SingleAsync(u => u.Id == userId);
            db.DeviceSessions.Add(new DeviceSession
            {
                Id = sessionId,
                UserId = userId,
                User = user,
                DeviceName = "Synthetic Test Device",
                TokenHash = tokens.Hash(tokens.CreateDeviceToken()),
                CreatedAt = now,
                LastSeenAt = now,
                ExpiresAt = now.AddDays(30),
            });
            await db.SaveChangesAsync();
        }
        return factory.Services.GetRequiredService<ProfileSessionStore>().Issue(sessionId, userId).Token;
    }

    private static async Task<Guid> SeedMovieAsync(TarvenServerFactory factory, string title, string? rootPath = null, string? filePath = null)
    {
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Synthetic Movies",
            Path = rootPath ?? "/synthetic/movies",
            NormalizedPath = MediaPath.Normalize(rootPath ?? "/synthetic/movies"),
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
        };
        var movie = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRootId = library.Id,
            LibraryRoot = library,
            Kind = MediaKind.Movie,
            DetectedTitle = title,
            SourcePath = filePath ?? $"/synthetic/movies/{title}.mkv",
            NormalizedSourcePath = MediaPath.Normalize(filePath ?? $"/synthetic/movies/{title}.mkv"),
            Extension = ".mkv",
            Availability = MediaAvailability.Available,
            FileSize = 1024,
        };
        db.LibraryRoots.Add(library);
        db.MediaItems.Add(movie);
        await db.SaveChangesAsync();
        return movie.Id;
    }

    private sealed class TestClock(DateTimeOffset initial) : TimeProvider
    {
        private DateTimeOffset current = initial;
        public override DateTimeOffset GetUtcNow() => current;
        public void Advance(TimeSpan delta) => current = current.Add(delta);
    }

    private sealed class RecordingLogger<T> : ILogger<T>
    {
        public int WarningCount { get; private set; }
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (logLevel == LogLevel.Warning) WarningCount++;
        }
    }

    private sealed class FlakyScopeFactory : IServiceScopeFactory
    {
        public bool ShouldFail { get; set; }
        public IServiceScopeFactory? Inner { get; set; }
        public IServiceScope CreateScope()
        {
            if (ShouldFail) throw new InvalidOperationException("Simulated SQLite busy failure");
            return Inner!.CreateScope();
        }
    }
}
