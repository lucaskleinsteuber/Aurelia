namespace Aurelia.Server.Services;

/// <summary>
/// Limits guessing of the 8-digit pairing code. The request limits count per address, and a
/// device in the home network can use thousands of addresses, so wrong guesses are also counted
/// together: after <see cref="MaximumFailures"/> of them, whoever sent them, the waiting codes
/// end and the owner creates a new one. One address alone cannot reach that number within a
/// code's five minutes.
/// </summary>
public sealed class PairingCodeAttemptGuard
{
    public const int MaximumFailures = 100;
    private int failures;

    /// <summary>A new code starts with no wrong guesses.</summary>
    public void CodeCreated() => Interlocked.Exchange(ref failures, 0);

    /// <summary>Counts a wrong guess; true when the waiting codes must end now.</summary>
    public bool RecordFailure()
    {
        if (Interlocked.Increment(ref failures) < MaximumFailures) return false;
        Interlocked.Exchange(ref failures, 0);
        return true;
    }
}
