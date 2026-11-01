namespace Aurelia.Linux.Core.Connection;

/// <summary>Keeps the latest list of servers announced nearby, so a saved server that moved to another address can still be reached.</summary>
public sealed class DiscoveryCache : IDisposable
{
    private readonly IServerDiscovery discovery;
    private IReadOnlyList<DiscoveredServer> latest = [];

    public DiscoveryCache(IServerDiscovery discovery)
    {
        this.discovery = discovery;
        discovery.Changed += servers => Volatile.Write(ref latest, servers);
        discovery.Start();
    }

    public IReadOnlyList<DiscoveredServer> Latest => Volatile.Read(ref latest);

    public void Dispose() => discovery.Dispose();
}
