using Aurelia.Contracts;
using Aurelia.Desktop.Core;
using Xunit;

namespace Aurelia.Desktop.Tests;

public sealed class ConnectionFlowTests
{
    internal static (ConnectionFlow Flow, FakeServerApi Api, MemorySecretStore Secrets) Create(StoredConnection? saved = null)
    {
        var api = new FakeServerApi();
        var secrets = new MemorySecretStore();
        var store = new ConnectionStore(secrets);
        if (saved is not null) store.Save(saved);
        var flow = new ConnectionFlow(api, store, new NoServerDiscovery(), "Synthetic PC", action => action(),
            delay: (_, _) => Task.CompletedTask);
        return (flow, api, secrets);
    }

    [Fact]
    public async Task AFirstConnectionGoesFromTheAddressToAnOpenProfile()
    {
        var (flow, api, secrets) = Create();
        await flow.StartAsync();
        Assert.Equal(ConnectionPhase.Connect, flow.Phase);

        flow.Address = "192.168.1.20";
        await flow.ConnectAsync();
        Assert.Equal(ConnectionPhase.Trust, flow.Phase);
        Assert.Equal("Living Room Mac", flow.ServerName);
        Assert.Equal("AAAA-AAAA-AAAA-AAAA-AAAA-AAAA", flow.FingerprintDisplay);
        Assert.Contains("inspect 192.168.1.20:43111", api.Calls);

        await flow.TrustAndPairAsync();
        Assert.Equal("4815 1623", flow.PairingCode);
        Assert.Equal(ConnectionPhase.Profiles, flow.Phase);
        Assert.Equal(["Alex", "Guest"], flow.Profiles.Select(profile => profile.Name));
        // The credential was saved before acknowledging, and is final afterwards.
        Assert.Equal(["inspect 192.168.1.20:43111", "pair Synthetic PC", "status", "status", "ack", "profiles"], api.Calls);
        var saved = new ConnectionStore(secrets).Load();
        Assert.NotNull(saved);
        Assert.Null(saved.PendingAcknowledgement);

        await flow.ChooseProfileAsync(FakeServerApi.Owner);
        Assert.Equal(ConnectionPhase.Pin, flow.Phase);
        Assert.Equal("Enter the PIN for Alex", flow.PinPrompt);
        await flow.SubmitPinAsync("12");
        Assert.Equal("Enter a PIN with four to eight digits.", flow.Error);
        await flow.SubmitPinAsync("0000");
        Assert.Equal("That PIN is not correct.", flow.Error);
        Assert.Equal(ConnectionPhase.Pin, flow.Phase);
        await flow.SubmitPinAsync("5682");
        Assert.Equal(ConnectionPhase.Connected, flow.Phase);
        Assert.Equal("Alex", flow.SignedInName);
        Assert.Null(flow.Error);
    }

    [Fact]
    public async Task AProfileWithoutPinOpensDirectlyAndSwitchingEndsIt()
    {
        var (flow, api, _) = Create(FakeServerApi.Saved());
        await flow.StartAsync();
        Assert.Equal(ConnectionPhase.Profiles, flow.Phase);
        await flow.ChooseProfileAsync(FakeServerApi.Guest);
        Assert.Equal(ConnectionPhase.Connected, flow.Phase);
        Assert.Contains("unlock -", api.Calls);

        await flow.SwitchProfileAsync();
        Assert.Equal(ConnectionPhase.Profiles, flow.Phase);
        Assert.Contains("end", api.Calls);
        Assert.Null(flow.Session);
    }

    [Fact]
    public async Task ADeniedPairingReturnsToTheTrustStepWithAReason()
    {
        var (flow, api, secrets) = Create();
        api.PairingResult = DeviceAuthorizationState.Denied;
        await flow.StartAsync();
        flow.Address = "192.168.1.20";
        await flow.ConnectAsync();
        await flow.TrustAndPairAsync();
        Assert.Equal(ConnectionPhase.Trust, flow.Phase);
        Assert.Equal("This computer was not approved on your Mac.", flow.Error);
        Assert.Null(secrets.Value);
    }

    [Fact]
    public async Task AnUnfinishedAcknowledgementIsCompletedOnTheNextStart()
    {
        var (flow, api, secrets) = Create(FakeServerApi.Saved(new PendingPairing(Guid.NewGuid(), new string('s', 43))));
        await flow.StartAsync();
        Assert.Equal(["ack", "info", "profiles"], api.Calls);
        Assert.Null(new ConnectionStore(secrets).Load()!.PendingAcknowledgement);
        Assert.Equal(ConnectionPhase.Profiles, flow.Phase);
    }

    [Fact]
    public async Task AnOfflineServerIsKeptAndCanBeTriedAgain()
    {
        var (flow, api, secrets) = Create(FakeServerApi.Saved());
        api.InfoFailure = AureliaApiException.Unreachable();
        await flow.StartAsync();
        Assert.Equal(ConnectionPhase.Profiles, flow.Phase);
        Assert.StartsWith("Living Room Mac could not be reached.", flow.Error);
        Assert.NotNull(secrets.Value);
        Assert.Empty(flow.Profiles);

        await flow.RefreshProfilesAsync();
        Assert.Null(flow.Error);
        Assert.Equal(2, flow.Profiles.Count);
    }

    [Theory]
    [InlineData(401, "invalid_session")]
    [InlineData(0, "identity_mismatch")]
    public async Task ARevokedDeviceOrChangedIdentityIsForgotten(int status, string code)
    {
        var (flow, api, secrets) = Create(FakeServerApi.Saved());
        api.InfoFailure = new AureliaApiException(status, code, "Connect again.");
        await flow.StartAsync();
        Assert.Equal(ConnectionPhase.Connect, flow.Phase);
        Assert.Equal("Connect again.", flow.Error);
        Assert.Null(secrets.Value);
    }

    [Fact]
    public async Task DisconnectingRemovesThisComputerFromTheServerAndHere()
    {
        var (flow, api, secrets) = Create(FakeServerApi.Saved());
        await flow.StartAsync();
        await flow.DisconnectAsync();
        Assert.Equal(ConnectionPhase.Connect, flow.Phase);
        Assert.Null(secrets.Value);
        Assert.Contains("disconnect", api.Calls);
    }

    [Fact]
    public async Task AnInvalidAddressIsExplainedWithoutContactingAnything()
    {
        var (flow, api, _) = Create();
        await flow.StartAsync();
        flow.Address = "http://192.168.1.20";
        await flow.ConnectAsync();
        Assert.Equal("Enter a server address such as 192.168.1.20.", flow.Error);
        Assert.Empty(api.Calls);
    }
}
