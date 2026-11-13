using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class SecurityTests
{
    private const string Installation = "5f1b6a3e-4a64-4e3b-9d44-0c7a3c1e9b21";

    [Fact]
    public async Task ANewDeviceIsLoggedShownAsNewAndConfirmedByTheOwner()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var paired = await PairAsync(client, owner.Token, "Synthetic iPhone", Installation, "ios/2.11.0");

        var alerts = await GetAsync<SecurityAlertsResponse>(client, owner.Token, "/api/v1/server/security/alerts");
        var device = Assert.Single(alerts.NewDevices);
        Assert.Equal(paired.SessionId, device.Id);
        Assert.Equal("iPhone or iPad", device.Platform);
        Assert.Equal("2.11.0", device.ClientVersion);
        Assert.True(device.IsNew);

        var events = await EventsAsync(client, owner.Token);
        var signIn = Assert.Single(events, entry => entry.Kind == "signed_in" && entry.DeviceSessionId == paired.SessionId);
        Assert.Equal("Device code", signIn.Detail);
        Assert.Equal("Synthetic iPhone", signIn.DeviceName);

        using (var acknowledge = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/server/security/devices/{paired.SessionId}/acknowledge", owner.Token))
        using (var response = await client.SendAsync(acknowledge))
            Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.Empty((await GetAsync<SecurityAlertsResponse>(client, owner.Token, "/api/v1/server/security/alerts")).NewDevices);
        var all = await GetAsync<SecurityDeviceSummary[]>(client, owner.Token, "/api/v1/server/security/devices");
        Assert.Contains(all, value => value.IsCurrent && !value.CanBlock);
        Assert.Contains(all, value => value.Id == paired.SessionId && !value.IsNew);
    }

    [Fact]
    public async Task WaitingForAlertsReturnsAsSoonAsADeviceSignsIn()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var first = await GetAsync<SecurityAlertsResponse>(client, owner.Token, "/api/v1/server/security/alerts");
        var waiting = GetAsync<SecurityAlertsResponse>(client, owner.Token, $"/api/v1/server/security/alerts?version={first.Version}&waitSeconds=20");
        await Task.Delay(200);
        Assert.False(waiting.IsCompleted);
        await PairAsync(client, owner.Token, "Synthetic Laptop", null, "linux/2.7.0");
        var answer = await waiting.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.NotEqual(first.Version, answer.Version);
        Assert.Single(answer.NewDevices);
    }

    [Fact]
    public async Task FailedAttemptsAndAdministratorChangesAreLoggedWithoutSecrets()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        UserSummary viewer;
        using (var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                   new CreateUserRequest("Synthetic Kid", string.Empty, UserRole.User, "4821")))
        using (var response = await ApiTestClient.SendAsync(client, create))
        {
            response.EnsureSuccessStatusCode();
            viewer = await ApiTestClient.ReadAsync<UserSummary>(response);
        }
        var paired = await PairAsync(client, owner.Token, "Synthetic TV", Installation, "tvos/2.6.0");
        using (var wrong = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/profiles/{viewer.Id}/unlock", paired.Token, new UnlockProfileRequest("9999")))
        using (var response = await client.SendAsync(wrong))
            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        using (var right = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/profiles/{viewer.Id}/unlock", paired.Token, new UnlockProfileRequest("4821")))
        using (var response = await client.SendAsync(right))
            response.EnsureSuccessStatusCode();
        using (var delete = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/users/{viewer.Id}", owner.Token))
        using (var response = await ApiTestClient.SendAsync(client, delete))
            response.EnsureSuccessStatusCode();
        using (var badCode = new HttpRequestMessage(HttpMethod.Post, "/api/v1/auth/pair") { Content = JsonContent.Create(new RedeemPairingCodeRequest("00000000", "Stranger")) })
        using (var response = await client.SendAsync(badCode))
            Assert.False(response.IsSuccessStatusCode);

        var events = await EventsAsync(client, owner.Token);
        Assert.Contains(events, entry => entry.Kind == "profile_created" && entry.Outcome == "changed");
        var wrongPin = Assert.Single(events, entry => entry.Kind == "wrong_pin");
        Assert.Equal("failed", wrongPin.Outcome);
        Assert.Equal("Profile PIN", wrongPin.Detail);
        Assert.Equal("Synthetic TV", wrongPin.DeviceName);
        var opened = Assert.Single(events, entry => entry.Kind == "profile_opened" && entry.DeviceName == "Synthetic TV");
        Assert.Equal("Synthetic Kid", opened.Detail);
        Assert.Equal(viewer.Id, opened.UserId);
        Assert.Equal("Synthetic Kid", Assert.Single(events, entry => entry.Kind == "profile_deleted").Detail);
        Assert.Contains(events, entry => entry.Kind == "wrong_code");

        var failed = await GetAsync<SecurityEventPage>(client, owner.Token, "/api/v1/server/security/events?outcome=failed");
        Assert.All(failed.Events, entry => Assert.Equal("failed", entry.Outcome));
        var serialized = System.Text.Json.JsonSerializer.Serialize(events);
        foreach (var secret in new[] { "4821", "9999", ApiTestClient.TestPin, "correct horse battery staple", owner.Token, paired.Token })
            Assert.DoesNotContain(secret, serialized);
    }

    [Fact]
    public async Task ABlockedDeviceIsSignedOutAndCanNotPairAgainUntilUnblocked()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var paired = await PairAsync(client, owner.Token, "Unknown Tablet", Installation, "web/1");

        BlockDeviceResponse blocked;
        using (var block = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/server/security/devices/{paired.SessionId}/block", owner.Token))
        using (var response = await client.SendAsync(block))
        {
            response.EnsureSuccessStatusCode();
            blocked = await ApiTestClient.ReadAsync<BlockDeviceResponse>(response);
        }
        Assert.True(blocked.Listed);
        using (var me = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/profiles", paired.Token))
        using (var response = await client.SendAsync(me))
            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);

        var code = await CodeAsync(client, owner.Token);
        using (var again = Pair(code, "Unknown Tablet", Installation, null))
        using (var response = await client.SendAsync(again))
        {
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
            Assert.Equal("device_blocked", (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
        }
        var events = await EventsAsync(client, owner.Token);
        Assert.Contains(events, entry => entry.Kind == "device_blocked" && entry.Detail == "Unknown Tablet");
        Assert.Contains(events, entry => entry.Kind == "blocked_device_refused");

        var list = await GetAsync<BlockedDeviceSummary[]>(client, owner.Token, "/api/v1/server/security/blocked");
        var entry = Assert.Single(list);
        using (var unblockWithoutApproval = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/server/security/blocked/{entry.Id}", owner.Token))
        using (var response = await client.SendAsync(unblockWithoutApproval))
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        using (var unblock = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/server/security/blocked/{entry.Id}", owner.Token))
        using (var response = await ApiTestClient.SendAsync(client, unblock))
            Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        var fresh = await CodeAsync(client, owner.Token);
        using (var paired2 = Pair(fresh, "Unknown Tablet", Installation, null))
        using (var response = await client.SendAsync(paired2))
            response.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task OnlyTheOwnerReadsTheLogAndTheCurrentDeviceCanNotBeBlocked()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using (var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                   new CreateUserRequest("security-viewer", "synthetic viewer password", UserRole.User, ApiTestClient.TestPin)))
        using (var response = await ApiTestClient.SendAsync(client, create))
            response.EnsureSuccessStatusCode();
        AuthenticationResponse viewer;
        using (var login = await ApiTestClient.LoginAsync(client, new LoginRequest("security-viewer", "synthetic viewer password", "Synthetic Viewer")))
            viewer = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
        foreach (var path in new[] { "/api/v1/server/security/events", "/api/v1/server/security/devices", "/api/v1/server/security/blocked",
                     "/api/v1/server/security/settings", "/api/v1/server/security/alerts", "/api/v1/management/passkeys" })
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, path, viewer.Token);
            using var response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        }
        var self = owner.SessionId;
        using var block = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/server/security/devices/{self}/block", owner.Token);
        using var refused = await client.SendAsync(block);
        Assert.Equal(HttpStatusCode.Conflict, refused.StatusCode);
    }

    [Fact]
    public async Task FaceIdUnlocksManagementWithAFreshSignatureOnly()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var passkey = await RegisterAsync(client, owner.Token, key, "Synthetic iPhone");
        Assert.True(passkey.IsThisDevice);

        await LockAsync(client, owner.Token);
        var challenge = await ChallengeAsync(client, owner.Token);
        using (var unlock = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/passkey-unlock", owner.Token,
                   new PasskeyUnlockRequest(passkey.Id, challenge, Sign(key, "unlock", challenge))))
        using (var response = await client.SendAsync(unlock))
            response.EnsureSuccessStatusCode();

        // The same challenge never works twice.
        using (var replay = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/passkey-unlock", owner.Token,
                   new PasskeyUnlockRequest(passkey.Id, challenge, Sign(key, "unlock", challenge))))
        using (var response = await client.SendAsync(replay))
            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);

        // A signature for another purpose or from another key is refused.
        using var stranger = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        foreach (var (signer, purpose) in new[] { (key, "register"), (stranger, "unlock") })
        {
            var fresh = await ChallengeAsync(client, owner.Token);
            using var attempt = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/passkey-unlock", owner.Token,
                new PasskeyUnlockRequest(passkey.Id, fresh, Sign(signer, purpose, fresh)));
            using var response = await client.SendAsync(attempt);
            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        }

        // The key works only from the device it was made on.
        var other = await PairAsync(client, owner.Token, "Synthetic Mac", null, "macos/2.15.0");
        var otherProfile = await ApiTestClient.UnlockDeviceAsync(client, other, owner.User.Id);
        var otherChallenge = await ChallengeAsync(client, otherProfile.Token);
        using (var foreign = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/passkey-unlock", otherProfile.Token,
                   new PasskeyUnlockRequest(passkey.Id, otherChallenge, Sign(key, "unlock", otherChallenge))))
        using (var response = await client.SendAsync(foreign))
            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);

        var events = await EventsAsync(client, owner.Token);
        Assert.Contains(events, entry => entry.Kind == "passkey_added");
        Assert.Contains(events, entry => entry.Kind == "management_unlocked" && entry.Detail?.StartsWith("Face ID", StringComparison.Ordinal) == true);
        Assert.Contains(events, entry => entry.Kind == "passkey_failed");
        Assert.Contains(events, entry => entry.Kind == "management_unlocked" && entry.Detail == "Server Password");
    }

    [Fact]
    public async Task RequiredFaceIdNeedsTheOwnersKeyAndRefusesThePasswordAwayFromTheServer()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using (var early = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/server/security/settings", owner.Token, new UpdateSecuritySettingsRequest(90, true)))
        using (var response = await ApiTestClient.SendAsync(client, early))
            Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);

        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        await RegisterAsync(client, owner.Token, key, "Synthetic iPhone");
        using (var enable = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/server/security/settings", owner.Token, new UpdateSecuritySettingsRequest(120, true)))
        using (var response = await ApiTestClient.SendAsync(client, enable))
        {
            response.EnsureSuccessStatusCode();
            var saved = await ApiTestClient.ReadAsync<SecuritySettingsResponse>(response);
            Assert.True(saved.RequirePasskeysForAdministrators);
            Assert.Equal(120, saved.SecurityLogDays);
        }

        // The test server has no client address; only the server computer itself (loopback) may still use the password.
        using (var password = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/unlock", owner.Token, new UnlockManagementRequest("correct horse battery staple")))
        using (var response = await client.SendAsync(password))
        {
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
            Assert.Equal("passkey_required", (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
        }
        var loopback = new DefaultHttpContext();
        loopback.Connection.RemoteIpAddress = IPAddress.IPv6Loopback;
        Assert.True(ClientIdentity.IsLoopback(loopback));
        loopback.Connection.RemoteIpAddress = IPAddress.Parse("192.0.2.10");
        Assert.False(ClientIdentity.IsLoopback(loopback));
        Assert.Contains(await EventsAsync(client, owner.Token), entry => entry.Kind == "password_refused");
        Assert.Contains(await EventsAsync(client, owner.Token), entry => entry.Kind == "passkey_requirement_changed" && entry.Detail == "Required");
    }

    [Fact]
    public async Task ADeviceWithoutFaceIdIsUnlockedOnlyAfterTheOwnerConfirmsOnTheirs()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var passkey = await RegisterAsync(client, owner.Token, key, "Synthetic iPhone");

        var laptop = await PairAsync(client, owner.Token, "Synthetic Linux Laptop", null, "linux/2.7.0");
        var laptopProfile = await ApiTestClient.UnlockDeviceAsync(client, laptop, owner.User.Id);
        await LockAsync(client, laptopProfile.Token);
        RemoteUnlockStartResponse started;
        using (var start = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/remote-unlock", laptopProfile.Token))
        using (var response = await client.SendAsync(start))
        {
            response.EnsureSuccessStatusCode();
            started = await ApiTestClient.ReadAsync<RemoteUnlockStartResponse>(response);
        }
        Assert.Matches("^[0-9]{4}$", started.Code);
        Assert.Equal("pending", (await GetAsync<RemoteUnlockStatusResponse>(client, laptopProfile.Token, $"/api/v1/management/remote-unlock/{started.Id}")).State);

        // Only the device with the key sees the request; the laptop does not.
        Assert.Empty((await GetAsync<SecurityAlertsResponse>(client, laptopProfile.Token, "/api/v1/server/security/alerts")).UnlockRequests);
        var request = Assert.Single((await GetAsync<SecurityAlertsResponse>(client, owner.Token, "/api/v1/server/security/alerts")).UnlockRequests);
        Assert.Equal(started.Code, request.Code);

        // Approving needs a signature over this very request.
        var challenge = await ChallengeAsync(client, owner.Token);
        using (var wrong = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/management/remote-unlock/{started.Id}/decide", owner.Token,
                   new DecideRemoteUnlockRequest(true, passkey.Id, challenge, Sign(key, "unlock", challenge))))
        using (var response = await client.SendAsync(wrong))
            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        var second = await ChallengeAsync(client, owner.Token);
        using (var approve = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/management/remote-unlock/{started.Id}/decide", owner.Token,
                   new DecideRemoteUnlockRequest(true, passkey.Id, second, Sign(key, "remote:" + started.Id.ToString("N"), second))))
        using (var response = await client.SendAsync(approve))
            Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);

        var status = await GetAsync<RemoteUnlockStatusResponse>(client, laptopProfile.Token, $"/api/v1/management/remote-unlock/{started.Id}");
        Assert.Equal("approved", status.State);
        Assert.NotNull(status.ManagementExpiresAt);
        // The laptop may now get approvals for protected changes.
        using (var approval = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/approval", laptopProfile.Token,
                   new AdministrationApprovalRequest("DELETE /api/v1/libraries/" + Guid.NewGuid(), AdministrationApprovalStore.Hash([]))))
        using (var response = await client.SendAsync(approval))
            response.EnsureSuccessStatusCode();
        Assert.Contains(await EventsAsync(client, owner.Token), entry => entry.Kind == "management_unlocked" && entry.Detail == "Confirmed on another device");
    }

    [Fact]
    public void ChangesAreClassifiedByMethodAndPath()
    {
        var id = Guid.NewGuid();
        Assert.Equal(new SecurityChange("library_removed", "changed", SecurityTarget.Library, id),
            SecurityChangeClassifier.Classify("DELETE", $"/api/v1/libraries/{id}"));
        Assert.Equal("screen_time_changed", SecurityChangeClassifier.Classify("PUT", $"/api/v1/users/{id}/screen-time")?.Kind);
        Assert.Equal("profile_changed", SecurityChangeClassifier.Classify("PUT", $"/api/v1/users/{id}/age-limit")?.Kind);
        Assert.Equal("profile_opened", SecurityChangeClassifier.Classify("POST", $"/api/v1/web/profiles/{id}/unlock")?.Kind);
        Assert.Null(SecurityChangeClassifier.Classify("GET", $"/api/v1/libraries/{id}"));
        Assert.Null(SecurityChangeClassifier.Classify("PUT", $"/api/v1/media/{id}/progress"));
        Assert.Equal("wrong_password", SecurityChangeClassifier.FailureKind("invalid_credentials"));
        Assert.Null(SecurityChangeClassifier.FailureKind("approval_required"));
        Assert.Equal(("iPhone or iPad", "2.11.0"), ClientIdentity.Client("ios/2.11.0"));
        Assert.Equal((null, null), ClientIdentity.Client("evil/1"));
        Assert.Equal("Browser · Safari on iPhone", ClientIdentity.BrowserPlatform(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1"));
        Assert.Null(ClientIdentity.Installation("not-a-guid"));
        Assert.Equal("5f1b6a3e4a644e3b9d440c7a3c1e9b21", ClientIdentity.Installation(Installation));
    }

    // MARK: Helpers

    private static async Task<string> CodeAsync(HttpClient client, string ownerToken)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/auth/pairings", ownerToken);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return (await ApiTestClient.ReadAsync<PairingCodeResponse>(response)).Code;
    }

    private static HttpRequestMessage Pair(string code, string name, string? installation, string? clientHeader)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/auth/pair")
        { Content = JsonContent.Create(new RedeemPairingCodeRequest(code, name), options: ApiTestClient.JsonOptions) };
        if (installation is not null) request.Headers.Add(ClientIdentity.InstallationHeader, installation);
        if (clientHeader is not null) request.Headers.Add(ClientIdentity.ClientHeader, clientHeader);
        return request;
    }

    private static async Task<AuthenticationResponse> PairAsync(HttpClient client, string ownerToken, string name, string? installation, string? clientHeader)
    {
        var code = await CodeAsync(client, ownerToken);
        using var request = Pair(code, name, installation, clientHeader);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AuthenticationResponse>(response);
    }

    private static async Task<T> GetAsync<T>(HttpClient client, string token, string path)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, path, token);
        using var response = await client.SendAsync(request);
        Assert.True(response.IsSuccessStatusCode, $"{path} answered {(int)response.StatusCode}: {await response.Content.ReadAsStringAsync()}");
        return await ApiTestClient.ReadAsync<T>(response);
    }

    private static async Task<IReadOnlyList<SecurityEventSummary>> EventsAsync(HttpClient client, string token) =>
        (await GetAsync<SecurityEventPage>(client, token, "/api/v1/server/security/events?limit=500")).Events;

    private static async Task<string> ChallengeAsync(HttpClient client, string token)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/passkey-challenge", token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return (await ApiTestClient.ReadAsync<PasskeyChallengeResponse>(response)).Challenge;
    }

    private static string Sign(ECDsa key, string purpose, string challenge) =>
        Convert.ToBase64String(key.SignData(PasskeyService.Message(purpose, challenge), HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence));

    private static string PublicKey(ECDsa key)
    {
        var point = key.ExportParameters(false).Q;
        return Convert.ToBase64String([0x04, .. point.X!, .. point.Y!]);
    }

    private static async Task<PasskeySummary> RegisterAsync(HttpClient client, string token, ECDsa key, string name)
    {
        var challenge = await ChallengeAsync(client, token);
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/passkeys", token,
            new RegisterPasskeyRequest(name, PublicKey(key), challenge, Sign(key, "register", challenge)));
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
        return await ApiTestClient.ReadAsync<PasskeySummary>(response);
    }

    private static async Task LockAsync(HttpClient client, string token)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/lock", token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
    }
}
