using System.Net;
using System.Net.Sockets;
using Haukcode.Mdns;

namespace Aurelia.Desktop.Core;

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
    public event Action<IReadOnlyList<DiscoveredServer>>? Changed { add { } remove { } }
    public void Start() { }
    public void Halt() { }
    public void Dispose() { }
}

/// <summary>Browses for "_aurelia._tcp", the service every Aurelia server announces.</summary>
public sealed class MdnsServerDiscovery : IServerDiscovery
{
    public const string ServiceType = "_aurelia._tcp";
    private readonly Lock gate = new();
    private readonly Dictionary<string, DiscoveredServer> found = new(StringComparer.OrdinalIgnoreCase);
    private MdnsBrowser? browser;

    public event Action<IReadOnlyList<DiscoveredServer>>? Changed;

    public void Start()
    {
        lock (gate)
        {
            if (browser is not null) return;
            try
            {
                var started = new MdnsBrowser(ServiceType);
                started.ServiceFound += service => Update(service, add: true);
                started.ServiceLost += service => Update(service, add: false);
                started.Start();
                browser = started;
            }
            catch (SocketException)
            {
                // Without multicast the address can still be typed in.
            }
        }
    }

    public void Halt()
    {
        lock (gate)
        {
            browser?.Dispose();
            browser = null;
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
            if (browser is null) return;
            if (add && Convert(service) is { } server) found[service.InstanceName] = server;
            else found.Remove(service.InstanceName);
            snapshot = [.. found.Values.OrderBy(server => server.Name, StringComparer.CurrentCultureIgnoreCase)];
        }
        Changed?.Invoke(snapshot);
    }

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
