using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.IntegrationTests;

public sealed class ConnectionFlowTests : IDisposable
{
    private readonly RealServer server = new();
    private readonly AureliaApi api;

    public ConnectionFlowTests() => api = new AureliaApi(server.Transport);

    public void Dispose()
    {
        api.Dispose();
        server.Dispose();
    }

    [Fact]
    public async Task PairsOpensTheOwnerProfileAndDisconnects()
    {
        var code = await server.CreatePairingCodeAsync();
        var inspected = await api.InspectAsync(RealServer.Address, TestContext.Current.CancellationToken);
        Assert.True(inspected.Info.IsSetup);

        var paired = await api.PairAsync(inspected, code[..4] + " " + code[4..], "Test Laptop", TestContext.Current.CancellationToken);
        Assert.Equal(inspected.Info.ServerId, paired.ServerId);

        var profiles = await api.ProfilesAsync(paired, TestContext.Current.CancellationToken);
        Assert.False(profiles.ManagementSetupRequired);
        var owner = Assert.Single(profiles.Profiles, profile => profile.Role == UserRole.Owner);
        Assert.True(owner.PinProtectionEnabled);

        var session = await api.UnlockProfileAsync(paired, owner.Id, RealServer.OwnerPin, TestContext.Current.CancellationToken);
        Assert.Equal(owner.Id, session.User.Id);
        Assert.True(session.CanManageMedia);
        Assert.True(session.ExpiresAt > DateTimeOffset.UtcNow);
        await api.EndProfileAsync(paired, session, TestContext.Current.CancellationToken);

        await api.DisconnectDeviceAsync(paired, TestContext.Current.CancellationToken);
        var revoked = await Assert.ThrowsAsync<AureliaApiException>(() => api.ProfilesAsync(paired, TestContext.Current.CancellationToken));
        Assert.True(revoked.IsAuthenticationFailure);
    }

    [Fact]
    public async Task ReportsAWrongCodeAndAWrongPin()
    {
        var code = await server.CreatePairingCodeAsync();
        var inspected = await api.InspectAsync(RealServer.Address, TestContext.Current.CancellationToken);
        var wrong = code == "00000000" ? "11111111" : "00000000";
        var codeError = await Assert.ThrowsAsync<AureliaApiException>(() => api.PairAsync(inspected, wrong, "Test Laptop", TestContext.Current.CancellationToken));
        Assert.Equal("invalid_pairing_code", codeError.Code);

        var paired = await api.PairAsync(inspected, code, "Test Laptop", TestContext.Current.CancellationToken);
        var owner = (await api.ProfilesAsync(paired, TestContext.Current.CancellationToken)).Profiles.Single();
        var pinError = await Assert.ThrowsAsync<AureliaApiException>(() => api.UnlockProfileAsync(paired, owner.Id, "9999", TestContext.Current.CancellationToken));
        Assert.Equal("invalid_profile_pin", pinError.Code);
    }

    [Fact]
    public async Task SetsUpProfilesForTheFirstTime()
    {
        var device = await server.SetUpOwnerAsync();
        var inspected = await api.InspectAsync(RealServer.Address, TestContext.Current.CancellationToken);
        var stored = new StoredServer(inspected.Info.ServerId, inspected.Info.Name, inspected.Address, inspected.Fingerprint,
            device.Token, device.SessionId, device.ExpiresAt, device.User);

        Assert.True((await api.ProfilesAsync(stored, TestContext.Current.CancellationToken)).ManagementSetupRequired);
        var wrongPassword = await Assert.ThrowsAsync<AureliaApiException>(
            () => api.InitializeProfilesAsync(stored, "not the password", "2468", TestContext.Current.CancellationToken));
        Assert.Equal("invalid_credentials", wrongPassword.Code);

        await api.InitializeProfilesAsync(stored, RealServer.OwnerPassword, "2468", TestContext.Current.CancellationToken);
        var profiles = await api.ProfilesAsync(stored, TestContext.Current.CancellationToken);
        Assert.False(profiles.ManagementSetupRequired);
        var opened = await api.UnlockProfileAsync(stored, profiles.Profiles.Single().Id, "2468", TestContext.Current.CancellationToken);
        Assert.True(opened.IsOwner);
    }

    [Fact]
    public async Task RefusesAServerWithAnotherIdentity()
    {
        var code = await server.CreatePairingCodeAsync();
        var inspected = await api.InspectAsync(RealServer.Address, TestContext.Current.CancellationToken);
        var paired = await api.PairAsync(inspected, code, "Test Laptop", TestContext.Current.CancellationToken);
        var impostor = paired with { ServerId = Guid.NewGuid() };
        var error = await Assert.ThrowsAsync<AureliaApiException>(() => api.ServerInfoAsync(impostor, TestContext.Current.CancellationToken));
        Assert.Equal("identity_mismatch", error.Code);
    }

    [Fact]
    public async Task TheScreensLeadFromConnectingToTheLibraryAndBackAfterARestart()
    {
        var code = await server.CreatePairingCodeAsync();
        var settings = new MemorySettingsStore();
        var keyring = new MemoryCredentialStore();
        var flow = new AppFlow(settings);
        var session = NewSession(flow, keyring);
        await session.StartAsync();
        Assert.Equal(AppScreen.Welcome, flow.Screen);
        flow.ChooseMode(OperatingMode.Client);

        using var connection = new ConnectionModel(session, new NoServerDiscovery(), action => action());
        connection.Address = "127.0.0.1";
        await connection.ConnectAsync();
        Assert.True(connection.IsVerifying, connection.Error);
        Assert.False(connection.CanPair);
        connection.FingerprintsMatch = true;
        connection.Code = code;
        Assert.True(connection.CanPair);
        await connection.PairAsync();
        Assert.Equal(AppScreen.ProfilePicker, flow.Screen);
        Assert.NotNull(keyring.Server);

        var picker = new ProfilePickerModel(session);
        await picker.LoadAsync();
        var owner = Assert.Single(picker.Profiles);
        await picker.ChooseAsync(owner);
        Assert.True(picker.IsEnteringPin);
        picker.Pin = "0000";
        await picker.SubmitPinAsync();
        Assert.Equal("PIN is incorrect.", picker.Error);
        Assert.Equal(1, picker.FailedAttempts);
        picker.Pin = RealServer.OwnerPin;
        await picker.SubmitPinAsync();
        Assert.Equal(AppScreen.Library, flow.Screen);
        Assert.Equal(owner.Id, session.Profile?.User.Id);

        await session.SwitchProfileAsync();
        Assert.Equal(AppScreen.ProfilePicker, flow.Screen);
        Assert.Null(session.Profile);

        // A restart finds the saved pairing and goes straight to the profile picker.
        var restartedFlow = new AppFlow(settings);
        var restarted = NewSession(restartedFlow, keyring);
        await restarted.StartAsync();
        Assert.Equal(AppScreen.ProfilePicker, restartedFlow.Screen);

        await restarted.DisconnectAsync();
        Assert.Null(keyring.Server);
        Assert.Equal(AppScreen.Connection, restartedFlow.Screen);
    }

    private AppSession NewSession(AppFlow flow, ICredentialStore keyring) =>
        new(flow, api, keyring, new ServerWakeUp(api, new NoWakeOnLan(), () => [], TimeProvider.System), "Test Laptop");
}
