using Aurelia.Desktop.Core;
using Xunit;

namespace Aurelia.Desktop.Tests;

/// <summary>
/// The app's connection code against the real server over real TLS: identity pinning, pairing
/// approved by the owner, profiles with and without PIN, restarting, and disconnecting.
/// </summary>
public sealed class RealServerTests
{
    [Fact]
    public async Task PairsChoosesProfilesAndReconnectsWithTheRealServer()
    {
        Assert.SkipWhen(SyntheticServer.Executable is null, "Run scripts/test-desktop.sh, which builds the server for this test.");
        await using var server = await SyntheticServer.StartAsync();
        using var api = new AureliaServerApi();
        var secrets = new MemorySecretStore();
        var store = new ConnectionStore(secrets);
        using var flow = new ConnectionFlow(api, store, new NoServerDiscovery(), "Synthetic Windows PC", action => action());

        await flow.StartAsync();
        flow.Address = $"127.0.0.1:{server.HttpsPort}";
        await flow.ConnectAsync();
        Assert.Null(flow.Error);
        Assert.Equal(ConnectionPhase.Trust, flow.Phase);
        Assert.Equal("Synthetic Desktop Test", flow.ServerName);
        // The fingerprint read over TLS is the one the server reports for itself.
        Assert.Equal(ServerIdentity.Display(server.Fingerprint), flow.FingerprintDisplay);

        var pairing = flow.TrustAndPairAsync();
        for (var attempt = 0; attempt < 100 && flow.PairingCode.Length == 0; attempt++)
            await Task.Delay(50, TestContext.Current.CancellationToken);
        Assert.Equal(ConnectionPhase.Pairing, flow.Phase);
        await server.ApproveAsync(flow.PairingCode);
        await pairing.WaitAsync(TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken);
        Assert.Null(flow.Error);
        Assert.Equal(ConnectionPhase.Profiles, flow.Phase);
        Assert.Contains(flow.Profiles, profile => profile.Name == SyntheticServer.OwnerName && profile.PinProtectionEnabled);
        Assert.Contains(flow.Profiles, profile => profile.Name == SyntheticServer.GuestName && !profile.PinProtectionEnabled);
        var saved = store.Load();
        Assert.NotNull(saved);
        Assert.Null(saved.PendingAcknowledgement);
        Assert.Equal(server.Fingerprint, saved.Fingerprint);

        var owner = flow.Profiles.Single(profile => profile.Name == SyntheticServer.OwnerName);
        await flow.ChooseProfileAsync(owner);
        await flow.SubmitPinAsync("0000");
        Assert.Equal("That PIN is not correct.", flow.Error);
        await flow.SubmitPinAsync(SyntheticServer.OwnerPin);
        Assert.Equal(ConnectionPhase.Connected, flow.Phase);
        Assert.Equal(SyntheticServer.OwnerName, flow.SignedInName);

        // A restart reconnects with the saved credential and the pinned identity.
        using var restarted = new ConnectionFlow(api, store, new NoServerDiscovery(), "Synthetic Windows PC", action => action());
        await restarted.StartAsync();
        Assert.Null(restarted.Error);
        Assert.Equal(ConnectionPhase.Profiles, restarted.Phase);
        await restarted.ChooseProfileAsync(restarted.Profiles.Single(profile => profile.Name == SyntheticServer.GuestName));
        Assert.Equal(ConnectionPhase.Connected, restarted.Phase);

        // A server presenting a different key is refused, and the saved connection forgotten.
        var tampered = new ConnectionStore(new MemorySecretStore());
        tampered.Save(saved with { Fingerprint = new string('B', 64) });
        using var impostor = new ConnectionFlow(api, tampered, new NoServerDiscovery(), "Synthetic Windows PC", action => action());
        await impostor.StartAsync();
        Assert.Equal(ConnectionPhase.Connect, impostor.Phase);
        Assert.Null(tampered.Load());

        // Disconnecting revokes this computer on the server.
        await restarted.DisconnectAsync();
        Assert.Null(store.Load());
        var revoked = await Assert.ThrowsAsync<AureliaApiException>(() => api.ProfilesAsync(saved, CancellationToken.None));
        Assert.Equal(401, revoked.Status);
    }

    [Fact]
    public async Task AnAddressWithoutAnAureliaServerIsExplained()
    {
        using var api = new AureliaServerApi();
        using var flow = new ConnectionFlow(api, new ConnectionStore(new MemorySecretStore()), new NoServerDiscovery(), "Synthetic PC",
            action => action());
        await flow.StartAsync();
        // A loopback port with nothing listening.
        using var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        flow.Address = $"127.0.0.1:{port}";
        await flow.ConnectAsync();
        Assert.Equal(ConnectionPhase.Connect, flow.Phase);
        Assert.Equal(AureliaApiException.Unreachable().Message, flow.Error);
    }
}
