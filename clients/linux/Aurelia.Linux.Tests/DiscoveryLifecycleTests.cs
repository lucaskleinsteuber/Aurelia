using System.Net.Sockets;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Views;
using Avalonia.Headless.XUnit;
using Avalonia.Threading;
using Haukcode.Mdns;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class DiscoveryLifecycleTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void UnavailableMulticastLeavesAnEmptyCacheAndDisposesFailedBrowsers(bool socketFailure)
    {
        var created = new List<FakeBrowser>();
        using var discovery = new MdnsServerDiscovery(_ =>
        {
            var browser = new FakeBrowser(socketFailure
                ? new SocketException((int)SocketError.NetworkUnreachable)
                : new InvalidOperationException("No multicast-capable network interfaces found"));
            created.Add(browser);
            return browser;
        });
        using var cache = new DiscoveryCache(discovery);

        Assert.Empty(cache.Latest);
        Assert.Equal(2, created.Count);
        Assert.All(created, browser => Assert.Equal(1, browser.DisposeCount));
    }

    [Fact]
    public async Task ABackgroundNetworkChangeRetriesOnlyTheFailedBrowser()
    {
        var available = false;
        var created = new List<FakeBrowser>();
        using var discovery = new MdnsServerDiscovery(type =>
        {
            var browser = new FakeBrowser(!available && type == MdnsServerDiscovery.ServiceTypes[1]
                ? new InvalidOperationException("No multicast-capable network interfaces found") : null);
            created.Add(browser);
            return browser;
        });
        discovery.Start();
        Assert.Equal(0, created[0].DisposeCount);
        Assert.Equal(1, created[1].DisposeCount);

        available = true;
        await Task.Run(() => discovery.OnNetworkAddressChanged(null, EventArgs.Empty), TestContext.Current.CancellationToken);
        await Task.Run(() => discovery.OnNetworkAddressChanged(null, EventArgs.Empty), TestContext.Current.CancellationToken);

        Assert.Equal(3, created.Count);
        Assert.All(created, browser => Assert.Equal(1, browser.StartCount));
        Assert.Equal(0, created[0].DisposeCount);
        Assert.Equal(0, created[2].DisposeCount);
        discovery.Halt();
        Assert.All(created, browser => Assert.Equal(1, browser.DisposeCount));

        // A notification or receive callback already queued before Halt cannot restart discovery
        // or publish a server from a browser that no longer belongs to this session.
        await Task.Run(() => discovery.OnNetworkAddressChanged(null, EventArgs.Empty), TestContext.Current.CancellationToken);
        created[0].RaiseLateCallbacks();
        Assert.Equal(3, created.Count);
    }

    [AvaloniaFact]
    public async Task OfflineStartupStillAllowsAHandEnteredServerAddress()
    {
        using var discovery = new MdnsServerDiscovery(_ =>
            new FakeBrowser(new InvalidOperationException("No multicast-capable network interfaces found")));
        var server = FakeServer.WithServerInfo();
        var window = TestWindows.Show(AppServices.ForTests(transport: server) with { CreateDiscovery = () => discovery });
        try
        {
            window.Flow.ChooseMode(OperatingMode.Client);
            Dispatcher.UIThread.RunJobs();
            var connection = Assert.IsType<ConnectionView>(window.CurrentScreen);
            Assert.Empty(connection.Model.Nearby);

            connection.Model.Address = "192.168.1.20";
            await connection.Model.ConnectAsync();

            Assert.True(connection.Model.IsVerifying, connection.Model.Error);
            Assert.Equal(FakeServer.ServerId, connection.Model.Inspected?.Info.ServerId);
            Assert.Contains("GET /api/v1/server/info", server.Requests);
        }
        finally
        {
            window.Close();
        }
    }

    private sealed class FakeBrowser(Exception? startFailure) : IMdnsDiscoveryBrowser
    {
        public event Action<ServiceProfile>? ServiceFound;
        public event Action<ServiceProfile>? ServiceLost;

        public int StartCount { get; private set; }
        public int DisposeCount { get; private set; }

        public void Start()
        {
            StartCount++;
            if (startFailure is not null) throw startFailure;
        }

        public void Dispose() => DisposeCount++;

        public void RaiseLateCallbacks()
        {
            ServiceFound?.Invoke(null!);
            ServiceLost?.Invoke(null!);
        }
    }
}
