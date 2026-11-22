using System.Net;
using System.Net.Http.Json;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ApiErrorHandlingTests
{
    [Fact]
    public async Task RestoringExclusionWhileScanIsActiveReturns409InsteadOf500()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var rootDir = Path.Combine(TestPaths.CreateDataDirectory(), "ExclusionBusy");
        Directory.CreateDirectory(rootDir);
        try
        {
            Guid libraryId;
            Guid exclusionId;
            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var now = DateTimeOffset.UtcNow;
                var root = new LibraryRoot
                {
                    Id = Guid.NewGuid(),
                    Name = "Busy Library",
                    Path = rootDir,
                    NormalizedPath = MediaPath.Normalize(rootDir),
                    Kind = LibraryKind.Movies,
                    Availability = LibraryAvailability.Available,
                    CreatedAt = now,
                };
                libraryId = root.Id;
                var exclusion = new MediaExclusion
                {
                    Id = Guid.NewGuid(),
                    LibraryRootId = libraryId,
                    RelativePath = "Skipped.mkv",
                    NormalizedSourcePath = Path.Combine(rootDir, "Skipped.mkv"),
                    IsDirectory = false,
                };
                exclusionId = exclusion.Id;
                db.LibraryRoots.Add(root);
                db.MediaExclusions.Add(exclusion);
                db.LibraryScans.Add(new LibraryScan
                {
                    Id = Guid.NewGuid(),
                    LibraryRootId = libraryId,
                    State = LibraryScanState.Running,
                    Trigger = LibraryScanTrigger.Manual,
                    CreatedAt = now,
                });
                await db.SaveChangesAsync();
            }

            using var request = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/libraries/{libraryId}/exclusions/{exclusionId}", owner.Token);
            using var response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
            var problem = await ApiTestClient.ReadAsync<ApiProblem>(response);
            Assert.Equal("library_scan_active", problem.Code);

            // Because the scan was already active, the exclusion was kept intact.
            using var verifyScope = factory.Services.CreateScope();
            var verifyDb = verifyScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.True(await verifyDb.MediaExclusions.AnyAsync(item => item.Id == exclusionId));
        }
        finally { Directory.Delete(Path.GetDirectoryName(rootDir)!, recursive: true); }
    }

    [Fact]
    public async Task RetryingUnknownMetadataJobReturnsApiProblemInsteadOf500()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/metadata/jobs/{Guid.NewGuid()}/retry", owner.Token);
        using var response = await client.SendAsync(request);
        Assert.True(response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.NotFound or HttpStatusCode.Conflict,
            $"Expected 4xx ApiProblem, got {(int)response.StatusCode}");
        var problem = await ApiTestClient.ReadAsync<ApiProblem>(response);
        Assert.False(string.IsNullOrWhiteSpace(problem.Code));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("""{"name":null}""")]
    public async Task CreatingCollectionWithoutNameReturns400InsteadOf500(string json)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/collections", owner.Token);
        request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        var problem = await ApiTestClient.ReadAsync<ApiProblem>(response);
        Assert.Equal("invalid_collection", problem.Code);
    }

    [Fact]
    public void StorageFullErrorsAreDetectedForSqliteDbUpdateAndIoExceptions()
    {
        var sqliteFull = new SqliteException("SQLite Error 13: 'database or disk is full'.", 13);
        var wrapped = new DbUpdateException("Save failed", sqliteFull);
        var ioEnospc = new IOException("No space left on device", 28);
        var ioWinDiskFull = new IOException("Disk full", unchecked((int)0x80070070));
        var unrelatedSqlite = new SqliteException("SQLite Error 5: 'database is locked'.", 5);
        var unrelatedIo = new IOException("Broken pipe", 32);

        Assert.True(ServerStorageErrors.IsStorageFull(sqliteFull));
        Assert.True(ServerStorageErrors.IsStorageFull(wrapped));
        Assert.True(ServerStorageErrors.IsStorageFull(ioEnospc));
        Assert.True(ServerStorageErrors.IsStorageFull(ioWinDiskFull));
        Assert.False(ServerStorageErrors.IsStorageFull(unrelatedSqlite));
        Assert.False(ServerStorageErrors.IsStorageFull(unrelatedIo));
    }

    [Fact]
    public async Task LibraryPathOverlappingServerDataDirectoryIsRejected()
    {
        var outer = TestPaths.CreateDataDirectory();
        var dataDir = Path.Combine(outer, ".srv-data");
        var insideData = Path.Combine(dataDir, "media");
        Directory.CreateDirectory(insideData);
        try
        {
            using var factory = new AureliaServerFactory(dataDir);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            foreach (var badPath in new[] { outer, dataDir, insideData })
            {
                using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries", owner.Token,
                    new CreateLibraryRequest("Bad", badPath, LibraryKind.Movies));
                using var response = await client.SendAsync(request);
                Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
                var problem = await ApiTestClient.ReadAsync<ApiProblem>(response);
                Assert.Equal("library_overlaps_server_data", problem.Code);
            }
        }
        finally { Directory.Delete(outer, recursive: true); }
    }

    [Fact]
    public async Task LibraryPathWithNulCharacterReturns400InsteadOf500()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries", owner.Token,
            new CreateLibraryRequest("Bad", "/tmp/bad\0path", LibraryKind.Movies));
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        var problem = await ApiTestClient.ReadAsync<ApiProblem>(response);
        Assert.Equal("invalid_library_path", problem.Code);
    }

    [Fact]
    public void LibraryWatcherIgnoresServerDataDirectoryAndHiddenFolders()
    {
        var root = "/media/home";
        var dataDir = "/media/home/aurelia-data";
        Assert.False(LibraryMonitoringService.IsRelevant(root, "/media/home/aurelia-data/work", dataDir));
        Assert.False(LibraryMonitoringService.IsRelevant(root, "/media/home/aurelia-data/last-use", dataDir));
        Assert.False(LibraryMonitoringService.IsRelevant(root, "/media/home/.srv-data/work", "/other/data"));
        Assert.False(LibraryMonitoringService.IsRelevant(root, "/media/home/.git/HEAD", "/other/data"));
        Assert.True(LibraryMonitoringService.IsRelevant(root, "/media/home/Movies/Film.mkv", dataDir));
        Assert.True(LibraryMonitoringService.IsRelevant(root, "/media/home/Movies/New Season", dataDir));
    }

    [Fact]
    public async Task ApiValidationGuardsRejectEmptyBodiesBadMetadataControlCharsConflictingAgeLimitAndDuplicateUploads()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // DYN-API-004: control and bidi-override characters rejected in collections and wishes.
        using (var badCol = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/collections", owner.Token,
            new SaveCollectionRequest("Evil\u202EName")))
        using (var resp = await client.SendAsync(badCol))
        {
            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
            Assert.Equal("invalid_collection", (await ApiTestClient.ReadAsync<ApiProblem>(resp)).Code);
        }

        using (var badWish = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/wishes", owner.Token,
            new CreateWishRequest(MediaKind.Movie, "Bad\u0007Title")))
        using (var resp = await client.SendAsync(badWish))
        {
            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
            Assert.Equal("invalid_wish_title", (await ApiTestClient.ReadAsync<ApiProblem>(resp)).Code);
        }

        // DYN-API-005: ageLimit combined with selectedTitles or titleIds returns 400.
        using (var conflictKid = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("KidConflict", null, UserRole.User, null, PinProtectionEnabled: false,
                AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: [Guid.NewGuid()], AgeLimit: 12)))
        using (var resp = await client.SendAsync(conflictKid))
        {
            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
            Assert.Equal("invalid_profile_access", (await ApiTestClient.ReadAsync<ApiProblem>(resp)).Code);
        }

        // DYN-API-008: duplicate backup upload ID returns 409 backup_upload_exists (not 507).
        var uploadId = Guid.NewGuid();
        using (var first = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/server/backups/uploads/{uploadId}", owner.Token))
        {
            first.Content = new ByteArrayContent([1, 2, 3, 4]);
            using var resp = await client.SendAsync(first);
            Assert.Equal(HttpStatusCode.NoContent, resp.StatusCode);
        }
        using (var second = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/server/backups/uploads/{uploadId}", owner.Token))
        {
            second.Content = new ByteArrayContent([1, 2, 3, 4]);
            using var resp = await client.SendAsync(second);
            Assert.Equal(HttpStatusCode.Conflict, resp.StatusCode);
            Assert.Equal("backup_upload_exists", (await ApiTestClient.ReadAsync<ApiProblem>(resp)).Code);
        }

        // SRV-API-006 & SRV-API-009: metadata provider empty body / unsupported language / bad job mode return 400 (no Build 9 text).
        using (var emptyProvider = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/metadata/provider", owner.Token))
        {
            emptyProvider.Content = new StringContent("{}", Encoding.UTF8, "application/json");
            using var resp = await client.SendAsync(emptyProvider);
            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
            var problem = await ApiTestClient.ReadAsync<ApiProblem>(resp);
            Assert.Equal("unsupported_metadata_language", problem.Code);
            Assert.DoesNotContain("Build 9", problem.Message, StringComparison.Ordinal);
        }

        using (var badJob = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/metadata/jobs", owner.Token))
        {
            badJob.Content = new StringContent("""{"mode":"nope"}""", Encoding.UTF8, "application/json");
            using var resp = await client.SendAsync(badJob);
            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
            Assert.Equal("invalid_metadata_job", (await ApiTestClient.ReadAsync<ApiProblem>(resp)).Code);
        }

        // SRV-API-007: missing required query parameter returns 400 with ApiProblem body.
        using (var missingQuery = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/devices/player/commands", owner.Token))
        using (var resp = await client.SendAsync(missingQuery))
        {
            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
            Assert.Equal("invalid_request", (await ApiTestClient.ReadAsync<ApiProblem>(resp)).Code);
        }

        // SRV-API-008: uniform pagination validation and X-Total-Count header on health lists.
        foreach (var badPage in new[]
        {
            "/api/v1/history?limit=0",
            "/api/v1/history?offset=-1",
            "/api/v1/people?limit=1000",
            "/api/v1/library/health/offline?days=-1",
            "/api/v1/library/health/duplicates?offset=-1",
            "/api/v1/library/health/files?limit=0",
        })
        {
            using var req = ApiTestClient.Authorized(HttpMethod.Get, badPage, owner.Token);
            using var resp = await client.SendAsync(req);
            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
            Assert.Equal("invalid_page", (await ApiTestClient.ReadAsync<ApiProblem>(resp)).Code);
        }

        using (var healthDup = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/library/health/duplicates", owner.Token))
        using (var resp = await client.SendAsync(healthDup))
        {
            resp.EnsureSuccessStatusCode();
            Assert.True(resp.Headers.Contains("X-Total-Count"));
        }

        // SRV-API-010: empty {} body on settings/favorite endpoints returns 400 instead of toggling to false.
        foreach (var path in new[]
        {
            "/api/v1/server/media-segments",
            "/api/v1/server/file-checks",
            $"/api/v1/media/{Guid.NewGuid()}/favorite",
        })
        {
            using var req = ApiTestClient.Authorized(HttpMethod.Put, path, owner.Token);
            req.Content = new StringContent("{}", Encoding.UTF8, "application/json");
            using var resp = await client.SendAsync(req);
            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
            var problem = await ApiTestClient.ReadAsync<ApiProblem>(resp);
            Assert.False(string.IsNullOrWhiteSpace(problem.Code));
        }

        // MAIN-006: EnsureApiSuccessAsync parses ApiProblem instead of dumping raw HTTP status text.
        using var problemResponse = new HttpResponseMessage(HttpStatusCode.BadRequest)
        {
            Content = new StringContent("""{"code":"invalid_pin_format","message":"Enter a 4 to 8 digit PIN."}""", Encoding.UTF8, "application/json"),
        };
        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            CommandClientSecurity.EnsureApiSuccessAsync(problemResponse, CancellationToken.None));
        Assert.Contains("invalid_pin_format", ex.Message, StringComparison.Ordinal);
        Assert.Contains("Enter a 4 to 8 digit PIN.", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConcurrentWishSupportCallsSucceedIdempotently()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var createViewer = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("Viewer", null, UserRole.User, null, PinProtectionEnabled: false,
                AccessMode: ProfileAccessMode.EntireLibrary));
        using var viewerResp = await client.SendAsync(createViewer);
        viewerResp.EnsureSuccessStatusCode();
        var viewer = await ApiTestClient.ReadAsync<UserSummary>(viewerResp);

        using var loginResp = await client.PostAsJsonAsync("/api/v1/auth/login",
            new LoginRequest(owner.User.Username, "correct horse battery staple", "Test Device"), ApiTestClient.JsonOptions);
        loginResp.EnsureSuccessStatusCode();
        var deviceAuth = await ApiTestClient.ReadAsync<AuthenticationResponse>(loginResp);

        using var unlockReq = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/profiles/{viewer.Id}/unlock", deviceAuth.Token,
            new UnlockProfileRequest(null));
        using var unlockResp = await client.SendAsync(unlockReq);
        unlockResp.EnsureSuccessStatusCode();
        var viewerSession = await ApiTestClient.ReadAsync<ProfileSessionResponse>(unlockResp);

        using var wishReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/wishes", owner.Token,
            new CreateWishRequest(MediaKind.Movie, "Concurrent Wish"));
        using var wishResp = await client.SendAsync(wishReq);
        wishResp.EnsureSuccessStatusCode();
        var created = await ApiTestClient.ReadAsync<CreateWishResponse>(wishResp);

        var tasks = Enumerable.Range(0, 12).Select(async _ =>
        {
            using var req = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/wishes/{created.Wish.Id}/support",
                viewerSession.Token, new SetWishSupportRequest(true));
            using var resp = await client.SendAsync(req);
            return resp.StatusCode;
        });
        var statuses = await Task.WhenAll(tasks);
        Assert.All(statuses, status => Assert.Equal(HttpStatusCode.OK, status));
    }
}
