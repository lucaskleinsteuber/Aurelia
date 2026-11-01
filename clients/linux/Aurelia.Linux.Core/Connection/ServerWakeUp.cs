using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Connection;

/// <summary>What the start screen says while Aurelia reaches its server.</summary>
public enum ConnectionStatus
{
    Idle,
    Connecting,
    Waking,
    Loading,
}

/// <summary>
/// Reaches a saved server, waking it when it sleeps, like the Mac app: a quick check first; when
/// the server does not answer and its Wake-on-LAN addresses are known, a magic packet every 10
/// seconds while checking every 2 seconds, for up to two minutes; otherwise waiting up to 20
/// seconds. A server that answers at another address it announces on the network is accepted
/// only with the same id and key, and that address is remembered.
/// </summary>
/// <summary>A server that answered, with what it reported about itself.</summary>
public sealed record ReachedServer(StoredServer Server, Aurelia.Contracts.ServerInfoResponse Info);

public sealed class ServerWakeUp(AureliaApi api, IWakeOnLan wakeOnLan, Func<IReadOnlyList<DiscoveredServer>> discovered, TimeProvider time)
{
    public static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(3);
    public static readonly TimeSpan WakeInterval = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan WakeLimit = TimeSpan.FromSeconds(120);
    public static readonly TimeSpan WaitLimit = TimeSpan.FromSeconds(20);

    /// <summary>Returns the server as reached (possibly at a new address), or null when it stayed silent.</summary>
    public async Task<ReachedServer?> ReachAsync(StoredServer server, Action<ConnectionStatus> report, CancellationToken cancellation)
    {
        report(ConnectionStatus.Connecting);
        if (await ProbeAsync(server, cancellation) is { } reached) return reached;
        var addresses = server.WakeOnLanAddresses ?? [];
        var limit = addresses.Count > 0 ? WakeLimit : WaitLimit;
        if (addresses.Count > 0) report(ConnectionStatus.Waking);
        var started = time.GetUtcNow();
        var lastWake = DateTimeOffset.MinValue;
        while (time.GetUtcNow() - started < limit)
        {
            cancellation.ThrowIfCancellationRequested();
            if (addresses.Count > 0 && time.GetUtcNow() - lastWake >= WakeInterval)
            {
                lastWake = time.GetUtcNow();
                await wakeOnLan.SendAsync(addresses, server.Address.Host, cancellation);
            }
            await Task.Delay(PollInterval, time, cancellation);
            if (await ProbeAsync(server, cancellation) is { } awake) return awake;
        }
        return null;
    }

    private async Task<ReachedServer?> ProbeAsync(StoredServer server, CancellationToken cancellation)
    {
        var candidates = new List<Uri> { server.Address };
        candidates.AddRange(discovered().Where(found => found.ServerId == server.ServerId && found.Address != server.Address)
            .Select(found => found.Address).Take(16));
        foreach (var address in candidates)
        {
            try
            {
                var at = server with { Address = address };
                var info = await api.ServerInfoAsync(at, cancellation, ProbeTimeout);
                return new ReachedServer(at with { WakeOnLanAddresses = info.WakeOnLanAddresses is { Count: > 0 } known ? known : server.WakeOnLanAddresses }, info);
            }
            catch (AureliaApiException error) when (error.IsUnreachable)
            {
            }
        }
        return null;
    }
}
