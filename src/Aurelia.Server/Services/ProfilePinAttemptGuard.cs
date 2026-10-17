namespace Aurelia.Server.Services;

/// <summary>
/// Limits PIN guessing per profile. Failures count across all paired devices, so more devices
/// do not mean more guesses, and every further five failures lock the profile longer:
/// one minute, five minutes, thirty minutes, then two hours each. A correct PIN, or a day
/// without failures, starts over.
/// </summary>
public sealed class ProfilePinAttemptGuard(TimeProvider clock)
{
    public const int FailuresPerLock = 5;
    private static readonly TimeSpan Forget = TimeSpan.FromHours(24);
    private readonly object gate = new();
    private readonly Dictionary<Guid, (int Failures, DateTimeOffset LockedUntil, DateTimeOffset LastFailure)> attempts = [];

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
        _ = device;
        lock (gate)
        {
            var now = clock.GetUtcNow();
            Prune(now);
            if (attempts.TryGetValue(user, out var value) && value.LockedUntil > now)
            {
                var minutes = Math.Max(1, (int)Math.Ceiling((value.LockedUntil - now).TotalMinutes));
                throw new AccountException("profile_pin_locked",
                    $"Too many PIN attempts. Try again in {minutes} minute{(minutes == 1 ? "" : "s")}.", 429);
            }
            if (attempts.Count >= 10000 && !attempts.ContainsKey(user))
                throw new AccountException("profile_pin_busy", "PIN verification is busy. Try again shortly.", 429);
        }
    }

    public void Record(Guid device, Guid user, bool success)
    {
        _ = device;
        lock (gate)
        {
            var now = clock.GetUtcNow();
            Prune(now);
            if (success)
            {
                attempts.Remove(user);
                return;
            }
            var failures = (attempts.TryGetValue(user, out var value) ? value.Failures : 0) + 1;
            var lockedUntil = failures % FailuresPerLock == 0 ? now + LockDuration(failures) : value.LockedUntil;
            attempts[user] = (failures, lockedUntil, now);
        }
    }

    private void Prune(DateTimeOffset now)
    {
        foreach (var key in attempts.Where(pair => pair.Value.LockedUntil <= now && now - pair.Value.LastFailure >= Forget)
                     .Select(pair => pair.Key).ToArray())
            attempts.Remove(key);
    }
}
