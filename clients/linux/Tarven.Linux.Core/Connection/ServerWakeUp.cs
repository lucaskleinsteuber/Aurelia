using Tarven.Linux.Core.Api;
using Tarven.Linux.Core.Moving;

namespace Tarven.Linux.Core.Connection;

/// <summary>What the start screen says while Tarven reaches its server.</summary>
public enum ConnectionStatus
{
    Idle,
    Connecting,
    Waking,
    Loading,
}

/// <summary>A server that answered, with what it reported about itself.</summary>
public sealed record ReachedServer(StoredServer Server, Tarven.Contracts.ServerInfoResponse Info);

/// <summary>
/// Reaches a saved server, waking it when it sleeps, like the Mac app: a quick check first; when
/// the server does not answer and its Wake-on-LAN addresses are known, a magic packet every 10
/// seconds while checking every 2 seconds, for up to two minutes; otherwise waiting up to 20
/// seconds. A server that answers at another address it announces on the network, or at an
/// address a moved server names (docs/SERVER_MOVE.md), is accepted only with the same id and key,
/// and that address is remembered with the same sign-in.
/// </summary>
public sealed class ServerWakeUp(TarvenApi api, IWakeOnLan wakeOnLan, Func<IReadOnlyList<DiscoveredServer>> discovered, TimeProvider time)
{
    public static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(3);
    public static readonly TimeSpan WakeInterval = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan WakeLimit = TimeSpan.FromSeconds(120);
    public static readonly TimeSpan WaitLimit = TimeSpan.FromSeconds(20);

    /// <summary>
    /// Returns the server as reached (possibly at a new address), or null when it stayed silent. A
    /// server that moved and could not be followed to the same identity and key ends with an
    /// <see cref="TarvenApiException"/> that says so (code "server_moved" or "moved_identity_mismatch").
    /// </summary>
    public async Task<ReachedServer?> ReachAsync(StoredServer server, Action<ConnectionStatus> report, CancellationToken cancellation)
    {
        report(ConnectionStatus.Connecting);
        var probe = await ProbeAsync(server, cancellation);
        if (probe.Reached is { } reached) return reached;
        if (probe.Moved is { } moved && probe.DifferentKey) throw MovedAway(server, moved, differentKey: true);
        // A server inside Tarven on a desktop or laptop is started by its owner, not woken, and a
        // server that moved answers at its old address already: only its new computer is waited for.
        var addresses = server.HostedByApp || probe.Moved is not null ? [] : server.WakeOnLanAddresses ?? [];
        var limit = addresses.Count > 0 ? WakeLimit : WaitLimit;
        if (addresses.Count > 0) report(ConnectionStatus.Waking);
        var started = time.GetUtcNow();
        var lastWake = DateTimeOffset.MinValue;
        var lastMoved = probe.Moved;
        while (time.GetUtcNow() - started < limit)
        {
            cancellation.ThrowIfCancellationRequested();
            if (addresses.Count > 0 && time.GetUtcNow() - lastWake >= WakeInterval)
            {
                lastWake = time.GetUtcNow();
                await wakeOnLan.SendAsync(addresses, server.Address.Host, cancellation);
            }
            await Task.Delay(PollInterval, time, cancellation);
            probe = await ProbeAsync(server, cancellation);
            if (probe.Reached is { } awake) return awake;
            lastMoved = probe.Moved ?? lastMoved;
            if (lastMoved is not null && probe.DifferentKey) throw MovedAway(server, lastMoved, differentKey: true);
        }
        if (lastMoved is not null) throw MovedAway(server, lastMoved, differentKey: false);
        return null;
    }

    private async Task<(ReachedServer? Reached, MovedServer? Moved, bool DifferentKey)> ProbeAsync(StoredServer server, CancellationToken cancellation)
    {
        var candidates = new List<Uri> { server.Address };
        candidates.AddRange(discovered().Where(found => found.ServerId == server.ServerId && found.Address != server.Address)
            .Select(found => found.Address).Take(16));
        MovedServer? moved = null;
        var differentKey = false;
        // A server that moved still answers at its old address with where it went: those addresses are
        // tried too, and the saved connection switches only to one with the same id and pinned key.
        for (var index = 0; index < candidates.Count && index < 32; index++)
        {
            var address = candidates[index];
            try
            {
                var at = server with { Address = address };
                var answer = await api.ProbeAsync(at, cancellation, ProbeTimeout);
                if (answer.Moved is { } target)
                {
                    moved ??= target;
                    candidates.AddRange(target.Followable(server.ServerId, candidates));
                    continue;
                }
                var info = answer.Info;
                var hosting = info.Hosting ?? server.Hosting;
                var wake = hosting is "macApp" or "linuxApp" ? null
                    : info.WakeOnLanAddresses is { Count: > 0 } known ? known : server.WakeOnLanAddresses;
                return (new ReachedServer(at with { WakeOnLanAddresses = wake, Hosting = hosting, PowerSavingEnabled = info.PowerSavingEnabled }, info), moved, false);
            }
            catch (TarvenApiException error) when (error.IsUnreachable)
            {
            }
            catch (TarvenApiException error) when (index > 0 && error.Code == "identity_mismatch")
            {
                // Never switch to a server with another key: an address announced nearby is skipped,
                // and a moved server that presents another key is reported instead of followed.
                if (moved is not null) differentKey = true;
            }
        }
        return (null, moved, differentKey);
    }

    /// <summary>The saved server moved and could not be followed: a different key, or the new computer is silent.</summary>
    internal static TarvenApiException MovedAway(StoredServer server, MovedServer moved, bool differentKey) =>
        new(409, differentKey ? "moved_identity_mismatch" : "server_moved", ServerMoveText.NotFollowed(moved, differentKey, server.Name))
        {
            MovedTo = moved,
        };
}
