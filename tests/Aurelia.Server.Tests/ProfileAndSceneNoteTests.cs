using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ProfileAndSceneNoteTests
{
    [Fact]
    public async Task LocalOwnerRecoveryRequiresPrivateHostProofAndServerPassword()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        const string hostProof = "synthetic-private-host-proof-12345678901234567890";
        var recovery = new LocalOwnerPinRecovery(new Microsoft.Extensions.Configuration.ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["Aurelia:HostRecoveryToken"] = hostProof }).Build());
        var context = new Microsoft.AspNetCore.Http.DefaultHttpContext();
        Assert.Throws<AccountException>(() => recovery.Authorize(context));
        context.Request.Headers["X-Aurelia-Host-Recovery"] = hostProof;
        context.Connection.RemoteIpAddress = System.Net.IPAddress.Parse("192.168.1.9");
        Assert.Throws<AccountException>(() => recovery.Authorize(context));
        context.Connection.RemoteIpAddress = System.Net.IPAddress.Loopback;
        recovery.Authorize(context);
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var profiles = scope.ServiceProvider.GetRequiredService<ProfileService>();
        var oldHash = (await database.Users.AsNoTracking().SingleAsync()).PinHash;
        await Assert.ThrowsAsync<AccountException>(() => recovery.RecoverAsync(new InitializeProfilesRequest("incorrect password", "5678"), database, profiles, CancellationToken.None));
        Assert.Equal(oldHash, (await database.Users.AsNoTracking().SingleAsync()).PinHash);
        await recovery.RecoverAsync(new InitializeProfilesRequest("correct horse battery staple", "5678"), database, profiles, CancellationToken.None);
        using var expired = await SendAsync(client, owner.Token, HttpMethod.Get, "/api/v1/home");
        Assert.Equal(HttpStatusCode.Unauthorized, expired.StatusCode);
        var device = await DeviceAsync(client);
        using var unlocked = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{owner.User.Id}/unlock", new UnlockProfileRequest("5678"));
        unlocked.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task PairedDeviceCannotReadPersonalDataOrAdministrationWithoutPin()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var device = await DeviceAsync(client);
        using var picker = await SendAsync(client, device.Token, HttpMethod.Get, "/api/v1/profiles");
        picker.EnsureSuccessStatusCode();
        Assert.Single((await ApiTestClient.ReadAsync<ProfilePickerResponse>(picker)).Profiles);
        foreach (var route in new[] { "/api/v1/home", "/api/v1/catalog/items", "/api/v1/auth/me", "/api/v1/server/users" })
        {
            using var forbidden = await SendAsync(client, device.Token, HttpMethod.Get, route);
            Assert.Equal(HttpStatusCode.Forbidden, forbidden.StatusCode);
        }
        using var unlock = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{owner.User.Id}/unlock", new UnlockProfileRequest(ApiTestClient.TestPin));
        unlock.EnsureSuccessStatusCode();
        var active = await ApiTestClient.ReadAsync<ProfileSessionResponse>(unlock);
        using var home = await SendAsync(client, active.Token, HttpMethod.Get, "/api/v1/home");
        Assert.Equal(HttpStatusCode.OK, home.StatusCode);
        // Admin actions succeed directly once the owner profile is unlocked with PIN
        using var users = await SendAsync(client, active.Token, HttpMethod.Get, "/api/v1/server/users");
        Assert.Equal(HttpStatusCode.OK, users.StatusCode);
        // Critical actions require management unlock with the server password
        using var criticalLocked = await SendAsync(client, active.Token, HttpMethod.Post, "/api/v1/libraries/reset", new ResetLibraryRequest([], "preview"));
        Assert.Equal(HttpStatusCode.Forbidden, criticalLocked.StatusCode);
        Assert.Equal("management_locked", (await ApiTestClient.ReadAsync<ApiProblem>(criticalLocked)).Code);
        using var administration = await SendAsync(client, active.Token, HttpMethod.Post, "/api/v1/management/unlock", new UnlockManagementRequest("correct horse battery staple"));
        administration.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task SwitchingOnOneDeviceRetiresOnlyItsOldProfileAndStreamLease()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var viewer = await CreateAsync(client, owner.Token, "scene-viewer");
        var device = await DeviceAsync(client);
        using var first = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{owner.User.Id}/unlock", new UnlockProfileRequest(ApiTestClient.TestPin));
        var session = await ApiTestClient.ReadAsync<ProfileSessionResponse>(first);
        var streams = factory.Services.GetRequiredService<ActiveStreamRegistry>();
        using var stream = streams.Enter(owner.User.Id, session.SessionId, 32, 4, CancellationToken.None);
        using var second = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{viewer.Id}/unlock", new UnlockProfileRequest(ApiTestClient.TestPin));
        second.EnsureSuccessStatusCode();
        Assert.True(stream.Token.IsCancellationRequested);
        using var stale = await SendAsync(client, session.Token, HttpMethod.Get, "/api/v1/home");
        Assert.Equal(HttpStatusCode.Unauthorized, stale.StatusCode);
        using var otherDevice = await SendAsync(client, owner.Token, HttpMethod.Get, "/api/v1/home");
        Assert.Equal(HttpStatusCode.OK, otherDevice.StatusCode);
        using var picker = await SendAsync(client, device.Token, HttpMethod.Get, "/api/v1/profiles");
        picker.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task SelectedSeriesIncludesChildrenButHidesOtherTitlesCountsImagesAndStorage()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var series = await SeedAsync(factory, MediaKind.Series, "Shared Show");
        var episode = await SeedAsync(factory, MediaKind.Episode, "Shared Episode", series);
        var extra = await SeedAsync(factory, MediaKind.Extra, "Shared Extra", series);
        var hidden = await SeedAsync(factory, MediaKind.Movie, "Private Film", rootId: series.LibraryRootId);
        var admin = await CreateAsync(client, owner.Token, "selected-admin", UserRole.Admin);
        using var access = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{admin.Id}/titles", owner.Token,
            new UpdateProfileTitleAccessRequest(ProfileAccessMode.SelectedTitles, [series.Id], 0));
        using var changed = await ApiTestClient.SendAsync(client, access);
        changed.EnsureSuccessStatusCode();
        using var login = await ApiTestClient.LoginAsync(client, new LoginRequest(admin.Username, "unused", "Selected device"));
        var active = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
        foreach (var media in new[] { series, episode, extra })
        {
            using var detail = await SendAsync(client, active.Token, HttpMethod.Get, $"/api/v1/catalog/items/{media.Id}/summary");
            Assert.Equal(HttpStatusCode.OK, detail.StatusCode);
        }
        using var secret = await SendAsync(client, active.Token, HttpMethod.Get, $"/api/v1/catalog/items/{hidden.Id}/summary");
        Assert.Equal(HttpStatusCode.NotFound, secret.StatusCode);
        using var search = await SendAsync(client, active.Token, HttpMethod.Get, "/api/v1/catalog/search?query=Shared&limit=1");
        search.EnsureSuccessStatusCode();
        var hits = await ApiTestClient.ReadAsync<PagedResponse<CatalogItemSummary>>(search);
        Assert.Equal(2, hits.Total);
        Assert.Single(hits.Items);
        foreach (var route in new[] { "/api/v1/libraries", $"/api/v1/media/{series.Id}/editor/files", "/api/v1/libraries/reset/preview" })
        {
            using var denied = await SendAsync(client, active.Token, route.EndsWith("preview", StringComparison.Ordinal) ? HttpMethod.Post : HttpMethod.Get, route,
                route.EndsWith("preview", StringComparison.Ordinal) ? new[] { series.LibraryRootId } : null);
            Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        }
        using var forbiddenRole = await SendAsync(client, active.Token, HttpMethod.Get, "/api/v1/server/users");
        Assert.Equal(HttpStatusCode.Forbidden, forbiddenRole.StatusCode);
    }

    [Fact]
    public async Task NotesArePrivateRevisionProtectedRetainedOfflineAndDeletedWithTitle()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var movie = await SeedAsync(factory, MediaKind.Movie, "Note Film");
        var user = await CreateAsync(client, owner.Token, "note-viewer");
        using (var grant = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{user.Id}/titles", owner.Token,
            new UpdateProfileTitleAccessRequest(ProfileAccessMode.EntireLibrary, [], 0)))
        using (var response = await ApiTestClient.SendAsync(client, grant)) response.EnsureSuccessStatusCode();
        using var login = await ApiTestClient.LoginAsync(client, new LoginRequest(user.Username, "unused", "Note viewer"));
        var viewer = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
        var id = Guid.NewGuid();
        var route = $"/api/v1/media/{movie.Id}/notes";
        using var saved = await SendAsync(client, viewer.Token, HttpMethod.Put, $"{route}/{id}", new SaveSceneNoteRequest(330000, 367000, "Synthetic private note", 0));
        saved.EnsureSuccessStatusCode();
        var note = await ApiTestClient.ReadAsync<SceneNoteSummary>(saved);
        Assert.Equal(1, note.Revision);
        using var replay = await SendAsync(client, viewer.Token, HttpMethod.Put, $"{route}/{id}", new SaveSceneNoteRequest(330000, 367000, "Synthetic private note", 0));
        Assert.Equal(note, await ApiTestClient.ReadAsync<SceneNoteSummary>(replay));
        using var ownerNotes = await SendAsync(client, owner.Token, HttpMethod.Get, route);
        Assert.Empty(await ApiTestClient.ReadAsync<List<SceneNoteSummary>>(ownerNotes));
        using var conflict = await SendAsync(client, viewer.Token, HttpMethod.Put, $"{route}/{id}", new SaveSceneNoteRequest(330000, null, "Stale", 0));
        Assert.Equal(HttpStatusCode.Conflict, conflict.StatusCode);
        using var changed = await SendAsync(client, viewer.Token, HttpMethod.Put, $"{route}/{id}", new SaveSceneNoteRequest(330000, null, "Updated", 1));
        Assert.Equal(2, (await ApiTestClient.ReadAsync<SceneNoteSummary>(changed)).Revision);
        using var foreignDelete = await SendAsync(client, owner.Token, HttpMethod.Delete, $"{route}/{id}?revision=2");
        Assert.Equal(HttpStatusCode.NotFound, foreignDelete.StatusCode);
        using var existing = await SendAsync(client, viewer.Token, HttpMethod.Get, route);
        Assert.Single(await ApiTestClient.ReadAsync<List<SceneNoteSummary>>(existing));
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        Assert.Contains(await database.SyncChanges.ToListAsync(), change => change.Area == SyncChangeArea.UserState && change.UserId == user.Id && change.MediaItemId == movie.Id);
        database.MediaItems.Remove(await database.MediaItems.SingleAsync(item => item.Id == movie.Id));
        await database.SaveChangesAsync();
        Assert.Empty(await database.SceneNotes.ToListAsync());
    }

    [Fact]
    public async Task PinResetCannotBeBypassedByAnAlreadyPendingUnlock()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var device = await DeviceAsync(client);
        using var requestScope = factory.Services.CreateScope();
        var profiles = requestScope.ServiceProvider.GetRequiredService<ProfileService>();
        var mutations = factory.Services.GetRequiredService<CatalogMutationGate>();
        Task<ProfileSessionResponse> pending;
        using (await mutations.EnterAsync(CancellationToken.None))
        {
            pending = profiles.UnlockAsync(device.SessionId, owner.User.Id, ApiTestClient.TestPin, CancellationToken.None);
            await Task.Delay(100);
            Assert.False(pending.IsCompleted);
            using var resetScope = factory.Services.CreateScope();
            var database = resetScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var user = await database.Users.SingleAsync(user => user.Id == owner.User.Id);
            user.PinHash = resetScope.ServiceProvider.GetRequiredService<Microsoft.AspNetCore.Identity.IPasswordHasher<ServerUser>>()
                .HashPassword(user, "5678");
            await database.SaveChangesAsync();
            factory.Services.GetRequiredService<ProfileSessionStore>().RevokeUser(user.Id);
        }
        var rejected = await Assert.ThrowsAsync<AccountException>(() => pending);
        Assert.Equal("invalid_profile_pin", rejected.Code);
        using var unlocked = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{owner.User.Id}/unlock", new UnlockProfileRequest("5678"));
        unlocked.EnsureSuccessStatusCode();
    }

    [Fact]
    public void PinsAndAdministrativeUnlocksHaveSeparateFiniteLifetimes()
    {
        var clock = new TestClock();
        var streams = new ActiveStreamRegistry();
        using var sessions = new ProfileSessionStore(clock, new TokenService(), streams);
        var device = Guid.NewGuid(); var user = Guid.NewGuid();
        var issued = sessions.Issue(device, user);
        using var stream = streams.Enter(user, issued.Session.Id, 32, 4, CancellationToken.None);
        Assert.False(sessions.ManagementUnlocked(issued.Session.Id));
        Assert.Equal(clock.GetUtcNow().AddMinutes(10), sessions.UnlockManagement(issued.Session.Id));
        clock.Advance(TimeSpan.FromMinutes(10));
        Assert.False(sessions.ManagementUnlocked(issued.Session.Id));
        Assert.True(sessions.IsActive(issued.Session.Id, device, user));
        clock.Advance(TimeSpan.FromHours(11) + TimeSpan.FromMinutes(50) - TimeSpan.FromMilliseconds(1));
        Assert.False(stream.Token.IsCancellationRequested);
        clock.Advance(TimeSpan.FromMilliseconds(1));
        // Expiration itself stops an existing stream, without another API lookup.
        Assert.True(stream.Token.IsCancellationRequested);
        Assert.False(sessions.IsActive(issued.Session.Id, device, user));
        var attempts = new ProfilePinAttemptGuard(clock);
        for (var index = 0; index < 5; index++) { attempts.Check(device, user); attempts.Record(device, user, false); }
        Assert.Throws<AccountException>(() => attempts.Check(device, user));
        clock.Advance(TimeSpan.FromSeconds(59));
        Assert.Throws<AccountException>(() => attempts.Check(device, user));
        clock.Advance(TimeSpan.FromSeconds(1));
        attempts.Check(device, user);
        // Another paired device does not get fresh guesses, and every lock lasts longer.
        var otherDevice = Guid.NewGuid();
        for (var index = 0; index < 5; index++) { attempts.Check(otherDevice, user); attempts.Record(otherDevice, user, false); }
        var locked = Assert.Throws<AccountException>(() => attempts.Check(device, user));
        Assert.Equal("profile_pin_locked", locked.Code);
        clock.Advance(TimeSpan.FromMinutes(5) - TimeSpan.FromSeconds(1));
        Assert.Throws<AccountException>(() => attempts.Check(otherDevice, user));
        clock.Advance(TimeSpan.FromSeconds(1));
        attempts.Check(otherDevice, user);
        Assert.Equal(TimeSpan.FromMinutes(30), ProfilePinAttemptGuard.LockDuration(15));
        Assert.Equal(TimeSpan.FromHours(2), ProfilePinAttemptGuard.LockDuration(40));
        // A correct PIN starts over; another profile is never affected.
        attempts.Record(device, user, true);
        attempts.Check(device, user);
        attempts.Check(device, Guid.NewGuid());
    }

    private static async Task<AuthenticationResponse> DeviceAsync(HttpClient client)
    {
        using var response = await client.PostAsJsonAsync("/api/v1/auth/login", new LoginRequest("lucas", "correct horse battery staple", "Paired synthetic device"), ApiTestClient.JsonOptions);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AuthenticationResponse>(response);
    }
    private static async Task<UserSummary> CreateAsync(HttpClient client, string owner, string name, UserRole role = UserRole.User)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner, new CreateUserRequest(name, "", role, ApiTestClient.TestPin));
        using var response = await ApiTestClient.SendAsync(client, request); response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<UserSummary>(response);
    }
    private static async Task<HttpResponseMessage> SendAsync(HttpClient client, string token, HttpMethod method, string path, object? body = null)
    { using var request = ApiTestClient.Authorized(method, path, token, body); return await client.SendAsync(request); }
    private static async Task<MediaItem> SeedAsync(AureliaServerFactory factory, MediaKind kind, string title, MediaItem? parent = null, Guid? rootId = null)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var root = parent?.LibraryRootId ?? rootId;
        var library = root.HasValue ? await database.LibraryRoots.SingleAsync(item => item.Id == root) : new LibraryRoot
        { Id = Guid.NewGuid(), Name = "Synthetic library", Path = factory.DataDirectory, NormalizedPath = MediaPath.Normalize(factory.DataDirectory), Kind = LibraryKind.Automatic, CreatedAt = DateTimeOffset.UtcNow };
        var path = Path.Combine(factory.DataDirectory, Guid.NewGuid() + ".mkv");
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            Kind = kind,
            DetectedTitle = title,
            LibraryRoot = library,
            LibraryRootId = library.Id,
            ParentId = parent?.Id,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
            Availability = MediaAvailability.Missing,
            SeasonNumber = kind == MediaKind.Episode ? 1 : null,
            EpisodeNumber = kind == MediaKind.Episode ? 1 : null
        };
        database.MediaItems.Add(media); await database.SaveChangesAsync(); return media;
    }
    private sealed class TestClock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.Parse("2026-01-01T00:00:00Z", global::System.Globalization.CultureInfo.InvariantCulture);
        private readonly List<ClockTimer> timers = [];
        public override DateTimeOffset GetUtcNow() => now;
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new ClockTimer(this, callback, state);
            timers.Add(timer);
            timer.Change(dueTime, period);
            return timer;
        }
        public void Advance(TimeSpan value)
        {
            now += value;
            foreach (var timer in timers.ToArray()) timer.FireIfDue();
        }
        private sealed class ClockTimer(TestClock owner, TimerCallback callback, object? state) : ITimer
        {
            private DateTimeOffset? due;
            private TimeSpan interval;
            public bool Change(TimeSpan dueTime, TimeSpan period)
            {
                due = dueTime == Timeout.InfiniteTimeSpan ? null : owner.now + dueTime;
                interval = period;
                return true;
            }
            public void FireIfDue()
            {
                if (due is null || due > owner.now) return;
                due = interval == Timeout.InfiniteTimeSpan ? null : owner.now + interval;
                callback(state);
            }
            public void Dispose() { due = null; owner.timers.Remove(this); }
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}
