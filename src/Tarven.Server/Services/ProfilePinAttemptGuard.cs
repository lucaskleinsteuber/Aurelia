namespace Tarven.Server.Services;

/// <summary>
/// Limits PIN guessing. Each paired device's failures for a profile count on their own, and every
/// further five lock that device out of the profile longer: one minute, five minutes, thirty
/// minutes, then two hours each. So one device guessing wrong cannot lock the owner out on every
/// other device (audit S-L1). Many devices together still meet a limit: every twenty failures for a
/// profile across all devices lock it everywhere, with the same steps. A correct PIN, a new PIN, or
/// a day without failures starts over.
/// </summary>
public sealed class ProfilePinAttemptGuard(TimeProvider clock)
{
    public const int FailuresPerLock = 5;
    public const int ProfileFailuresPerLock = 20;
    private static readonly TimeSpan Forget = TimeSpan.FromHours(24);
    private readonly object gate = new();
    private readonly Dictionary<(Guid Device, Guid User), Counter> devices = [];
    private readonly Dictionary<Guid, Counter> profiles = [];

    private readonly record struct Counter(int Failures, DateTimeOffset LockedUntil, DateTimeOffset LastFailure);

    public static TimeSpan LockDuration(int failures) => (failures / FailuresPerLock) switch
    {
        <= 0 => TimeSpan.Zero,
        1 => TimeSpan.FromMinutes(1),
        2 => TimeSpan.FromMinutes(5),
        3 => TimeSpan.FromMinutes(30),
        _ => TimeSpan.FromHours(2),
    };

    public void Check(Guid device, Guid user)
    {
        lock (gate)
        {
            var now = clock.GetUtcNow();
            Prune(now);
            var until = Max(devices.TryGetValue((device, user), out var mine) ? mine.LockedUntil : default,
                profiles.TryGetValue(user, out var all) ? all.LockedUntil : default);
            if (until > now)
            {
                var minutes = Math.Max(1, (int)Math.Ceiling((until - now).TotalMinutes));
                throw new AccountException("profile_pin_locked",
                    $"Too many PIN attempts. Try again in {minutes} minute{(minutes == 1 ? "" : "s")}.", 429);
            }
            if (devices.Count >= 10000 && !devices.ContainsKey((device, user)))
                throw new AccountException("profile_pin_busy", "PIN verification is busy. Try again shortly.", 429);
        }
    }

    public void Record(Guid device, Guid user, bool success)
    {
        lock (gate)
        {
            var now = clock.GetUtcNow();
            Prune(now);
            if (success)
            {
                // Only this device starts over: another device's guessing stays locked.
                devices.Remove((device, user));
                profiles.Remove(user);
                return;
            }
            var mine = devices.TryGetValue((device, user), out var value) ? value : default;
            var failures = mine.Failures + 1;
            devices[(device, user)] = new(failures, failures % FailuresPerLock == 0 ? now + LockDuration(failures) : mine.LockedUntil, now);
            var all = profiles.TryGetValue(user, out var total) ? total : default;
            var allFailures = all.Failures + 1;
            // Twenty failures across devices count like five on one device, forty like ten, and so on.
            profiles[user] = new(allFailures, allFailures % ProfileFailuresPerLock == 0
                ? now + LockDuration(allFailures / (ProfileFailuresPerLock / FailuresPerLock)) : all.LockedUntil, now);
        }
    }

    /// <summary>A new PIN ends every lock of the profile: the guesses were for the old one.</summary>
    public void Reset(Guid user)
    {
        lock (gate) ForgetUser(user);
    }

    private void ForgetUser(Guid user)
    {
        profiles.Remove(user);
        foreach (var key in devices.Keys.Where(key => key.User == user).ToArray()) devices.Remove(key);
    }

    private static DateTimeOffset Max(DateTimeOffset first, DateTimeOffset second) => first > second ? first : second;

    private void Prune(DateTimeOffset now)
    {
        foreach (var key in devices.Where(pair => pair.Value.LockedUntil <= now && now - pair.Value.LastFailure >= Forget)
                     .Select(pair => pair.Key).ToArray())
            devices.Remove(key);
        foreach (var key in profiles.Where(pair => pair.Value.LockedUntil <= now && now - pair.Value.LastFailure >= Forget)
                     .Select(pair => pair.Key).ToArray())
            profiles.Remove(key);
    }
}
