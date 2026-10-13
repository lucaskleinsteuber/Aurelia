namespace Aurelia.Server.Services;

public sealed class ProfilePinAttemptGuard(TimeProvider clock)
{
    private readonly object gate = new();
    private readonly Dictionary<(Guid Device, Guid User), (int Failures, DateTimeOffset Until)> attempts = [];
    public void Check(Guid device, Guid user)
    {
        lock (gate)
        {
            Prune();
            if (attempts.TryGetValue((device, user), out var value) && value.Failures >= 5)
                throw new AccountException("profile_pin_locked", "Too many PIN attempts. Wait at least one minute before trying again.", 429);
            if (attempts.Count >= 10000 && !attempts.ContainsKey((device, user)))
                throw new AccountException("profile_pin_busy", "PIN verification is busy. Try again shortly.", 429);
        }
    }
    public void Record(Guid device, Guid user, bool success)
    {
        lock (gate)
        {
            Prune();
            var key = (device, user);
            if (success) attempts.Remove(key);
            else
            {
                var failures = attempts.TryGetValue(key, out var value) ? value.Failures + 1 : 1;
                attempts[key] = (failures, clock.GetUtcNow().AddMinutes(failures >= 5 ? 1 : 5));
            }
        }
    }
    private void Prune()
    {
        foreach (var key in attempts.Where(pair => pair.Value.Until <= clock.GetUtcNow()).Select(pair => pair.Key).ToArray()) attempts.Remove(key);
    }
}
