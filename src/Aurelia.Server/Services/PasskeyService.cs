using System.Security.Cryptography;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Face ID and Touch ID for server management. A Mac, iPhone or iPad makes a P-256 key in its
/// Secure Enclave, protected by Face ID or Touch ID; the server keeps only the public key and
/// checks signatures over one-time challenges with <see cref="ECDsa"/>. A device without Face ID
/// (Linux, a browser) can ask one with it to confirm an unlock; both show the same four digits.
/// Challenges and unlock requests live in memory only.
/// </summary>
public sealed class PasskeyService(TimeProvider clock, SecurityAlertSignal alerts)
{
    public static readonly TimeSpan ChallengeLifetime = TimeSpan.FromMinutes(1);
    public static readonly TimeSpan RemoteUnlockLifetime = TimeSpan.FromMinutes(2);
    public const int MaximumPasskeysPerProfile = 10;
    private readonly object gate = new();
    private readonly Dictionary<string, Challenge> challenges = [];
    private readonly Dictionary<Guid, RemoteUnlock> remoteUnlocks = [];

    private sealed record Challenge(Guid ProfileSessionId, DateTimeOffset ExpiresAt);

    internal sealed record RemoteUnlock(
        Guid Id, Guid ProfileSessionId, Guid UserId, Guid DeviceSessionId, string ProfileName, string DeviceName,
        string? IpAddress, string Code, DateTimeOffset ExpiresAt, string State, Guid? ApprovedBy, bool Granted);

    /// <summary>The words a device signs: what for and which challenge, so a signature fits nothing else.</summary>
    public static byte[] Message(string purpose, string challenge) => Encoding.UTF8.GetBytes($"aurelia-passkey-v1|{purpose}|{challenge}");

    public PasskeyChallengeResponse CreateChallenge(Guid profileSessionId)
    {
        var challenge = Base64Url(RandomNumberGenerator.GetBytes(32));
        var expires = clock.GetUtcNow() + ChallengeLifetime;
        lock (gate)
        {
            Prune();
            if (challenges.Count >= 4096) throw new AccountException("passkey_busy", "Too many sign-in attempts. Try again shortly.", 429);
            challenges[challenge] = new Challenge(profileSessionId, expires);
        }
        return new PasskeyChallengeResponse(challenge, expires);
    }

    /// <summary>Uses up a challenge of this profile session; false when unknown, expired or someone else's.</summary>
    private bool Consume(string? challenge, Guid profileSessionId)
    {
        if (string.IsNullOrEmpty(challenge)) return false;
        lock (gate)
        {
            Prune();
            if (!challenges.Remove(challenge, out var entry)) return false;
            return entry.ProfileSessionId == profileSessionId && entry.ExpiresAt > clock.GetUtcNow();
        }
    }

    /// <summary>A P-256 public key from X9.63 (0x04 ‖ X ‖ Y, 65 bytes), or null when it isn't one.</summary>
    public static ECDsa? PublicKey(byte[] raw)
    {
        if (raw.Length != 65 || raw[0] != 0x04) return null;
        try
        {
            var key = ECDsa.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = raw[1..33], Y = raw[33..65] },
            });
            return key;
        }
        catch (CryptographicException) { return null; }
    }

    public static bool Verify(byte[] publicKey, byte[] message, string? signature)
    {
        if (string.IsNullOrEmpty(signature) || signature.Length > 512) return false;
        byte[] bytes;
        try { bytes = Convert.FromBase64String(signature); }
        catch (FormatException) { return false; }
        using var key = PublicKey(publicKey);
        if (key is null) return false;
        try { return key.VerifyData(message, bytes, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence); }
        catch (CryptographicException) { return false; }
    }

    public async Task<PasskeySummary> RegisterAsync(AureliaDbContext database, Guid userId, Guid deviceSessionId, Guid profileSessionId,
        RegisterPasskeyRequest request, CancellationToken token)
    {
        var name = (request.Name ?? string.Empty).Trim();
        if (name.Length is < 1 or > 128 || name.Any(char.IsControl))
            throw new AccountException("invalid_passkey_name", "Give the key a name with 1 to 128 visible characters.", 400);
        byte[] publicKey;
        try { publicKey = Convert.FromBase64String(request.PublicKey ?? string.Empty); }
        catch (FormatException) { throw Invalid(); }
        if (PublicKey(publicKey) is not { } key) throw Invalid();
        key.Dispose();
        if (!Consume(request.Challenge, profileSessionId) || !Verify(publicKey, Message("register", request.Challenge), request.Signature))
            throw Invalid();
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId && user.IsEnabled, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        if (user.Role is not (UserRole.Owner or UserRole.Admin))
            throw new AccountException("administration_required", "Only the owner and administrators use Face ID or Touch ID here.", 403);
        var device = await database.DeviceSessions.SingleAsync(session => session.Id == deviceSessionId, token);
        if (await database.ManagementPasskeys.CountAsync(passkey => passkey.UserId == userId, token) >= MaximumPasskeysPerProfile)
            throw new AccountException("passkey_limit", "This profile already has ten keys. Remove one first.", 409);
        // One key per profile and device: a new one replaces the old.
        await database.ManagementPasskeys.Where(passkey => passkey.UserId == userId && passkey.DeviceSessionId == deviceSessionId).ExecuteDeleteAsync(token);
        var passkey = new ManagementPasskey
        {
            Id = Guid.NewGuid(),
            UserId = userId,
            User = user,
            DeviceSessionId = deviceSessionId,
            DeviceSession = device,
            Name = name,
            PublicKey = publicKey,
            CreatedAt = clock.GetUtcNow(),
        };
        database.ManagementPasskeys.Add(passkey);
        await database.SaveChangesAsync(token);
        return Summary(passkey, user.DisplayName ?? user.Username, deviceSessionId);
    }

    /// <summary>Checks a signature from this profile's key on this device; returns the key on success.</summary>
    public async Task<ManagementPasskey> VerifyAsync(AureliaDbContext database, Guid userId, Guid deviceSessionId, Guid profileSessionId,
        Guid passkeyId, string? challenge, string? signature, string purpose, CancellationToken token)
    {
        var passkey = await database.ManagementPasskeys.SingleOrDefaultAsync(value => value.Id == passkeyId, token);
        var fresh = Consume(challenge, profileSessionId);
        if (passkey is null || !fresh || passkey.UserId != userId || passkey.DeviceSessionId != deviceSessionId
            || !Verify(passkey.PublicKey, Message(purpose, challenge!), signature))
            throw Invalid();
        passkey.LastUsedAt = clock.GetUtcNow();
        await database.SaveChangesAsync(token);
        return passkey;
    }

    public static PasskeySummary Summary(ManagementPasskey passkey, string userName, Guid currentDevice) =>
        new(passkey.Id, passkey.UserId, userName, passkey.Name, passkey.CreatedAt, passkey.LastUsedAt, passkey.DeviceSessionId == currentDevice);

    public static AccountException Invalid() =>
        new("passkey_invalid", "Face ID or Touch ID could not confirm this. Try again.", 401);

    // Confirming on another device.

    public RemoteUnlockStartResponse StartRemoteUnlock(Guid profileSessionId, Guid userId, Guid deviceSessionId,
        string profileName, string deviceName, string? ipAddress)
    {
        var code = RandomNumberGenerator.GetInt32(0, 10_000).ToString("D4", System.Globalization.CultureInfo.InvariantCulture);
        var request = new RemoteUnlock(Guid.NewGuid(), profileSessionId, userId, deviceSessionId, profileName, deviceName, ipAddress,
            code, clock.GetUtcNow() + RemoteUnlockLifetime, "pending", null, false);
        lock (gate)
        {
            Prune();
            if (remoteUnlocks.Values.Count(value => value.DeviceSessionId == deviceSessionId && value.State == "pending") >= 3)
                throw new AccountException("remote_unlock_limit", "Wait for the earlier request or let it expire.", 429);
            if (remoteUnlocks.Count >= 256) throw new AccountException("remote_unlock_limit", "Too many requests. Try again shortly.", 429);
            remoteUnlocks[request.Id] = request;
        }
        alerts.Bump();
        return new RemoteUnlockStartResponse(request.Id, code, request.ExpiresAt);
    }

    /// <summary>Pending requests a key of <paramref name="userId"/> may confirm: its own, or anyone's for the owner.</summary>
    public IReadOnlyList<RemoteUnlockRequestSummary> PendingFor(Guid userId, bool owner)
    {
        lock (gate)
        {
            Prune();
            var now = clock.GetUtcNow();
            return remoteUnlocks.Values.Where(value => value.State == "pending" && value.ExpiresAt > now && (owner || value.UserId == userId))
                .OrderBy(value => value.ExpiresAt)
                .Select(value => new RemoteUnlockRequestSummary(value.Id, value.ProfileName, value.DeviceName, value.IpAddress, value.Code, value.ExpiresAt))
                .ToArray();
        }
    }

    internal RemoteUnlock? FindRemote(Guid id)
    {
        lock (gate) { Prune(); return remoteUnlocks.GetValueOrDefault(id); }
    }

    public void DecideRemote(Guid id, Guid approverUserId, bool owner, bool approve)
    {
        lock (gate)
        {
            Prune();
            if (!remoteUnlocks.TryGetValue(id, out var request) || request.State != "pending" || request.ExpiresAt <= clock.GetUtcNow())
                throw new AccountException("remote_unlock_not_pending", "This request is no longer waiting.", 409);
            if (!owner && request.UserId != approverUserId)
                throw new AccountException("remote_unlock_forbidden", "Only the owner or the same profile can confirm this.", 403);
            remoteUnlocks[id] = request with { State = approve ? "approved" : "denied", ApprovedBy = approverUserId };
        }
        alerts.Bump();
    }

    /// <summary>The requester's view; grants management to it once, the first time it sees "approved".</summary>
    public (RemoteUnlockStatusResponse Status, bool GrantNow) RemoteStatus(Guid id, Guid profileSessionId)
    {
        lock (gate)
        {
            Prune(keepFinished: true);
            if (!remoteUnlocks.TryGetValue(id, out var request) || request.ProfileSessionId != profileSessionId)
                throw new AccountException("remote_unlock_not_found", "This request was not found.", 404);
            var state = request.State == "pending" && request.ExpiresAt <= clock.GetUtcNow() ? "expired" : request.State;
            var grant = state == "approved" && !request.Granted;
            if (grant) remoteUnlocks[id] = request with { Granted = true };
            return (new RemoteUnlockStatusResponse(state, request.ExpiresAt, null), grant);
        }
    }

    private void Prune(bool keepFinished = false)
    {
        var now = clock.GetUtcNow();
        foreach (var key in challenges.Where(entry => entry.Value.ExpiresAt <= now).Select(entry => entry.Key).ToArray())
            challenges.Remove(key);
        // Finished requests stay a little longer, so the requester can still read the answer.
        foreach (var key in remoteUnlocks.Where(entry => entry.Value.ExpiresAt + TimeSpan.FromMinutes(keepFinished ? 5 : 2) <= now).Select(entry => entry.Key).ToArray())
            remoteUnlocks.Remove(key);
    }

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
