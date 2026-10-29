using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ProfileDeletionTests
{
    [Fact]
    public async Task DeletionRemovesPrivateStateAndCrossDeviceTicketsButPreservesOtherProfilesAndLibrary()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var target = await CreateProfileAsync(client, owner.Token, "Temporary viewer");
        var seeded = await SeedAsync(factory, owner, target);
        var profiles = factory.Services.GetRequiredService<ProfileSessionStore>();
        var active = profiles.Issue(seeded.TargetDeviceId, target.Id);
        using var lease = factory.Services.GetRequiredService<ActiveStreamRegistry>()
            .Enter(target.Id, active.Session.Id, 32, 4, CancellationToken.None);

        using var request = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/users/{target.Id}", owner.Token);
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.True(lease.Token.IsCancellationRequested);
        Assert.False(profiles.IsActive(active.Session.Id, seeded.TargetDeviceId, target.Id));

        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        Assert.Equal(owner.User.Id, (await database.Users.SingleAsync()).Id);
        Assert.Equal(owner.SessionId, (await database.DeviceSessions.SingleAsync()).Id);
        Assert.Equal(owner.User.Id, (await database.PlaybackTickets.SingleAsync()).UserId);
        Assert.Equal(owner.User.Id, (await database.PlaybackProgress.SingleAsync()).UserId);
        Assert.Equal(owner.User.Id, (await database.UserFavorites.SingleAsync()).UserId);
        Assert.Equal(owner.User.Id, (await database.SceneNotes.SingleAsync()).UserId);
        Assert.Equal(owner.User.Id, (await database.ContinueWatchingStates.SingleAsync()).UserId);
        Assert.Equal(owner.User.Id, (await database.LibraryStateMutations.SingleAsync()).UserId);
        Assert.Empty(await database.UserTitleGrants.ToListAsync());
        Assert.Empty(await database.UserLibraryGrants.ToListAsync());
        Assert.Empty(await database.PairingCodes.ToListAsync());
        Assert.Equal(seeded.MediaId, (await database.MediaItems.SingleAsync()).Id);
        Assert.Single(await database.LibraryRoots.ToListAsync());
        Assert.Single(await database.MediaCollections.ToListAsync());
        Assert.Single(await database.MediaCollectionMembers.ToListAsync());
        Assert.Equal(0, await database.Database.SqlQueryRaw<long>("SELECT COUNT(*) AS Value FROM pragma_foreign_key_check").SingleAsync());

        using var users = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/users", owner.Token);
        using var refreshed = await client.SendAsync(users);
        refreshed.EnsureSuccessStatusCode();
        Assert.DoesNotContain(await ApiTestClient.ReadAsync<List<UserSummary>>(refreshed), profile => profile.Id == target.Id);
    }

    [Theory]
    [InlineData(UserRole.User)]
    [InlineData(UserRole.Admin)]
    public async Task NonOwnerProfilesCannotDeleteAnotherProfile(UserRole role)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var actor = await CreateProfileAsync(client, owner.Token, "Restricted actor", role);
        var target = await CreateProfileAsync(client, owner.Token, "Keep this viewer");
        using var login = await ApiTestClient.LoginAsync(client, new LoginRequest(actor.Username, "unused", "Restricted device"));
        var active = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
        using var request = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/users/{target.Id}", active.Token);
        using var denied = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        using var scope = factory.Services.CreateScope();
        Assert.True(await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().Users.AnyAsync(user => user.Id == target.Id));
    }

    [Fact]
    public async Task OwnerNeedsBothUnlockedManagementAndApprovalForThisDeletion()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var target = await CreateProfileAsync(client, owner.Token, "Protected from accidental deletion", UserRole.Admin);
        var route = $"/api/v1/users/{target.Id}";
        using (var request = ApiTestClient.Authorized(HttpMethod.Delete, route, owner.Token))
        using (var denied = await client.SendAsync(request))
        {
            Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
            Assert.Equal("approval_required", (await ApiTestClient.ReadAsync<ApiProblem>(denied)).Code);
        }
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/approval", owner.Token,
            new AdministrationApprovalRequest($"DELETE /api/v1/users/{Guid.NewGuid()}", AdministrationApprovalStore.Hash([]))))
        using (var approved = await client.SendAsync(request))
        {
            approved.EnsureSuccessStatusCode();
            var proof = await ApiTestClient.ReadAsync<AdministrationApprovalResponse>(approved);
            using var wrongAction = ApiTestClient.Authorized(HttpMethod.Delete, route, owner.Token);
            wrongAction.Headers.Add("X-Aurelia-Approval", proof.Token);
            using var denied = await client.SendAsync(wrongAction);
            Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
            Assert.Equal("approval_required", (await ApiTestClient.ReadAsync<ApiProblem>(denied)).Code);
        }
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/lock", owner.Token))
        using (var locked = await client.SendAsync(request)) locked.EnsureSuccessStatusCode();
        using (var request = ApiTestClient.Authorized(HttpMethod.Delete, route, owner.Token))
        using (var denied = await client.SendAsync(request))
        {
            Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
            Assert.Equal("management_locked", (await ApiTestClient.ReadAsync<ApiProblem>(denied)).Code);
        }
        using var scope = factory.Services.CreateScope();
        Assert.True(await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().Users.AnyAsync(user => user.Id == target.Id));
    }

    [Fact]
    public async Task CurrentOwnerCannotDeleteItself()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await CreateProfileAsync(client, owner.Token, "Other owner", UserRole.Owner);
        using var request = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/users/{owner.User.Id}", owner.Token);
        using var rejected = await ApiTestClient.SendAsync(client, request);
        Assert.Equal(HttpStatusCode.Conflict, rejected.StatusCode);
        Assert.Equal("cannot_delete_current_user", (await ApiTestClient.ReadAsync<ApiProblem>(rejected)).Code);
        using var scope = factory.Services.CreateScope();
        Assert.Equal(2, await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().Users.CountAsync());
    }

    [Fact]
    public async Task LastEnabledOwnerRemainsProtectedEvenWhenAnotherOwnerRowExists()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var disabled = await CreateProfileAsync(client, owner.Token, "Disabled owner", UserRole.Owner);
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        (await database.Users.SingleAsync(user => user.Id == disabled.Id)).IsEnabled = false;
        await database.SaveChangesAsync();
        // Exercise the service's invariant independently of authentication, which
        // already prevents the disabled actor from reaching the HTTP endpoint.
        var rejected = await Assert.ThrowsAsync<AccountException>(() => scope.ServiceProvider.GetRequiredService<AccountService>()
            .DeleteUserAsync(disabled.Id, owner.User.Id, CancellationToken.None));
        Assert.Equal("last_owner_required", rejected.Code);
        Assert.Equal(2, await database.Users.CountAsync());
    }

    [Fact]
    public async Task AnotherEnabledOwnerCanBeDeleted()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var target = await CreateProfileAsync(client, owner.Token, "Second owner", UserRole.Owner);
        using var request = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/users/{target.Id}", owner.Token);
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        using var scope = factory.Services.CreateScope();
        Assert.Equal(owner.User.Id, (await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().Users.SingleAsync()).Id);
    }

    [Fact]
    public async Task FailureAfterTicketDeletionRollsBackAllPersistentAndActiveProfileState()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var target = await CreateProfileAsync(client, owner.Token, "Retained on failure");
        var seeded = await SeedAsync(factory, owner, target);
        var profiles = factory.Services.GetRequiredService<ProfileSessionStore>();
        var active = profiles.Issue(seeded.TargetDeviceId, target.Id);
        using var lease = factory.Services.GetRequiredService<ActiveStreamRegistry>()
            .Enter(target.Id, active.Session.Id, 32, 4, CancellationToken.None);
        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            await database.Database.ExecuteSqlRawAsync("CREATE TRIGGER fail_profile_delete BEFORE DELETE ON Users BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END");
            await Assert.ThrowsAsync<DbUpdateException>(() => scope.ServiceProvider.GetRequiredService<AccountService>()
                .DeleteUserAsync(owner.User.Id, target.Id, CancellationToken.None));
        }
        Assert.False(lease.Token.IsCancellationRequested);
        Assert.True(profiles.IsActive(active.Session.Id, seeded.TargetDeviceId, target.Id));
        using var verification = factory.Services.CreateScope();
        var saved = verification.ServiceProvider.GetRequiredService<AureliaDbContext>();
        Assert.Equal(2, await saved.Users.CountAsync());
        Assert.Equal(2, await saved.DeviceSessions.CountAsync());
        Assert.Equal(3, await saved.PlaybackTickets.CountAsync());
        Assert.Equal(2, await saved.PlaybackProgress.CountAsync());
        Assert.Equal(2, await saved.UserFavorites.CountAsync());
        Assert.Equal(2, await saved.SceneNotes.CountAsync());
        Assert.Equal(2, await saved.ContinueWatchingStates.CountAsync());
        Assert.Equal(2, await saved.LibraryStateMutations.CountAsync());
        Assert.Single(await saved.UserTitleGrants.ToListAsync());
        Assert.Single(await saved.UserLibraryGrants.ToListAsync());
        Assert.Single(await saved.PairingCodes.ToListAsync());
        Assert.Single(await saved.MediaItems.ToListAsync());
        Assert.Single(await saved.MediaCollections.ToListAsync());
    }

    private static async Task<UserSummary> CreateProfileAsync(HttpClient client, string ownerToken, string name, UserRole role = UserRole.User)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", ownerToken,
            new CreateUserRequest(name, "", role, ApiTestClient.TestPin));
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<UserSummary>(response);
    }

    private sealed record SeededState(Guid MediaId, Guid TargetDeviceId);

    private static async Task<SeededState> SeedAsync(AureliaServerFactory factory, AuthenticationResponse owner, UserSummary target)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var actor = await database.Users.SingleAsync(user => user.Id == owner.User.Id);
        var viewer = await database.Users.SingleAsync(user => user.Id == target.Id);
        var ownerDevice = await database.DeviceSessions.SingleAsync(device => device.Id == owner.SessionId);
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Synthetic library",
            Path = factory.DataDirectory,
            NormalizedPath = MediaPath.Normalize(factory.DataDirectory),
            Kind = LibraryKind.Automatic,
            CreatedAt = now
        };
        var path = Path.Combine(factory.DataDirectory, "missing-synthetic-title.mkv");
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            Kind = MediaKind.Movie,
            DetectedTitle = "Shared synthetic title",
            LibraryRoot = library,
            LibraryRootId = library.Id,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            CreatedAt = now,
            UpdatedAt = now,
            Availability = MediaAvailability.Missing
        };
        database.MediaItems.Add(media);
        var targetDevice = new DeviceSession
        {
            Id = Guid.NewGuid(),
            User = viewer,
            UserId = viewer.Id,
            DeviceName = "Target-owned synthetic device",
            TokenHash = new string('d', 64),
            CreatedAt = now,
            LastSeenAt = now,
            ExpiresAt = now.AddDays(1)
        };
        database.DeviceSessions.Add(targetDevice);
        foreach (var user in new[] { actor, viewer })
        {
            database.PlaybackTickets.Add(Ticket(user, ownerDevice));
            database.PlaybackProgress.Add(new PlaybackProgress
            {
                Id = Guid.NewGuid(),
                User = user,
                UserId = user.Id,
                MediaItem = media,
                MediaItemId = media.Id,
                PositionMilliseconds = 12000,
                DurationMilliseconds = 120000,
                LastPlayedAt = now,
                UpdatedAt = now,
                Revision = 1
            });
            database.UserFavorites.Add(new UserFavorite { Id = Guid.NewGuid(), User = user, UserId = user.Id, MediaItem = media, MediaItemId = media.Id, CreatedAt = now });
            database.SceneNotes.Add(new SceneNote { Id = Guid.NewGuid(), User = user, UserId = user.Id, MediaItem = media, MediaItemId = media.Id, StartMilliseconds = 1000, Text = "Private synthetic note", Revision = 1 });
            database.ContinueWatchingStates.Add(new ContinueWatchingState { User = user, UserId = user.Id, MediaItem = media, MediaItemId = media.Id, IsHidden = true, Revision = 1 });
            database.LibraryStateMutations.Add(new LibraryStateMutation { User = user, UserId = user.Id, ClientMutationId = Guid.NewGuid(), Fingerprint = "synthetic mutation", ResponseJson = "{}" });
        }
        database.PlaybackTickets.Add(Ticket(viewer, targetDevice));
        database.UserTitleGrants.Add(new UserTitleGrant { User = viewer, UserId = viewer.Id, MediaItem = media, MediaItemId = media.Id });
        database.UserLibraryGrants.Add(new UserLibraryGrant { User = viewer, UserId = viewer.Id, LibraryRoot = library, LibraryRootId = library.Id });
        database.PairingCodes.Add(new PairingCode { Id = Guid.NewGuid(), User = viewer, UserId = viewer.Id, CodeHash = new string('c', 64), CreatedAt = now, ExpiresAt = now.AddMinutes(5) });
        var collection = new MediaCollectionRecord { Id = Guid.NewGuid(), Name = "Shared collection", IsManual = true, CreatedAt = now, UpdatedAt = now };
        database.MediaCollectionMembers.Add(new MediaCollectionMember { Collection = collection, CollectionId = collection.Id, MediaItem = media, MediaItemId = media.Id });
        await database.SaveChangesAsync();
        return new(media.Id, targetDevice.Id);

        PlaybackTicket Ticket(ServerUser user, DeviceSession device) => new()
        {
            Id = Guid.NewGuid(),
            User = user,
            UserId = user.Id,
            MediaItem = media,
            MediaItemId = media.Id,
            DeviceSession = device,
            DeviceSessionId = device.Id,
            TokenHash = Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N"),
            CreatedAt = now,
            ExpiresAt = now.AddMinutes(5)
        };
    }
}
