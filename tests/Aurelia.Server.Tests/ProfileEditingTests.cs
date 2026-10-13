using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ProfileEditingTests
{
    [Fact]
    public async Task NormalProfileDefaultsToNoPinButStillNeedsItsOwnVolatileSession()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var user = await CreateAsync(client, owner.Token, new("Unprotected Viewer", null, UserRole.User));
        Assert.False(user.PinProtectionEnabled);
        Assert.False(user.NeedsPinSetup);
        Assert.Equal(1, user.ProfileRevision);
        Assert.Equal(ProfileAccessMode.SelectedTitles, user.AccessMode);
        var device = await DeviceAsync(client);
        using var picker = await SendAsync(client, device.Token, HttpMethod.Get, "/api/v1/profiles");
        var chosen = Assert.Single((await ApiTestClient.ReadAsync<ProfilePickerResponse>(picker)).Profiles, profile => profile.Id == user.Id);
        Assert.False(chosen.PinProtectionEnabled);
        Assert.False(chosen.NeedsPinSetup);
        using var deviceHome = await SendAsync(client, device.Token, HttpMethod.Get, "/api/v1/home");
        Assert.Equal(HttpStatusCode.Forbidden, deviceHome.StatusCode);
        using var opened = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{user.Id}/unlock", new UnlockProfileRequest());
        opened.EnsureSuccessStatusCode();
        var profile = await ApiTestClient.ReadAsync<ProfileSessionResponse>(opened);
        Assert.Equal(user.Id, profile.User.Id);
        Assert.NotEqual(device.Token, profile.Token);
        using var home = await SendAsync(client, profile.Token, HttpMethod.Get, "/api/v1/home");
        home.EnsureSuccessStatusCode();
        using var administration = await SendAsync(client, profile.Token, HttpMethod.Post,
            "/api/v1/management/unlock", new UnlockManagementRequest("correct horse battery staple"));
        Assert.Equal(HttpStatusCode.Forbidden, administration.StatusCode);
        using var ended = await SendAsync(client, profile.Token, HttpMethod.Post, "/api/v1/profile/end");
        ended.EnsureSuccessStatusCode();
        using var retired = await SendAsync(client, profile.Token, HttpMethod.Get, "/api/v1/home");
        Assert.Equal(HttpStatusCode.Unauthorized, retired.StatusCode);
    }

    [Theory]
    [InlineData(UserRole.Owner)]
    [InlineData(UserRole.Admin)]
    public async Task PrivilegedProfilesCannotBeCreatedUnprotectedOrPromotedWithoutPin(UserRole role)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var badCreate = await SendApprovedAsync(client, owner.Token, HttpMethod.Post, "/api/v1/users",
            new CreateUserRequest("Rejected Privileged", null, role, PinProtectionEnabled: false));
        Assert.Equal(HttpStatusCode.BadRequest, badCreate.StatusCode);
        var user = await CreateAsync(client, owner.Token, new("Promotion Viewer", null, UserRole.User));
        var before = await EditorAsync(client, owner.Token, user.Id);
        using var badPromotion = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{user.Id}/profile",
            new UpdateProfileRequest(before.Revision, role, true, true));
        Assert.Equal(HttpStatusCode.BadRequest, badPromotion.StatusCode);
        Assert.Equal(before.User, (await EditorAsync(client, owner.Token, user.Id)).User);
        using var legacyPromotion = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{user.Id}/role", new ChangeUserRoleRequest(role));
        Assert.Equal(HttpStatusCode.BadRequest, legacyPromotion.StatusCode);
        using var goodPromotion = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{user.Id}/profile",
            new UpdateProfileRequest(before.Revision, role, true, true, "5678"));
        goodPromotion.EnsureSuccessStatusCode();
        var after = await ApiTestClient.ReadAsync<ProfileEditorResponse>(goodPromotion);
        Assert.Equal(role, after.User.Role);
        Assert.True(after.User.PinProtectionEnabled);
        Assert.False(after.User.NeedsPinSetup);
        Assert.True(after.Revision > before.Revision);
        var device = await DeviceAsync(client);
        using var missingPin = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{user.Id}/unlock", new UnlockProfileRequest());
        Assert.Equal(HttpStatusCode.Unauthorized, missingPin.StatusCode);
        using var correctPin = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{user.Id}/unlock", new UnlockProfileRequest("5678"));
        correctPin.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task AtomicEditsValidateEverythingBeforeChangingAnyProfileState()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var user = await CreateAsync(client, owner.Token, new("Atomic Viewer", null, UserRole.User));
        var before = await EditorAsync(client, owner.Token, user.Id);
        using var badAccess = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{user.Id}/profile",
            new UpdateProfileRequest(before.Revision, UserRole.Admin, false, true, "5678", ProfileAccessMode.SelectedTitles, [Guid.NewGuid()]));
        Assert.Equal(HttpStatusCode.BadRequest, badAccess.StatusCode);
        var unchanged = await EditorAsync(client, owner.Token, user.Id);
        Assert.Equal(before.User, unchanged.User);
        Assert.Equal(before.IsEnabled, unchanged.IsEnabled);
        Assert.Equal(before.Revision, unchanged.Revision);
        using var saved = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{user.Id}/profile",
            new UpdateProfileRequest(before.Revision, UserRole.Admin, true, true, "5678", ProfileAccessMode.EntireLibrary, []));
        saved.EnsureSuccessStatusCode();
        var after = await ApiTestClient.ReadAsync<ProfileEditorResponse>(saved);
        Assert.Equal(UserRole.Admin, after.User.Role);
        Assert.Equal(ProfileAccessMode.EntireLibrary, after.Access.Mode);
        using var stale = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{user.Id}/profile",
            new UpdateProfileRequest(before.Revision, UserRole.User, false, false));
        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        Assert.Equal(after.User, (await EditorAsync(client, owner.Token, user.Id)).User);
    }

    [Fact]
    public async Task LegacyLibraryGrantsSurviveUnrelatedEditsAndAdvanceOverallRevision()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var user = await CreateAsync(client, owner.Token, new("Legacy Viewer", null, UserRole.User));
        var initial = await EditorAsync(client, owner.Token, user.Id);
        using var legacy = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{user.Id}/access", new UpdateUserAccessRequest(true, []));
        legacy.EnsureSuccessStatusCode();
        var inherited = await EditorAsync(client, owner.Token, user.Id);
        Assert.True(inherited.Revision > initial.Revision);
        Assert.Equal(ProfileAccessMode.LegacyLibraries, inherited.Access.Mode);
        using var saved = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{user.Id}/profile",
            new UpdateProfileRequest(inherited.Revision, UserRole.User, false, false));
        saved.EnsureSuccessStatusCode();
        var after = await ApiTestClient.ReadAsync<ProfileEditorResponse>(saved);
        Assert.Equal(ProfileAccessMode.LegacyLibraries, after.Access.Mode);
        Assert.Equal(inherited.Access.Revision, after.Access.Revision);
        Assert.Empty(after.Access.TitleIds);
    }

    [Fact]
    public async Task OwnerDemotionAndRestrictedAccessAreOneChangeAndLastOwnerIsProtected()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var only = await EditorAsync(client, owner.Token, owner.User.Id);
        using var forbidden = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{owner.User.Id}/profile",
            new UpdateProfileRequest(only.Revision, UserRole.User, false, false, AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: []));
        Assert.Equal(HttpStatusCode.Conflict, forbidden.StatusCode);
        var second = await CreateAsync(client, owner.Token, new("Second Owner", null, UserRole.Owner, "5678"));
        var before = await EditorAsync(client, owner.Token, second.Id);
        using var demoted = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{second.Id}/profile",
            new UpdateProfileRequest(before.Revision, UserRole.User, true, false, AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: []));
        demoted.EnsureSuccessStatusCode();
        var after = await ApiTestClient.ReadAsync<ProfileEditorResponse>(demoted);
        Assert.Equal(UserRole.User, after.User.Role);
        Assert.False(after.User.PinProtectionEnabled);
        Assert.Equal(ProfileAccessMode.SelectedTitles, after.Access.Mode);
    }

    [Fact]
    public async Task OwnProtectionChangesRequireOldPinAndRetireSessionsAndStreams()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var user = await CreateAsync(client, owner.Token, new("Protected Viewer", null, UserRole.User, "5678"));
        var device = await DeviceAsync(client);
        using var opened = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{user.Id}/unlock", new UnlockProfileRequest("5678"));
        var session = await ApiTestClient.ReadAsync<ProfileSessionResponse>(opened);
        using var stream = factory.Services.GetRequiredService<ActiveStreamRegistry>().Enter(user.Id, session.SessionId, 32, 4, CancellationToken.None);
        using var wrong = await SendAsync(client, session.Token, HttpMethod.Put, "/api/v1/profile/pin-protection", new UpdateOwnPinProtectionRequest(false, "9999"));
        Assert.Equal(HttpStatusCode.Unauthorized, wrong.StatusCode);
        Assert.False(stream.Token.IsCancellationRequested);
        using var disabled = await SendAsync(client, session.Token, HttpMethod.Put, "/api/v1/profile/pin-protection", new UpdateOwnPinProtectionRequest(false, "5678"));
        disabled.EnsureSuccessStatusCode();
        Assert.True(stream.Token.IsCancellationRequested);
        using var retired = await SendAsync(client, session.Token, HttpMethod.Get, "/api/v1/home");
        Assert.Equal(HttpStatusCode.Unauthorized, retired.StatusCode);
        using var pinless = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{user.Id}/unlock", new UnlockProfileRequest());
        pinless.EnsureSuccessStatusCode();
        using var ownerDisable = await SendAsync(client, owner.Token, HttpMethod.Put, "/api/v1/profile/pin-protection", new UpdateOwnPinProtectionRequest(false, ApiTestClient.TestPin));
        Assert.Equal(HttpStatusCode.BadRequest, ownerDisable.StatusCode);
    }

    [Fact]
    public async Task UnprotectedProfileCanEnablePinWithoutAnOldPin()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var user = await CreateAsync(client, owner.Token, new("Enable Protection", null, UserRole.User));
        var device = await DeviceAsync(client);
        using var pinless = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{user.Id}/unlock", new UnlockProfileRequest());
        var unprotected = await ApiTestClient.ReadAsync<ProfileSessionResponse>(pinless);
        using var enabled = await SendAsync(client, unprotected.Token, HttpMethod.Put, "/api/v1/profile/pin-protection", new UpdateOwnPinProtectionRequest(true, Pin: "1357"));
        enabled.EnsureSuccessStatusCode();
        using var missing = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{user.Id}/unlock", new UnlockProfileRequest());
        Assert.Equal(HttpStatusCode.Unauthorized, missing.StatusCode);
        using var correct = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{user.Id}/unlock", new UnlockProfileRequest("1357"));
        correct.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task ExistingPendingPinProfileDoesNotBecomeUnprotected()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var user = await CreateAsync(client, owner.Token, new("Pending Viewer", null, UserRole.User, "5678"));
        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            (await database.Users.SingleAsync(candidate => candidate.Id == user.Id)).PinHash = null;
            await database.SaveChangesAsync();
        }
        var device = await DeviceAsync(client);
        using var picker = await SendAsync(client, device.Token, HttpMethod.Get, "/api/v1/profiles");
        var profile = Assert.Single((await ApiTestClient.ReadAsync<ProfilePickerResponse>(picker)).Profiles, candidate => candidate.Id == user.Id);
        Assert.True(profile.PinProtectionEnabled);
        Assert.True(profile.NeedsPinSetup);
        using var opened = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{user.Id}/unlock", new UnlockProfileRequest());
        Assert.Equal(HttpStatusCode.Unauthorized, opened.StatusCode);
        var before = await EditorAsync(client, owner.Token, user.Id);
        using var explicitlyUnprotected = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{user.Id}/profile",
            new UpdateProfileRequest(before.Revision, UserRole.User, true, false));
        explicitlyUnprotected.EnsureSuccessStatusCode();
        using var allowed = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{user.Id}/unlock", new UnlockProfileRequest());
        allowed.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task UnprotectedProfilesKeepNotesSeparateAndAtomicCreationStoresTitleGrants()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        Guid mediaId;
        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var root = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Synthetic rights",
                Path = factory.DataDirectory,
                NormalizedPath = MediaPath.Normalize(factory.DataDirectory),
                Kind = LibraryKind.Movies,
                CreatedAt = DateTimeOffset.UtcNow
            };
            var media = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRoot = root,
                LibraryRootId = root.Id,
                Kind = MediaKind.Movie,
                DetectedTitle = "Private note fixture",
                SourcePath = Path.Combine(factory.DataDirectory, "offline.mkv"),
                NormalizedSourcePath = MediaPath.Normalize(Path.Combine(factory.DataDirectory, "offline.mkv")),
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow,
                Availability = MediaAvailability.Missing
            };
            database.MediaItems.Add(media);
            await database.SaveChangesAsync();
            mediaId = media.Id;
        }
        var first = await CreateAsync(client, owner.Token, new("First No PIN", null, UserRole.User,
            PinProtectionEnabled: false, AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: [mediaId]));
        var second = await CreateAsync(client, owner.Token, new("Second No PIN", null, UserRole.User,
            PinProtectionEnabled: false, AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: [mediaId]));
        var editor = await EditorAsync(client, owner.Token, first.Id);
        Assert.Equal(mediaId, Assert.Single(editor.Access.TitleIds));
        // Keeping an existing title while changing protection must not create a duplicate grant.
        using var revised = await SendApprovedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{first.Id}/profile",
            new UpdateProfileRequest(editor.Revision, UserRole.User, true, false,
                AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: [mediaId]));
        revised.EnsureSuccessStatusCode();
        Assert.Equal(mediaId, Assert.Single((await ApiTestClient.ReadAsync<ProfileEditorResponse>(revised)).Access.TitleIds));
        var device = await DeviceAsync(client);
        using var openedFirst = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{first.Id}/unlock", new UnlockProfileRequest());
        var firstSession = await ApiTestClient.ReadAsync<ProfileSessionResponse>(openedFirst);
        var noteId = Guid.NewGuid();
        using var saved = await SendAsync(client, firstSession.Token, HttpMethod.Put, $"/api/v1/media/{mediaId}/notes/{noteId}",
            new SaveSceneNoteRequest(5000, null, "Synthetic private note", 0));
        saved.EnsureSuccessStatusCode();
        using var openedSecond = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{second.Id}/unlock", new UnlockProfileRequest());
        var secondSession = await ApiTestClient.ReadAsync<ProfileSessionResponse>(openedSecond);
        using var notes = await SendAsync(client, secondSession.Token, HttpMethod.Get, $"/api/v1/media/{mediaId}/notes");
        notes.EnsureSuccessStatusCode();
        Assert.Empty(await ApiTestClient.ReadAsync<List<SceneNoteSummary>>(notes));
        using var oldSession = await SendAsync(client, firstSession.Token, HttpMethod.Get, "/api/v1/home");
        Assert.Equal(HttpStatusCode.Unauthorized, oldSession.StatusCode);
    }

    private static async Task<UserSummary> CreateAsync(HttpClient client, string token, CreateUserRequest request)
    {
        using var response = await SendApprovedAsync(client, token, HttpMethod.Post, "/api/v1/users", request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<UserSummary>(response);
    }

    private static async Task<ProfileEditorResponse> EditorAsync(HttpClient client, string token, Guid id)
    {
        using var response = await SendAsync(client, token, HttpMethod.Get, $"/api/v1/users/{id}/profile");
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<ProfileEditorResponse>(response);
    }

    private static async Task<AuthenticationResponse> DeviceAsync(HttpClient client)
    {
        using var response = await client.PostAsJsonAsync("/api/v1/auth/login",
            new LoginRequest("lucas", "correct horse battery staple", "Synthetic profile device"), ApiTestClient.JsonOptions);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AuthenticationResponse>(response);
    }

    private static async Task<HttpResponseMessage> SendApprovedAsync(HttpClient client, string token, HttpMethod method, string path, object body)
    {
        using var request = ApiTestClient.Authorized(method, path, token, body);
        return await ApiTestClient.SendAsync(client, request);
    }

    private static async Task<HttpResponseMessage> SendAsync(HttpClient client, string token, HttpMethod method, string path, object? body = null)
    {
        using var request = ApiTestClient.Authorized(method, path, token, body);
        return await client.SendAsync(request);
    }
}
