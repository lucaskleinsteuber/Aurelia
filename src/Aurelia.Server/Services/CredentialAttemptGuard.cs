namespace Aurelia.Server.Services;

// Bounded concurrent password work and temporary account lockouts; no password or token is retained.
public sealed class CredentialAttemptGuard : IDisposable
{
    private readonly object gate = new();
    private readonly Dictionary<Guid, (int Failures, DateTimeOffset Since)> attempts = [];
    private readonly SemaphoreSlim work = new(4, 4);
    public void Check(Guid userId, DateTimeOffset now)
    {
        lock (gate)
        {
            foreach (var id in attempts.Where(pair => now - pair.Value.Since > TimeSpan.FromMinutes(5)).Select(pair => pair.Key).ToArray())
                attempts.Remove(id);
            if (attempts.TryGetValue(userId, out var entry) && entry.Failures >= 10)
                throw new AccountException("credential_locked", "Too many password attempts. Try again in five minutes.", 429);
        }
    }
    public async Task<IDisposable> EnterAsync(CancellationToken token)
    {
        if (!await work.WaitAsync(0, token)) throw new AccountException("credential_busy", "Password verification is busy. Try again shortly.", 429);
        return new Slot(work);
    }
    public void Record(Guid id, bool success, DateTimeOffset now)
    {
        lock (gate)
        {
            if (success) attempts.Remove(id);
            else if (attempts.TryGetValue(id, out var entry)) attempts[id] = (entry.Failures + 1, entry.Since);
            else if (attempts.Count < 10_000) attempts[id] = (1, now);
        }
    }
    private sealed class Slot(SemaphoreSlim semaphore) : IDisposable
    {
        public void Dispose() => semaphore.Release();
    }
    public void Dispose() => work.Dispose();
}
