namespace Aurelia.Server.Services;

// Public requests have separate budgets so polling cannot exhaust the start or
// owner code-lookup allowance. Neither codes nor credentials enter limiter keys.
public sealed class DeviceAuthorizationGuard(TimeProvider clock) : IDisposable
{
    private readonly object gate = new();
    private readonly Dictionary<(string Operation, string Actor), (int Count, DateTimeOffset Start)> windows = [];
    private readonly Dictionary<string, List<(Guid Id, DateTimeOffset ExpiresAt)>> pendingByAddress = [];
    private readonly SemaphoreSlim mutations = new(1, 1);
    public const int MaxPendingPerAddress = 20;

    public void ReservePending(string actor, Guid id, DateTimeOffset expiresAt)
    {
        var now = clock.GetUtcNow();
        lock (gate)
        {
            if (pendingByAddress.Count >= 4096)
            {
                foreach (var key in pendingByAddress.Keys.ToArray())
                {
                    pendingByAddress[key].RemoveAll(entry => entry.ExpiresAt <= now);
                    if (pendingByAddress[key].Count == 0) pendingByAddress.Remove(key);
                }
            }
            if (!pendingByAddress.TryGetValue(actor, out var entries))
            {
                entries = [];
                pendingByAddress[actor] = entries;
            }
            entries.RemoveAll(entry => entry.ExpiresAt <= now);
            if (entries.Count >= MaxPendingPerAddress)
                throw new AccountException("device_pairing_limit", "Too many pending device pairings from this network. Try again shortly.", 429);
            entries.Add((id, expiresAt));
        }
    }

    public void ReleasePending(Guid id)
    {
        lock (gate)
        {
            foreach (var key in pendingByAddress.Keys.ToArray())
            {
                var entries = pendingByAddress[key];
                entries.RemoveAll(entry => entry.Id == id);
                if (entries.Count == 0) pendingByAddress.Remove(key);
            }
        }
    }

    public void Admit(string operation, string actor)
    {
        var maximum = operation switch { "start" => 5, "lookup" => 10, _ => 60 };
        var now = clock.GetUtcNow();
        lock (gate)
        {
            if (windows.Count >= 4096)
                foreach (var stale in windows.Where(pair => now - pair.Value.Start >= TimeSpan.FromMinutes(1)).Select(pair => pair.Key).ToArray())
                    windows.Remove(stale);
            var key = (operation, actor);
            if (windows.TryGetValue(key, out var entry) && now - entry.Start < TimeSpan.FromMinutes(1))
            {
                if (entry.Count >= maximum) throw Limited();
                windows[key] = (entry.Count + 1, entry.Start);
            }
            else
            {
                if (windows.Count >= 4096) throw Limited();
                windows[key] = (1, now);
            }
        }
    }

    public async Task<IDisposable> EnterAsync(CancellationToken token)
    {
        await mutations.WaitAsync(token);
        return new Lease(mutations);
    }

    public void Dispose() => mutations.Dispose();

    private static AccountException Limited() => new("device_pairing_rate_limited", "Too many device pairing requests. Try again shortly.", 429);

    private sealed class Lease(SemaphoreSlim semaphore) : IDisposable
    {
        private bool disposed;
        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            semaphore.Release();
        }
    }
}
