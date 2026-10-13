using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerAccessFoundationTests
{
    [Theory]
    [InlineData("http://192.168.1.5:43110", false)]
    [InlineData("http://localhost.example.com:43110", false)]
    [InlineData("https://owner:password@example.com", false)]
    [InlineData("http://127.0.0.1:43110", true)]
    [InlineData("http://localhost:43110", true)]
    [InlineData("http://[::1]:43110", true)]
    [InlineData("https://192.168.1.5:43111", true)]
    public void CommandClientsRejectUnverifiedRemotePasswordTransport(string address, bool allowed)
    {
        if (allowed) Assert.Equal(address, CommandClientSecurity.ValidateAddress(address).GetLeftPart(UriPartial.Authority));
        else Assert.Throws<InvalidOperationException>(() => CommandClientSecurity.ValidateAddress(address));
    }

    [Fact]
    public async Task CommandClientApprovalsPreserveLibraryAndMetadataAdministration()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", owner.Token);
        var library = await SeedAsync(factory, "Command Library");
        using var configured = await CommandClientSecurity.SendConfirmedAsync(client, HttpMethod.Put, "/api/v1/metadata/provider",
            new UpdateMetadataProviderRequest(false, "en-US", null), "correct horse battery staple", CancellationToken.None);
        configured.EnsureSuccessStatusCode();
        using var disabled = await CommandClientSecurity.SendConfirmedAsync(client, HttpMethod.Delete, "/api/v1/metadata/provider/token",
            null, "correct horse battery staple", CancellationToken.None);
        disabled.EnsureSuccessStatusCode();
        using var removed = await CommandClientSecurity.SendConfirmedAsync(client, HttpMethod.Delete, $"/api/v1/libraries/{library.LibraryId}",
            null, "correct horse battery staple", CancellationToken.None);
        Assert.Equal(HttpStatusCode.NoContent, removed.StatusCode);
    }

    [Theory]
    [InlineData("/api/v1/auth/sessions/")]
    [InlineData("/api/v1/server/sessions/")]
    public async Task OwnerCannotRevokeAnotherAccountsDeviceWithoutExactApproval(string route)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var viewer = await CreateViewerAsync(client, owner, "device-viewer");
        var path = route + viewer.SessionId;
        using var missing = ApiTestClient.Authorized(HttpMethod.Delete, path, owner.Token);
        using var denied = await client.SendAsync(missing);
        Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        using var approval = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/approval", owner.Token,
            new AdministrationApprovalRequest("DELETE " + path, AdministrationApprovalStore.Hash([]), "correct horse battery staple"));
        using var approved = await client.SendAsync(approval);
        approved.EnsureSuccessStatusCode();
        var grant = await ApiTestClient.ReadAsync<AdministrationApprovalResponse>(approved);
        using var revoke = ApiTestClient.Authorized(HttpMethod.Delete, path, owner.Token);
        revoke.Headers.Add("X-Aurelia-Approval", grant.Token);
        using var revoked = await client.SendAsync(revoke);
        Assert.Equal(HttpStatusCode.NoContent, revoked.StatusCode);
        using var account = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/auth/me", viewer.Token);
        using var signedOut = await client.SendAsync(account);
        Assert.Equal(HttpStatusCode.Unauthorized, signedOut.StatusCode);
    }

    [Theory]
    [InlineData("awaitingConfirmation")]
    [InlineData("restarting")]
    public void ConfigurationCannotOverwritePoliciesDuringAnUnconfirmedHostChange(string state)
    {
        var directory = TestPaths.CreateDataDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(directory);
        try
        {
            var runtime = ServerRuntimeOptions.Resolve(new Microsoft.Extensions.Configuration.ConfigurationBuilder().Build(), ["run", "--data-dir", directory]);
            var store = new ServerConfigurationStore(runtime);
            var previous = store.Current;
            File.WriteAllText(Path.Combine(directory, "host-operation.json"), System.Text.Json.JsonSerializer.Serialize(
                new HostOperationJournal(1, Guid.NewGuid(), "network", state, Guid.NewGuid(), DateTimeOffset.UtcNow.AddSeconds(60), previous),
                ApiTestClient.JsonOptions));
            var error = Assert.Throws<AccountException>(() => store.Update(previous with { DeviceSessionDays = 30 }));
            Assert.Equal("host_operation_active", error.Code);
            Assert.Equal(previous, store.Current);
            Assert.False(File.Exists(Path.Combine(directory, ServerHostSettings.FileName)));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task GrantsProtectLegacyCatalogDetailsSearchCountsArtworkProgressFavoritesAndTickets()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var first = await SeedAsync(factory, "Visible Movie");
        var hidden = await SeedAsync(factory, "Hidden Movie");
        var viewer = await CreateViewerAsync(client, owner, "first-viewer");
        var other = await CreateViewerAsync(client, owner, "second-viewer");
        using (var access = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{viewer.User.Id}/access", owner.Token,
                   new UpdateUserAccessRequest(true, [first.LibraryId])))
        using (var response = await ApiTestClient.SendAsync(client, access)) response.EnsureSuccessStatusCode();
        using (var access = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{other.User.Id}/access", owner.Token,
                   new UpdateUserAccessRequest(true, [hidden.LibraryId])))
        using (var response = await ApiTestClient.SendAsync(client, access)) response.EnsureSuccessStatusCode();
        foreach (var account in new[] { viewer, other })
        {
            var permitted = account == viewer ? first : hidden;
            var forbidden = account == viewer ? hidden : first;
            foreach (var route in new[] { "/api/v1/catalog/movies", "/api/v1/catalog/items", "/api/v1/catalog/search?query=Movie&limit=1", "/api/v1/home" })
            {
                using var request = ApiTestClient.Authorized(HttpMethod.Get, route, account.Token);
                using var response = await client.SendAsync(request);
                response.EnsureSuccessStatusCode();
                var json = await response.Content.ReadAsStringAsync();
                Assert.Contains(permitted.Title, json, StringComparison.Ordinal);
                Assert.DoesNotContain(forbidden.Title, json, StringComparison.Ordinal);
                if (route.Contains("search", StringComparison.Ordinal)) Assert.Equal(1, (await ApiTestClient.ReadAsync<PagedResponse<CatalogItemSummary>>(response)).Total);
            }
            foreach (var route in new[] { $"/api/v1/catalog/movies/{forbidden.MediaId}", $"/api/v1/catalog/items/{forbidden.MediaId}",
                         $"/api/v1/catalog/items/{forbidden.MediaId}/summary",
                         $"/api/v1/media/{forbidden.MediaId}/metadata", $"/api/v1/media/{forbidden.MediaId}/progress", $"/api/v1/artwork/{forbidden.ArtworkId}" })
            {
                using var request = ApiTestClient.Authorized(HttpMethod.Get, route, account.Token);
                using var response = await client.SendAsync(request);
                Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
            }
            using var summary = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/catalog/items/{permitted.MediaId}/summary", account.Token);
            using var summaryResponse = await ApiTestClient.SendAsync(client, summary);
            summaryResponse.EnsureSuccessStatusCode();
            Assert.Equal(permitted.Title, (await ApiTestClient.ReadAsync<CatalogItemSummary>(summaryResponse)).Title);
            using var favorite = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{forbidden.MediaId}/favorite", account.Token, new SetFavoriteRequest(true));
            using var favoriteResponse = await client.SendAsync(favorite);
            Assert.Equal(HttpStatusCode.NotFound, favoriteResponse.StatusCode);
            using var progress = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{forbidden.MediaId}/progress", account.Token,
                new UpdatePlaybackProgressRequest(20_000, 300_000, false, Guid.NewGuid(), true, 0));
            using var progressResponse = await ApiTestClient.SendAsync(client, progress);
            Assert.Equal(HttpStatusCode.NotFound, progressResponse.StatusCode);
            using var playback = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{forbidden.MediaId}/playback", account.Token);
            using var playbackResponse = await client.SendAsync(playback);
            Assert.Equal(HttpStatusCode.NotFound, playbackResponse.StatusCode);
        }
    }

    [Fact]
    public async Task NewAccountsHaveNoImplicitGrantsAndLastOwnerCannotBeDisabled()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        _ = await SeedAsync(factory, "Private Movie");
        var viewer = await CreateViewerAsync(client, owner, "no-grants");
        using var catalog = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/catalog/items", viewer.Token);
        using var response = await client.SendAsync(catalog);
        Assert.Equal(0, (await ApiTestClient.ReadAsync<PagedResponse<CatalogItemSummary>>(response)).Total);
        using var disable = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{owner.User.Id}/access", owner.Token, new UpdateUserAccessRequest(false, []));
        using var disabled = await ApiTestClient.SendAsync(client, disable);
        Assert.Equal(HttpStatusCode.Conflict, disabled.StatusCode);
    }

    [Fact]
    public async Task SensitiveChangesRequireExactSingleUseSessionBoundApproval()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var missing = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token, new CreateUserRequest("blocked", "secure viewer password", UserRole.User, ApiTestClient.TestPin));
        using var denied = await client.SendAsync(missing);
        Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        using var change = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token, new CreateUserRequest("approved", "secure viewer password", UserRole.User, ApiTestClient.TestPin));
        var payload = await change.Content!.ReadAsByteArrayAsync();
        using var approve = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/approval", owner.Token,
            new AdministrationApprovalRequest("POST /api/v1/users", AdministrationApprovalStore.Hash(payload), "correct horse battery staple"));
        using var approved = await client.SendAsync(approve);
        approved.EnsureSuccessStatusCode();
        var grant = await ApiTestClient.ReadAsync<AdministrationApprovalResponse>(approved);
        Assert.InRange(grant.ExpiresAt - DateTimeOffset.UtcNow, TimeSpan.FromSeconds(100), TimeSpan.FromMinutes(2));
        change.Headers.Add("X-Aurelia-Approval", grant.Token);
        using var success = await client.SendAsync(change);
        success.EnsureSuccessStatusCode();
        using var replay = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token, new CreateUserRequest("replayed", "secure viewer password", UserRole.User, ApiTestClient.TestPin));
        replay.Headers.Add("X-Aurelia-Approval", grant.Token);
        using var replayed = await client.SendAsync(replay);
        Assert.Equal(HttpStatusCode.Forbidden, replayed.StatusCode);
    }

    [Fact]
    public void StreamLimitsAndRevocationCancelAlreadyRunningRequests()
    {
        var registry = new ActiveStreamRegistry();
        var user = Guid.NewGuid();
        var session = Guid.NewGuid();
        using var first = registry.Enter(user, session, 32, 1, CancellationToken.None);
        Assert.Throws<AccountException>(() => registry.Enter(user, Guid.NewGuid(), 32, 1, CancellationToken.None));
        registry.RevokeSession(session);
        Assert.True(first.Token.IsCancellationRequested);
        using var second = registry.Enter(Guid.NewGuid(), Guid.NewGuid(), 32, 1, CancellationToken.None);
        registry.RevokeUser(second.UserId);
        Assert.True(second.Token.IsCancellationRequested);
    }

    [Fact]
    public void ApprovalRejectsExpiryWrongDeviceWrongActionAndChangedPayload()
    {
        var clock = new ApprovalClock();
        var approvals = new AdministrationApprovalStore(clock, new TokenService());
        var session = Guid.NewGuid();
        var hash = AdministrationApprovalStore.Hash("{\"role\":\"user\"}"u8);
        var expired = approvals.Issue(session, "PUT /api/v1/users/test", hash);
        clock.Advance(TimeSpan.FromMinutes(2));
        Assert.False(approvals.Consume(expired.Token, session, "PUT /api/v1/users/test", hash));
        var otherDevice = approvals.Issue(session, "PUT /api/v1/users/test", hash);
        Assert.False(approvals.Consume(otherDevice.Token, Guid.NewGuid(), "PUT /api/v1/users/test", hash));
        Assert.False(approvals.Consume(otherDevice.Token, session, "PUT /api/v1/users/test", hash));
        var otherAction = approvals.Issue(session, "PUT /api/v1/users/test", hash);
        Assert.False(approvals.Consume(otherAction.Token, session, "DELETE /api/v1/users/test", hash));
        var otherBody = approvals.Issue(session, "PUT /api/v1/users/test", hash);
        Assert.False(approvals.Consume(otherBody.Token, session, "PUT /api/v1/users/test", AdministrationApprovalStore.Hash("{}"u8)));
    }

    [Fact]
    public async Task SensitiveRouteMatchingCannotBypassConfirmationAndOversizedJsonIsRejected()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var uppercase = ApiTestClient.Authorized(HttpMethod.Post, "/API/v1/Users/", owner.Token,
            new CreateUserRequest("not-approved", "secure viewer password", UserRole.User, ApiTestClient.TestPin));
        using var denied = await client.SendAsync(uppercase);
        Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        using var tooLarge = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/server/settings", owner.Token);
        tooLarge.Content = new StringContent(new string(' ', 65_537));
        using var oversized = await client.SendAsync(tooLarge);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, oversized.StatusCode);
    }

    [Fact]
    public async Task SessionLastSeenWritesAreThrottledAndIncrementalSearchTracksTitleEditsAndDeletes()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var media = await SeedAsync(factory, "Original Movie");
        DateTimeOffset firstSeen;
        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            firstSeen = (await database.DeviceSessions.SingleAsync(value => value.Id == owner.SessionId)).LastSeenAt;
            var item = await database.MediaItems.SingleAsync(value => value.Id == media.MediaId);
            item.OverrideTitle = "Changed Movie";
            await database.SaveChangesAsync();
        }
        using (var search = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/catalog/search?query=Changed", owner.Token))
        using (var found = await client.SendAsync(search))
            Assert.Equal(media.MediaId, Assert.Single((await ApiTestClient.ReadAsync<PagedResponse<CatalogItemSummary>>(found)).Items).Id);
        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.Equal(firstSeen, (await database.DeviceSessions.SingleAsync(value => value.Id == owner.SessionId)).LastSeenAt);
            database.MediaItems.Remove(await database.MediaItems.SingleAsync(value => value.Id == media.MediaId));
            await database.SaveChangesAsync();
        }
        using var secondSearch = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/catalog/search?query=Changed", owner.Token);
        using var gone = await client.SendAsync(secondSearch);
        Assert.Equal(0, (await ApiTestClient.ReadAsync<PagedResponse<CatalogItemSummary>>(gone)).Total);
    }

    [Theory]
    [InlineData("192.168.1.20", true)]
    [InlineData("100.101.1.1", true)]
    [InlineData("fc00::1", true)]
    [InlineData("8.8.8.8", false)]
    [InlineData("2001:4860:4860::8888", false)]
    public void PublicInternetCannotBeEnabledThroughAllowedNetworks(string address, bool expected)
    {
        Assert.Equal(expected, ServerRequestGuard.NetworkAllowed(IPAddress.Parse(address), null));
        Assert.Equal(expected && address.StartsWith("192.168.", StringComparison.Ordinal),
            ServerRequestGuard.NetworkAllowed(IPAddress.Parse(address), ["192.168.0.0/16"]));
    }

    private sealed class ApprovalClock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan duration) => now += duration;
    }

    [Fact]
    public void ConfigurationRejectsStaleRevisionsAndDoesNotChangeAnExistingSessionLifetime()
    {
        var directory = TestPaths.CreateDataDirectory();
        try
        {
            var runtime = ServerRuntimeOptions.Resolve(new Microsoft.Extensions.Configuration.ConfigurationBuilder().Build(), ["run", "--data-dir", directory]);
            var store = new ServerConfigurationStore(runtime);
            var original = store.Current;
            Assert.Equal(90, original.DeviceSessionDays);
            var updated = store.Update(original with { DeviceSessionDays = 30, PairingEnabled = false });
            Assert.Equal(original.Revision + 1, updated.Stored.Revision);
            Assert.Throws<AccountException>(() => store.Update(original));
            Assert.Equal(30, new ServerConfigurationStore(runtime).Current.DeviceSessionDays);
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static async Task<AuthenticationResponse> CreateViewerAsync(HttpClient client, AuthenticationResponse owner, string name)
    {
        using var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token, new CreateUserRequest(name, "secure viewer password", UserRole.User, ApiTestClient.TestPin));
        using var created = await ApiTestClient.SendAsync(client, create);
        created.EnsureSuccessStatusCode();
        using var login = await ApiTestClient.LoginAsync(client, new LoginRequest(name, "secure viewer password", "Viewer"));
        login.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
    }

    private sealed record Seed(Guid LibraryId, Guid MediaId, Guid ArtworkId, string Title);
    private static async Task<Seed> SeedAsync(AureliaServerFactory factory, string title)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var root = Path.Combine(factory.DataDirectory, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "Movie.mkv");
        await File.WriteAllBytesAsync(path, [1, 2, 3, 4]);
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = title,
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = now
        };
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = MediaKind.Movie,
            DetectedTitle = title,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            Extension = ".mkv",
            FileSize = 4,
            FileModifiedAt = now,
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now
        };
        media.Metadata = new MediaMetadata { MediaItemId = media.Id, UpdatedAt = now };
        var artwork = new ArtworkAsset { Id = Guid.NewGuid(), MediaItemId = media.Id, RelativeFilePath = Guid.NewGuid().ToString("N"), Kind = ArtworkKind.Poster, CreatedAt = now };
        media.Metadata.Artwork.Add(artwork);
        database.MediaItems.Add(media);
        await database.SaveChangesAsync();
        return new(library.Id, media.Id, artwork.Id, title);
    }
}
