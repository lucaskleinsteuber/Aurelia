using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Aurelia.Linux.Core.Api;
using Haukcode.Mdns;

namespace Aurelia.Linux.Core.Connection;

/// <summary>Finds Aurelia servers that announce themselves on the local network.</summary>
public interface IServerDiscovery : IDisposable
{
    /// <summary>Raised on a background thread with the full current list.</summary>
    event Action<IReadOnlyList<DiscoveredServer>>? Changed;

    void Start();

    void Halt();
}

/// <summary>Used where browsing must not touch the network, as in tests.</summary>
public sealed class NoServerDiscovery : IServerDiscovery
{
    public event Action<IReadOnlyList<DiscoveredServer>>? Changed
    {
        add { }
        remove { }
    }

    public void Start()
    {
    }

    public void Halt()
    {
    }

    public void Dispose()
    {
    }
}

/// <summary>
/// Browses for "_aurelia._tcp", the service every Aurelia server announces, and the older
/// "_aurelia-home._tcp". Only servers that announce TLS are listed; one server found under both
/// names or on several addresses appears once.
/// </summary>
public sealed class MdnsServerDiscovery : IServerDiscovery
{
    public static readonly string[] ServiceTypes = ["_aurelia._tcp", "_aurelia-home._tcp"];

    private readonly Lock gate = new();
    private readonly Dictionary<string, DiscoveredServer> found = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, IMdnsDiscoveryBrowser> browsers = [];
    private readonly Func<string, IMdnsDiscoveryBrowser> createBrowser;
    private bool running;

    public MdnsServerDiscovery() : this(type => new MdnsDiscoveryBrowser(type))
    {
    }

    internal MdnsServerDiscovery(Func<string, IMdnsDiscoveryBrowser> createBrowser) => this.createBrowser = createBrowser;

    public event Action<IReadOnlyList<DiscoveredServer>>? Changed;

    public void Start() => StartBrowsers(initial: true);

    internal void OnNetworkAddressChanged(object? sender, EventArgs args) => StartBrowsers(initial: false);

    private void StartBrowsers(bool initial)
    {
        List<IMdnsDiscoveryBrowser> failed = [];
        lock (gate)
        {
            if (!running)
            {
                if (!initial) return;
                running = true;
                NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
            }
            foreach (var type in ServiceTypes)
            {
                if (browsers.ContainsKey(type)) continue;
                IMdnsDiscoveryBrowser? browser = null;
                try
                {
                    browser = createBrowser(type);
                    browser.ServiceFound += service => Update(browser, service, add: true);
                    browser.ServiceLost += service => Update(browser, service, add: false);
                    browsers.Add(type, browser);
                    browser.Start();
                }
                catch (Exception failure) when (failure is SocketException or InvalidOperationException)
                {
                    // No multicast-capable interface is a normal offline state. The manual
                    // address still works; retry when an interface later gains an address.
                    browsers.Remove(type);
                    if (browser is not null) failed.Add(browser);
                }
            }
        }
        // A browser may wait for its receive callbacks while disposing. Do not hold their lock.
        foreach (var browser in failed) browser.Dispose();
    }

    public void Halt()
    {
        IMdnsDiscoveryBrowser[] stopped;
        lock (gate)
        {
            if (running) NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
            running = false;
            stopped = [.. browsers.Values];
            browsers.Clear();
            found.Clear();
        }
        foreach (var browser in stopped) browser.Dispose();
        Changed?.Invoke([]);
    }

    public void Dispose() => Halt();

    private void Update(IMdnsDiscoveryBrowser browser, ServiceProfile service, bool add)
    {
        IReadOnlyList<DiscoveredServer> snapshot;
        lock (gate)
        {
            if (!running || !browsers.ContainsValue(browser)) return;
            var key = service.FullInstanceName;
            if (add && Convert(service) is { } server) found[key] = server;
            else found.Remove(key);
            snapshot = Merge(found.Values);
        }
        Changed?.Invoke(snapshot);
    }

    /// <summary>One entry per server id (or address when a server announces no id), sorted by name.</summary>
    public static IReadOnlyList<DiscoveredServer> Merge(IEnumerable<DiscoveredServer> servers) =>
        [.. servers
            .GroupBy(server => server.ServerId?.ToString() ?? server.Address.ToString(), StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .OrderBy(server => server.Name, StringComparer.CurrentCultureIgnoreCase)];

    internal static DiscoveredServer? Convert(ServiceProfile service)
    {
        var properties = service.Properties;
        if (properties is null || !properties.TryGetValue("tls", out var tls) || tls != "1") return null;
        var address = service.Addresses
            .OrderBy(candidate => candidate.AddressFamily == AddressFamily.InterNetwork ? 0 : 1)
            .FirstOrDefault(candidate => !IPAddress.IsLoopback(candidate) && !candidate.IsIPv6LinkLocal);
        if (address is null || service.Port == 0) return null;
        var host = address.AddressFamily == AddressFamily.InterNetworkV6 ? "[" + address + "]" : address.ToString();
        if (!Uri.TryCreate($"https://{host}:{service.Port}", UriKind.Absolute, out var uri) || !ServerAddress.IsValid(uri)) return null;
        var name = properties.TryGetValue("name", out var announced) && announced.Length is > 0 and <= 128 ? announced : service.InstanceName;
        Guid? id = properties.TryGetValue("id", out var text) && Guid.TryParse(text, out var parsed) ? parsed : null;
        return new DiscoveredServer(id, name, uri);
    }
}

internal interface IMdnsDiscoveryBrowser : IDisposable
{
    event Action<ServiceProfile>? ServiceFound;
    event Action<ServiceProfile>? ServiceLost;
    void Start();
}

internal sealed class MdnsDiscoveryBrowser(string type) : IMdnsDiscoveryBrowser
{
    private readonly MdnsBrowser browser = new(type);

    public event Action<ServiceProfile>? ServiceFound
    {
        add => browser.ServiceFound += value;
        remove => browser.ServiceFound -= value;
    }

    public event Action<ServiceProfile>? ServiceLost
    {
        add => browser.ServiceLost += value;
        remove => browser.ServiceLost -= value;
    }

    public void Start() => browser.Start();
    public void Dispose() => browser.Dispose();
}
