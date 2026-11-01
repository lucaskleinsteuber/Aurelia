using System.Net;
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
    private readonly List<MdnsBrowser> browsers = [];

    public event Action<IReadOnlyList<DiscoveredServer>>? Changed;

    public void Start()
    {
        lock (gate)
        {
            if (browsers.Count > 0) return;
            foreach (var type in ServiceTypes)
            {
                try
                {
                    var browser = new MdnsBrowser(type);
                    browser.ServiceFound += service => Update(service, add: true);
                    browser.ServiceLost += service => Update(service, add: false);
                    browser.Start();
                    browsers.Add(browser);
                }
                catch (SocketException)
                {
                    // Without multicast the address can still be typed in.
                }
            }
        }
    }

    public void Halt()
    {
        lock (gate)
        {
            foreach (var browser in browsers) browser.Dispose();
            browsers.Clear();
            found.Clear();
        }
        Changed?.Invoke([]);
    }

    public void Dispose() => Halt();

    private void Update(ServiceProfile service, bool add)
    {
        IReadOnlyList<DiscoveredServer> snapshot;
        lock (gate)
        {
            if (browsers.Count == 0) return;
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
