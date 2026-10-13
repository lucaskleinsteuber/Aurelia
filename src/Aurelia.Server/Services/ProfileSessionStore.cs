namespace Aurelia.Server.Services;

/// Viewing and administrative unlocks are volatile; only paired devices survive restarts.
public sealed class ProfileSessionStore(TimeProvider clock, TokenService tokens, ActiveStreamRegistry streams) : IDisposable
{
    public sealed record Session(Guid Id, Guid DeviceId, Guid UserId, DateTimeOffset ExpiresAt);
    public sealed record ManagementGrant(Guid Generation, DateTimeOffset ExpiresAt);
    private sealed record Entry(Session Session, Guid ManagementEpoch, ManagementGrant? Management);
    private readonly object gate = new();
    private readonly Dictionary<string, Entry> sessions = [];
    private ITimer? expiryTimer;

    public (Session Session, string Token) Issue(Guid deviceId, Guid userId)
    {
        lock (gate)
        {
            Prune();
            expiryTimer ??= clock.CreateTimer(_ => { lock (gate) { Prune(); ScheduleExpiry(); } }, null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
            if (sessions.Count >= 10000) throw new AccountException("profile_session_limit", "Too many active profile sessions.", 429);
            // One profile per device. Switching also cancels its prior streams.
            Retire(entry => entry.Session.DeviceId == deviceId);
            var token = tokens.CreateDeviceToken();
            var session = new Session(Guid.NewGuid(), deviceId, userId, clock.GetUtcNow().AddHours(12));
            sessions.Add(tokens.Hash(token), new Entry(session, Guid.NewGuid(), null));
            ScheduleExpiry();
            return (session, token);
        }
    }

    public Session? Find(string tokenHash)
    {
        lock (gate) { Prune(); return sessions.GetValueOrDefault(tokenHash)?.Session; }
    }

    public bool IsActive(Guid sessionId, Guid deviceId, Guid userId)
    {
        lock (gate) { Prune(); return sessions.Values.Any(entry => entry.Session.Id == sessionId && entry.Session.DeviceId == deviceId && entry.Session.UserId == userId); }
    }

    public Guid ManagementEpoch(Guid id)
    {
        lock (gate)
        {
            Prune();
            return sessions.Values.FirstOrDefault(entry => entry.Session.Id == id)?.ManagementEpoch
                ?? throw new AccountException("profile_session_expired", "Unlock your profile again.", 401);
        }
    }

    public DateTimeOffset UnlockManagement(Guid id, Guid? expectedEpoch = null)
    {
        lock (gate)
        {
            Prune();
            var key = sessions.FirstOrDefault(pair => pair.Value.Session.Id == id).Key;
            if (key is null) throw new AccountException("profile_session_expired", "Unlock your profile again.", 401);
            if (expectedEpoch is { } epoch && sessions[key].ManagementEpoch != epoch)
                throw new AccountException("management_unlock_superseded", "The management state changed. Unlock management again if needed.", 409);
            var expiry = clock.GetUtcNow().AddMinutes(10);
            if (expiry > sessions[key].Session.ExpiresAt) expiry = sessions[key].Session.ExpiresAt;
            var generation = Guid.NewGuid();
            sessions[key] = sessions[key] with { ManagementEpoch = generation, Management = new(generation, expiry) };
            return expiry;
        }
    }

    public bool ManagementUnlocked(Guid id)
    {
        return CurrentManagementGrant(id) is not null;
    }

    public ManagementGrant? CurrentManagementGrant(Guid id)
    {
        lock (gate)
        {
            Prune();
            var grant = sessions.Values.FirstOrDefault(entry => entry.Session.Id == id)?.Management;
            return grant?.ExpiresAt > clock.GetUtcNow() ? grant : null;
        }
    }

    public bool ManagementGrantActive(Guid id, Guid generation)
    {
        return CurrentManagementGrant(id)?.Generation == generation;
    }

    public void LockManagement(Guid id)
    {
        lock (gate)
        {
            var key = sessions.FirstOrDefault(pair => pair.Value.Session.Id == id).Key;
            if (key is not null) sessions[key] = sessions[key] with { ManagementEpoch = Guid.NewGuid(), Management = null };
        }
    }

    public void End(Guid id) { lock (gate) Retire(entry => entry.Session.Id == id); }
    public void RevokeDevice(Guid id) { lock (gate) Retire(entry => entry.Session.DeviceId == id); }
    public void RevokeUser(Guid id) { lock (gate) Retire(entry => entry.Session.UserId == id); }
    public void Dispose()
    {
        lock (gate)
        {
            expiryTimer?.Dispose();
            expiryTimer = null;
            Retire(_ => true);
        }
    }

    private void Prune() => Retire(entry => entry.Session.ExpiresAt <= clock.GetUtcNow());
    private void ScheduleExpiry()
    {
        if (expiryTimer is null) return;
        var delay = sessions.Count == 0 ? Timeout.InfiniteTimeSpan : sessions.Values.Min(entry => entry.Session.ExpiresAt) - clock.GetUtcNow();
        expiryTimer.Change(delay < TimeSpan.Zero && delay != Timeout.InfiniteTimeSpan ? TimeSpan.Zero : delay, Timeout.InfiniteTimeSpan);
    }
    private void Retire(Func<Entry, bool> predicate)
    {
        var changed = false;
        foreach (var key in sessions.Where(pair => predicate(pair.Value)).Select(pair => pair.Key).ToArray())
        {
            var id = sessions[key].Session.Id;
            sessions.Remove(key);
            streams.RevokeSession(id);
            changed = true;
        }
        if (changed) ScheduleExpiry();
    }
}
