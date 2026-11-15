namespace Aurelia.Server.Services;

/// <summary>
/// Limits guessing of the 8-digit pairing code. Each address (an IPv6 address by its /64 network,
/// so one device's many addresses count once) may guess wrong <see cref="FailuresPerAddress"/>
/// times per waiting code; then it is refused until the owner creates a new code, and the codes
/// stay valid for everyone else (audit S-L6: before, any device at home could end every pairing
/// with 100 wrong guesses). Wrong guesses from many networks together still end the waiting codes
/// after <see cref="MaximumFailures"/>.
/// </summary>
public sealed class PairingCodeAttemptGuard
{
    public const int MaximumFailures = 100;
    public const int FailuresPerAddress = 20;
    private readonly object gate = new();
    private readonly Dictionary<string, int> perAddress = [];
    private int failures;

    /// <summary>A new code starts with no wrong guesses.</summary>
    public void CodeCreated()
    {
        lock (gate)
        {
            failures = 0;
            perAddress.Clear();
        }
    }

    /// <summary>Whether this address guessed wrong too often for the waiting codes.</summary>
    public bool IsRefused(System.Net.IPAddress? address)
    {
        lock (gate) return perAddress.TryGetValue(ServerRequestGuard.AddressKey(address), out var count) && count >= FailuresPerAddress;
    }

    /// <summary>Counts a wrong guess; true when the waiting codes must end now.</summary>
    public bool RecordFailure(System.Net.IPAddress? address = null)
    {
        lock (gate)
        {
            var key = ServerRequestGuard.AddressKey(address);
            if (perAddress.Count < 10_000 || perAddress.ContainsKey(key))
                perAddress[key] = perAddress.GetValueOrDefault(key) + 1;
            if (++failures < MaximumFailures) return false;
            failures = 0;
            perAddress.Clear();
            return true;
        }
    }
}
