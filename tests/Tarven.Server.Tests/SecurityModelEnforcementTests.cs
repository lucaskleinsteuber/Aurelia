using System.Net;
using System.Net.Http.Json;
using Tarven.Contracts;
using Tarven.Server.Authentication;
using Tarven.Server.Data;
using Tarven.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Tarven.Server.Tests;

public sealed class SecurityModelEnforcementTests
{
    [Fact]
    public async Task ViewerProfileRefusedForAdminActionsWithForbidden()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // Create a regular viewer profile
        using var createReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token, new CreateUserRequest("test-viewer", "", UserRole.User, null));
        using var createResp = await ApiTestClient.SendAsync(client, createReq);
        createResp.EnsureSuccessStatusCode();
        var viewerSummary = await ApiTestClient.ReadAsync<UserSummary>(createResp);

        var sessions = factory.Services.GetRequiredService<ProfileSessionStore>();
        var viewer = sessions.Issue(owner.SessionId, viewerSummary.Id);

        // Attempt Admin action: Add storage location
        using var addStorage = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries", viewer.Token,
            new CreateLibraryRequest("Synthetic Storage", "/tmp/synthetic-test-storage", LibraryKind.Movies));
        using var addStorageResponse = await client.SendAsync(addStorage);
        Assert.Equal(HttpStatusCode.Forbidden, addStorageResponse.StatusCode);

        // Attempt Admin action: TMDB API key update
        using var tmdb = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/metadata/provider", viewer.Token,
            new UpdateMetadataProviderRequest(true, "en-US", "synthetic-key"));
        using var tmdbResponse = await client.SendAsync(tmdb);
        Assert.Equal(HttpStatusCode.Forbidden, tmdbResponse.StatusCode);

        // Attempt Admin action: Server settings update
        var currentSettings = factory.Services.GetRequiredService<ServerConfigurationStore>().Current;
        using var settings = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/server/settings", viewer.Token, currentSettings);
        using var settingsResponse = await client.SendAsync(settings);
        Assert.Equal(HttpStatusCode.Forbidden, settingsResponse.StatusCode);
    }

    [Fact]
    public async Task AdminProfileAllowedForAdminActionsWithoutPasswordUnlock()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // Create an administrator profile with full library access (admins require a PIN)
        using var createReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("test-admin", "", UserRole.Admin, ApiTestClient.TestPin, AccessMode: ProfileAccessMode.EntireLibrary));
        using var createResp = await ApiTestClient.SendAsync(client, createReq);
        createResp.EnsureSuccessStatusCode();
        var adminSummary = await ApiTestClient.ReadAsync<UserSummary>(createResp);

        var sessionStore = factory.Services.GetRequiredService<ProfileSessionStore>();
        var admin = sessionStore.Issue(owner.SessionId, adminSummary.Id);
        var adminToken = admin.Token;

        // Verify management is NOT unlocked for this admin session
        Assert.False(sessionStore.ManagementUnlocked(admin.Session.Id));

        // 1. Admin action: Get server health metrics (NO unlock)
        using var healthReq = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/health", adminToken);
        using var healthResp = await client.SendAsync(healthReq);
        healthResp.EnsureSuccessStatusCode();

        // 2. Admin action: TMDB provider settings update (NO unlock, NO approval)
        using var tmdbReq = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/metadata/provider", adminToken,
            new UpdateMetadataProviderRequest(false, "en-US", null));
        using var tmdbResp = await client.SendAsync(tmdbReq);
        tmdbResp.EnsureSuccessStatusCode();

        // 3. Admin action: Add storage location (NO unlock, NO approval)
        var storageParent = TestPaths.CreateDataDirectory();
        var storageDir = Path.Combine(storageParent, "admin-added-storage");
        try
        {
            Directory.CreateDirectory(storageDir);
            using var addStorageReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries", adminToken,
                new CreateLibraryRequest("Admin Added Storage", storageDir, LibraryKind.Movies));
            using var addStorageResp = await client.SendAsync(addStorageReq);
            addStorageResp.EnsureSuccessStatusCode();
        }
        finally
        {
            if (Directory.Exists(storageParent)) Directory.Delete(storageParent, recursive: true);
        }
    }

    [Fact]
    public async Task CriticalActionDemandsServerPasswordAndSucceedsWithApproval()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // Seed a storage location so library reset has a target
        var rootId = Guid.NewGuid();
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
            var root = new LibraryRoot { Id = rootId, Name = "Reset Target", Path = "/tmp/reset-target", NormalizedPath = "/tmp/reset-target", Kind = LibraryKind.Movies };
            db.LibraryRoots.Add(root);
            await db.SaveChangesAsync();
        }

        // Preview reset to get current revision
        using var previewReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset/preview", owner.Token, new[] { rootId });
        using var previewResp = await client.SendAsync(previewReq);
        previewResp.EnsureSuccessStatusCode();
        var preview = await ApiTestClient.ReadAsync<ResetLibraryPreview>(previewResp);

        var resetBody = new ResetLibraryRequest([rootId], preview.Revision);

        // Critical action: Library reset without approval -> rejected with approval_required
        using (var proofless = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset", owner.Token, resetBody))
        using (var response = await client.SendAsync(proofless))
        {
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
            Assert.Equal("approval_required", (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
        }

        // Unlock management with server password first
        using var unlockReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/unlock", owner.Token,
            new UnlockManagementRequest("correct horse battery staple"));
        using var unlockResp = await client.SendAsync(unlockReq);
        unlockResp.EnsureSuccessStatusCode();

        // Obtain approval for the exact action and payload hash
        var payloadBytes = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(resetBody, ApiTestClient.JsonOptions);
        using var approvalReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset/approval", owner.Token,
            new AdministrationApprovalRequest("POST /api/v1/libraries/reset", AdministrationApprovalStore.Hash(payloadBytes)));
        using var approvalResp = await client.SendAsync(approvalReq);
        approvalResp.EnsureSuccessStatusCode();
        var approval = await ApiTestClient.ReadAsync<AdministrationApprovalResponse>(approvalResp);

        // Execute critical action with the obtained X-Tarven-Approval
        using var resetReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset", owner.Token, resetBody);
        resetReq.Headers.Add("X-Tarven-Approval", approval.Token);
        using var resetResp = await client.SendAsync(resetReq);
        resetResp.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task NonCriticalAdminActionsAcceptOlderClientApprovalHeaderGracefully()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // Older client sends a dummy or valid approval header to a non-critical endpoint (e.g. POST /api/v1/users)
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("compat-viewer", "", UserRole.User, null));
        request.Headers.Add("X-Tarven-Approval", "legacy-client-approval-token-ignored-cleanly");
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        var created = await ApiTestClient.ReadAsync<UserSummary>(response);
        Assert.Equal("compat-viewer", created.Username);
    }

    [Fact]
    public async Task WatchlistAndPreferencesArePureViewerActionsNeverRequiringUnlock()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // Seed a media item
        var mediaId = Guid.NewGuid();
        var rootId = Guid.NewGuid();
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
            var root = new LibraryRoot { Id = rootId, Name = "Synth", Path = "/tmp/test", NormalizedPath = "/tmp/test", Kind = LibraryKind.Movies };
            db.LibraryRoots.Add(root);
            var item = new MediaItem
            {
                Id = mediaId,
                LibraryRootId = root.Id,
                DetectedTitle = "Test Watchlist Movie",
                SourcePath = "/tmp/test/movie.mp4",
                NormalizedSourcePath = "/tmp/test/movie.mp4",
                Kind = MediaKind.Movie,
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow
            };
            db.MediaItems.Add(item);
            await db.SaveChangesAsync();
        }

        // Create a regular viewer
        using var createReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token, new CreateUserRequest("movie-viewer", "", UserRole.User, null));
        using var createResp = await ApiTestClient.SendAsync(client, createReq);
        createResp.EnsureSuccessStatusCode();
        var viewerSummary = await ApiTestClient.ReadAsync<UserSummary>(createResp);

        // Grant library access to viewer
        await ApiTestClient.GrantExistingLibrariesAsync(client, owner.Token, viewerSummary.Id);

        var sessions = factory.Services.GetRequiredService<ProfileSessionStore>();
        var viewer = sessions.Issue(owner.SessionId, viewerSummary.Id);

        // Viewer adds movie to watchlist via PUT /api/v1/media/{id}/watchlist
        using var addWatchlist = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{mediaId}/watchlist", viewer.Token, new SetWatchlistRequest(true));
        using var addResponse = await client.SendAsync(addWatchlist);
        addResponse.EnsureSuccessStatusCode();

        // Viewer fetches watchlist via GET /api/v1/watchlist
        using var getWatchlist = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/watchlist", viewer.Token);
        using var getResponse = await client.SendAsync(getWatchlist);
        getResponse.EnsureSuccessStatusCode();
        var list = await ApiTestClient.ReadAsync<WatchlistResponse>(getResponse);
        Assert.Single(list.Items);
        Assert.Equal(mediaId, list.Items[0].Id);

        // Viewer removes from watchlist via PUT /api/v1/media/{id}/watchlist with false
        using var delWatchlist = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{mediaId}/watchlist", viewer.Token, new SetWatchlistRequest(false));
        using var delResponse = await client.SendAsync(delWatchlist);
        delResponse.EnsureSuccessStatusCode();
    }

    // Audit S-M1: with only an owner's PIN, no other way may make a new owner or administrator, change
    // a role or switch an owner off. Each needs the Server Password like PUT /users/{id}/role.
    [Fact]
    public async Task EveryWayToChangeWhoManagesNeedsTheServerPassword()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        static async Task<HttpResponseMessage> Send(HttpClient http, HttpRequestMessage request)
        {
            using (request) return await http.SendAsync(request);
        }
        static async Task<string?> Refusal(HttpResponseMessage response) =>
            response.StatusCode == HttpStatusCode.Forbidden ? (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code : null;

        using (var elevated = await Send(client, ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                   new CreateUserRequest("Synthetic Admin", null, UserRole.Admin, ApiTestClient.TestPin))))
            Assert.Equal("approval_required", await Refusal(elevated));
        using var created = await Send(client, ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("Synthetic Viewer", null, UserRole.User, ApiTestClient.TestPin)));
        created.EnsureSuccessStatusCode();
        var viewer = await ApiTestClient.ReadAsync<UserSummary>(created);

        using var editorResponse = await Send(client, ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/users/{viewer.Id}/profile", owner.Token));
        var editor = await ApiTestClient.ReadAsync<ProfileEditorResponse>(editorResponse);
        using (var promote = await Send(client, ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{viewer.Id}/profile", owner.Token,
                   new UpdateProfileRequest(editor.Revision, UserRole.Owner, true, true))))
            Assert.Equal("approval_required", await Refusal(promote));
        using (var unchanged = await Send(client, ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{viewer.Id}/profile", owner.Token,
                   new UpdateProfileRequest(editor.Revision, UserRole.User, true, true, "5678"))))
            unchanged.EnsureSuccessStatusCode();

        using (var switchOff = await Send(client, ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{owner.User.Id}/enabled", owner.Token,
                   new SetProfileEnabledRequest(false))))
            Assert.Equal("approval_required", await Refusal(switchOff));
        using (var viewerOff = await Send(client, ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{viewer.Id}/enabled", owner.Token,
                   new SetProfileEnabledRequest(false))))
            Assert.NotEqual("approval_required", await Refusal(viewerOff));

        // The real clients ask for the approval when refused; with it the same change goes through.
        using var approved = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("Approved Admin", null, UserRole.Admin, ApiTestClient.TestPin));
        using var approvedResponse = await ApiTestClient.SendAsync(client, approved);
        approvedResponse.EnsureSuccessStatusCode();
    }

    // Audit 2026-11-21 (SRV-SEC-001): the endpoints bind property names in any case and keep one of
    // repeated names, so "Role", "ROLE" or a second "role" must not slip past the Server Password.
    [Fact]
    public async Task AnySpellingOrCopyOfAFieldStillNeedsTheServerPassword()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        async Task<HttpResponseMessage> SendRaw(HttpMethod method, string path, string json)
        {
            using var request = ApiTestClient.Authorized(method, path, owner.Token);
            request.Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");
            return await client.SendAsync(request);
        }
        static async Task<string?> Refusal(HttpResponseMessage response) =>
            response.StatusCode == HttpStatusCode.Forbidden ? (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code : null;
        var pin = ApiTestClient.TestPin;

        foreach (var (name, json) in new[]
        {
            ("Role admin", $$"""{"username":"Synthetic A","password":null,"Role":"admin","pin":"{{pin}}"}"""),
            ("ROLE owner", $$"""{"username":"Synthetic B","password":null,"ROLE":"owner","pin":"{{pin}}"}"""),
            ("repeated role", $$"""{"username":"Synthetic C","password":null,"role":"user","Role":"owner","pin":"{{pin}}"}"""),
            ("repeated lowercase role", $$"""{"username":"Synthetic D","password":null,"role":"user","role":"admin","pin":"{{pin}}"}"""),
        })
        {
            using var response = await SendRaw(HttpMethod.Post, "/api/v1/users", json);
            Assert.True("approval_required" == await Refusal(response), $"{name}: {(int)response.StatusCode}");
        }
        using (var plain = await SendRaw(HttpMethod.Post, "/api/v1/users",
                   $$"""{"Username":"Synthetic Viewer","Password":null,"Role":"user","Pin":"{{pin}}"}"""))
            plain.EnsureSuccessStatusCode();

        using (var switchOff = await SendRaw(HttpMethod.Put, $"/api/v1/users/{owner.User.Id}/enabled", """{"IsEnabled":false}"""))
            Assert.Equal("approval_required", await Refusal(switchOff));
        using (var repeated = await SendRaw(HttpMethod.Put, $"/api/v1/users/{owner.User.Id}/enabled", """{"isEnabled":true,"ISENABLED":false}"""))
            Assert.Equal("approval_required", await Refusal(repeated));

        // A body that is not an object can't bind; it is refused as bad input, never with a 500.
        using (var array = await SendRaw(HttpMethod.Post, "/api/v1/users", "[]"))
            Assert.Equal(HttpStatusCode.BadRequest, array.StatusCode);
        using (var text = await SendRaw(HttpMethod.Put, $"/api/v1/users/{owner.User.Id}/enabled", "\"off\""))
            Assert.Equal(HttpStatusCode.BadRequest, text.StatusCode);

        using var users = await client.SendAsync(ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/users", owner.Token));
        var all = await ApiTestClient.ReadAsync<List<UserSummary>>(users);
        Assert.DoesNotContain(all, user => user.Username.StartsWith("Synthetic ", StringComparison.Ordinal) && user.Role != UserRole.User);
        Assert.Single(all, user => user.Role == UserRole.Owner);
    }

    [Theory]
    [InlineData("POST", "/api/v1/users", true)]
    [InlineData("PUT", "/api/v1/users/6f0c1c6e-8a3d-4d0c-9b55-111111111111/profile", true)]
    [InlineData("PUT", "/api/v1/users/6f0c1c6e-8a3d-4d0c-9b55-111111111111/enabled", true)]
    [InlineData("PUT", "/api/v1/users/6f0c1c6e-8a3d-4d0c-9b55-111111111111/access", true)]
    [InlineData("PUT", "/api/v1/users/6f0c1c6e-8a3d-4d0c-9b55-111111111111/titles", true)]
    [InlineData("PUT", "/api/v1/users/6f0c1c6e-8a3d-4d0c-9b55-111111111111/pin", true)]
    [InlineData("PUT", "/api/v1/users/6f0c1c6e-8a3d-4d0c-9b55-111111111111/name", false)]
    [InlineData("PUT", "/api/v1/users/6f0c1c6e-8a3d-4d0c-9b55-111111111111/screen-time", false)]
    [InlineData("GET", "/api/v1/users", false)]
    public void OnlyProfileChangesThatCanChangeWhoManagesAreLookedAt(string method, string path, bool looked)
        => Assert.Equal(looked, ServerRequestGuard.MayChangeWhoManages(method, path));

    // Audit SRV-SEC-003: revoking libraries or titles from an Owner or Admin profile requires
    // the Server Password (via /access, /titles, or /profile), while adding access, upgrading
    // to EntireLibrary, or revoking access on a regular User profile still works with PIN only.
    [Fact]
    public async Task RevokingLibrariesOrTitlesFromAdminOrOwnerNeedsTheServerPassword()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        var lib1Id = Guid.NewGuid();
        var lib2Id = Guid.NewGuid();
        var movie1Id = Guid.NewGuid();
        var movie2Id = Guid.NewGuid();
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
            var now = DateTimeOffset.UtcNow;
            db.LibraryRoots.AddRange(
                new LibraryRoot { Id = lib1Id, Name = "Synth Movies 1", Path = "/tmp/synth-lib-1", NormalizedPath = "/tmp/synth-lib-1", Kind = LibraryKind.Movies, CreatedAt = now },
                new LibraryRoot { Id = lib2Id, Name = "Synth Movies 2", Path = "/tmp/synth-lib-2", NormalizedPath = "/tmp/synth-lib-2", Kind = LibraryKind.Movies, CreatedAt = now });
            db.MediaItems.AddRange(
                new MediaItem { Id = movie1Id, LibraryRootId = lib1Id, Kind = MediaKind.Movie, DetectedTitle = "Synth Film 1", SourcePath = "/tmp/synth-lib-1/a.mkv", NormalizedSourcePath = "/tmp/synth-lib-1/a.mkv", Extension = ".mkv", CreatedAt = now, UpdatedAt = now },
                new MediaItem { Id = movie2Id, LibraryRootId = lib2Id, Kind = MediaKind.Movie, DetectedTitle = "Synth Film 2", SourcePath = "/tmp/synth-lib-2/b.mkv", NormalizedSourcePath = "/tmp/synth-lib-2/b.mkv", Extension = ".mkv", CreatedAt = now, UpdatedAt = now });
            await db.SaveChangesAsync();
        }

        UserSummary admin;
        using (var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                   new CreateUserRequest("Synthetic Admin", null, UserRole.Admin, ApiTestClient.TestPin, AccessMode: ProfileAccessMode.EntireLibrary)))
        using (var response = await ApiTestClient.SendAsync(client, create))
        {
            response.EnsureSuccessStatusCode();
            admin = await ApiTestClient.ReadAsync<UserSummary>(response);
        }

        UserSummary viewer;
        using (var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                   new CreateUserRequest("Synthetic Viewer", null, UserRole.User, ApiTestClient.TestPin, AccessMode: ProfileAccessMode.EntireLibrary)))
        using (var response = await ApiTestClient.SendAsync(client, create))
        {
            response.EnsureSuccessStatusCode();
            viewer = await ApiTestClient.ReadAsync<UserSummary>(response);
        }

        // Pair a second device and unlock the owner profile with PIN only (no /api/v1/management/unlock),
        // keeping the first device's unlocked management session active for approval tests.
        string pinOnlyOwner;
        using (var login = await client.PostAsJsonAsync("/api/v1/auth/login",
                   new LoginRequest("lucas", "correct horse battery staple", "PIN-Only Device"), ApiTestClient.JsonOptions))
        {
            login.EnsureSuccessStatusCode();
            var device = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
            using var unlock = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/profiles/{owner.User.Id}/unlock",
                device.Token, new UnlockProfileRequest(ApiTestClient.TestPin));
            using var unlockResp = await client.SendAsync(unlock);
            unlockResp.EnsureSuccessStatusCode();
            pinOnlyOwner = (await ApiTestClient.ReadAsync<ProfileSessionResponse>(unlockResp)).Token;
        }

        static async Task<string?> Refusal(HttpResponseMessage response) =>
            response.StatusCode == HttpStatusCode.Forbidden ? (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code : null;

        async Task<HttpResponseMessage> SendRaw(string token, HttpMethod method, string path, string json)
        {
            using var request = ApiTestClient.Authorized(method, path, token);
            request.Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");
            return await client.SendAsync(request);
        }

        async Task<ProfileTitleAccessResponse> ReadTitles(Guid userId)
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/users/{userId}/titles", pinOnlyOwner);
            using var response = await client.SendAsync(request);
            response.EnsureSuccessStatusCode();
            return await ApiTestClient.ReadAsync<ProfileTitleAccessResponse>(response);
        }

        // 1. PUT /api/v1/users/{adminId}/access with empty libraryIds -> refused without Server Password, succeeds with approval.
        using (var pinOnly = await SendRaw(pinOnlyOwner, HttpMethod.Put, $"/api/v1/users/{admin.Id}/access", """{"isEnabled":true,"libraryIds":[]}"""))
            Assert.Equal("management_locked", await Refusal(pinOnly));
        using (var proofless = await SendRaw(owner.Token, HttpMethod.Put, $"/api/v1/users/{admin.Id}/access", """{"isEnabled":true,"libraryIds":[]}"""))
            Assert.Equal("approval_required", await Refusal(proofless));
        using (var duplicateKey = await SendRaw(pinOnlyOwner, HttpMethod.Put, $"/api/v1/users/{admin.Id}/access",
                   $$"""{"isEnabled":true,"libraryIds":["{{lib1Id}}","{{lib2Id}}"],"LibraryIds":[]}"""))
            Assert.Equal("management_locked", await Refusal(duplicateKey));
        using (var ownerCut = await SendRaw(pinOnlyOwner, HttpMethod.Put, $"/api/v1/users/{owner.User.Id}/access", """{"isEnabled":true,"libraryIds":[]}"""))
            Assert.Equal("management_locked", await Refusal(ownerCut));

        using (var approvedAccess = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/access", owner.Token,
                   new UpdateUserAccessRequest(true, [])))
        using (var approvedResponse = await ApiTestClient.SendAsync(client, approvedAccess))
            Assert.Equal(HttpStatusCode.NoContent, approvedResponse.StatusCode);

        // Adding libraries to a LegacyLibraries admin does not revoke access and works with PIN only;
        // revoking one of those libraries requires the Server Password.
        using (var addLib1 = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/access", pinOnlyOwner,
                   new UpdateUserAccessRequest(true, [lib1Id])))
        using (var addLib1Response = await client.SendAsync(addLib1))
            Assert.Equal(HttpStatusCode.NoContent, addLib1Response.StatusCode);

        using (var addLib2 = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/access", pinOnlyOwner,
                   new UpdateUserAccessRequest(true, [lib1Id, lib2Id])))
        using (var addLib2Response = await client.SendAsync(addLib2))
            Assert.Equal(HttpStatusCode.NoContent, addLib2Response.StatusCode);

        using (var dropLib2 = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/access", pinOnlyOwner,
                   new UpdateUserAccessRequest(true, [lib1Id])))
        using (var dropLib2Response = await client.SendAsync(dropLib2))
            Assert.Equal("management_locked", await Refusal(dropLib2Response));

        // 2. Upgrading admin to EntireLibrary via PUT /users/{adminId}/titles works with PIN only.
        var titles = await ReadTitles(admin.Id);
        using (var upgrade = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/titles", pinOnlyOwner,
                   new UpdateProfileTitleAccessRequest(ProfileAccessMode.EntireLibrary, [], titles.Revision)))
        using (var upgradeResponse = await client.SendAsync(upgrade))
            Assert.Equal(HttpStatusCode.OK, upgradeResponse.StatusCode);

        // 3. Switching EntireLibrary admin to SelectedTitles via PUT /users/{adminId}/titles requires Server Password.
        titles = await ReadTitles(admin.Id);
        using (var restrictPinOnly = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/titles", pinOnlyOwner,
                   new UpdateProfileTitleAccessRequest(ProfileAccessMode.SelectedTitles, [], titles.Revision)))
        using (var restrictPinOnlyResponse = await client.SendAsync(restrictPinOnly))
            Assert.Equal("management_locked", await Refusal(restrictPinOnlyResponse));

        using (var restrictProofless = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/titles", owner.Token,
                   new UpdateProfileTitleAccessRequest(ProfileAccessMode.SelectedTitles, [], titles.Revision)))
        using (var restrictProoflessResponse = await client.SendAsync(restrictProofless))
            Assert.Equal("approval_required", await Refusal(restrictProoflessResponse));

        using (var duplicateMode = await SendRaw(pinOnlyOwner, HttpMethod.Put, $"/api/v1/users/{admin.Id}/titles",
                   $$"""{"mode":"entireLibrary","Mode":"selectedTitles","titleIds":[],"revision":{{titles.Revision}}}"""))
            Assert.Equal("management_locked", await Refusal(duplicateMode));

        using (var approvedTitles = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/titles", owner.Token,
                   new UpdateProfileTitleAccessRequest(ProfileAccessMode.SelectedTitles, [], titles.Revision)))
        using (var approvedTitlesResponse = await ApiTestClient.SendAsync(client, approvedTitles))
            Assert.Equal(HttpStatusCode.OK, approvedTitlesResponse.StatusCode);

        // 4. Adding titles to a SelectedTitles admin works with PIN only; revoking a single title requires Server Password.
        titles = await ReadTitles(admin.Id);
        using (var grantBoth = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/titles", pinOnlyOwner,
                   new UpdateProfileTitleAccessRequest(ProfileAccessMode.SelectedTitles, [movie1Id, movie2Id], titles.Revision)))
        using (var grantBothResponse = await client.SendAsync(grantBoth))
            Assert.Equal(HttpStatusCode.OK, grantBothResponse.StatusCode);

        titles = await ReadTitles(admin.Id);
        using (var revokeOne = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/titles", pinOnlyOwner,
                   new UpdateProfileTitleAccessRequest(ProfileAccessMode.SelectedTitles, [movie1Id], titles.Revision)))
        using (var revokeOneResponse = await client.SendAsync(revokeOne))
            Assert.Equal("management_locked", await Refusal(revokeOneResponse));

        using (var revokeOneApproved = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/titles", owner.Token,
                   new UpdateProfileTitleAccessRequest(ProfileAccessMode.SelectedTitles, [movie1Id], titles.Revision)))
        using (var revokeOneApprovedResponse = await ApiTestClient.SendAsync(client, revokeOneApproved))
            Assert.Equal(HttpStatusCode.OK, revokeOneApprovedResponse.StatusCode);

        // Upgrading SelectedTitles admin back to EntireLibrary succeeds without Server Password.
        titles = await ReadTitles(admin.Id);
        using (var backToEntire = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/titles", pinOnlyOwner,
                   new UpdateProfileTitleAccessRequest(ProfileAccessMode.EntireLibrary, [], titles.Revision)))
        using (var backToEntireResponse = await client.SendAsync(backToEntire))
            Assert.Equal(HttpStatusCode.OK, backToEntireResponse.StatusCode);

        // 5. PUT /api/v1/users/{adminId}/profile setting accessMode to selectedTitles requires Server Password.
        ProfileEditorResponse editor;
        using (var editorReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/users/{admin.Id}/profile", pinOnlyOwner))
        using (var editorResp = await client.SendAsync(editorReq))
        {
            editorResp.EnsureSuccessStatusCode();
            editor = await ApiTestClient.ReadAsync<ProfileEditorResponse>(editorResp);
        }
        using (var profileRestrict = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/profile", pinOnlyOwner,
                   new UpdateProfileRequest(editor.Revision, UserRole.Admin, true, true, AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: [])))
        using (var profileRestrictResp = await client.SendAsync(profileRestrict))
            Assert.Equal("management_locked", await Refusal(profileRestrictResp));

        // 6. Regular User profile: revoking libraries or titles works with PIN only.
        using (var viewerAccess = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{viewer.Id}/access", pinOnlyOwner,
                   new UpdateUserAccessRequest(true, [])))
        using (var viewerAccessResp = await client.SendAsync(viewerAccess))
            Assert.Equal(HttpStatusCode.NoContent, viewerAccessResp.StatusCode);

        var viewerTitles = await ReadTitles(viewer.Id);
        using (var viewerRestrict = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{viewer.Id}/titles", pinOnlyOwner,
                   new UpdateProfileTitleAccessRequest(ProfileAccessMode.SelectedTitles, [], viewerTitles.Revision)))
        using (var viewerRestrictResp = await client.SendAsync(viewerRestrict))
            Assert.Equal(HttpStatusCode.OK, viewerRestrictResp.StatusCode);
    }

    // Audit S-L5: one device with many IPv6 addresses counts once, and a full table never refuses
    // a new address: it forgets the one seen longest ago.
    [Fact]
    public void TheFloodGuardCountsADeviceOnceAndAlwaysAdmitsNewAddresses()
    {
        Assert.Equal(ServerRequestGuard.AddressKey(System.Net.IPAddress.Parse("2001:db8:1:2::aaaa")),
            ServerRequestGuard.AddressKey(System.Net.IPAddress.Parse("2001:db8:1:2:1234:5678:9abc:def0")));
        Assert.NotEqual(ServerRequestGuard.AddressKey(System.Net.IPAddress.Parse("2001:db8:1:2::1")),
            ServerRequestGuard.AddressKey(System.Net.IPAddress.Parse("2001:db8:1:3::1")));
        Assert.Equal("192.168.1.20", ServerRequestGuard.AddressKey(System.Net.IPAddress.Parse("::ffff:192.168.1.20")));

        var guard = new ServerRequestGuard();
        for (var index = 0; index < ServerRequestGuard.TrackedAddresses; index++)
            Assert.True(guard.Admit(new System.Net.IPAddress([10, 1, (byte)(index / 256), (byte)(index % 256)])));
        Assert.True(guard.Admit(System.Net.IPAddress.Parse("192.168.178.50")));
    }
}
