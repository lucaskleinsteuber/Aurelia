using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class SecurityModelEnforcementTests
{
    [Fact]
    public async Task ViewerProfileRefusedForAdminActionsWithForbidden()
    {
        using var factory = new AureliaServerFactory();
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
        using var factory = new AureliaServerFactory();
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
        var storageDir = Path.Combine(factory.DataDirectory, "admin-added-storage");
        Directory.CreateDirectory(storageDir);
        using var addStorageReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries", adminToken,
            new CreateLibraryRequest("Admin Added Storage", storageDir, LibraryKind.Movies));
        using var addStorageResp = await client.SendAsync(addStorageReq);
        addStorageResp.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task CriticalActionDemandsServerPasswordAndSucceedsWithApproval()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // Seed a storage location so library reset has a target
        var rootId = Guid.NewGuid();
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
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

        // Execute critical action with the obtained X-Aurelia-Approval
        using var resetReq = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset", owner.Token, resetBody);
        resetReq.Headers.Add("X-Aurelia-Approval", approval.Token);
        using var resetResp = await client.SendAsync(resetReq);
        resetResp.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task NonCriticalAdminActionsAcceptOlderClientApprovalHeaderGracefully()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // Older client sends a dummy or valid approval header to a non-critical endpoint (e.g. POST /api/v1/users)
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("compat-viewer", "", UserRole.User, null));
        request.Headers.Add("X-Aurelia-Approval", "legacy-client-approval-token-ignored-cleanly");
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        var created = await ApiTestClient.ReadAsync<UserSummary>(response);
        Assert.Equal("compat-viewer", created.Username);
    }

    [Fact]
    public async Task WatchlistAndPreferencesArePureViewerActionsNeverRequiringUnlock()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // Seed a media item
        var mediaId = Guid.NewGuid();
        var rootId = Guid.NewGuid();
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
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
}
