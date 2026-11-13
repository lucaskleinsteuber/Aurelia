namespace Aurelia.Contracts;

// Security log, signed-in devices, the block list and Face ID / Touch ID for management
// ("security-v1", docs/SECURITY_MODEL.md). Only the owner reads the log and manages devices.

/// <summary>
/// One entry of the security log. <c>Kind</c> is a fixed code (such as <c>signed_in</c>,
/// <c>wrong_password</c> or <c>library_removed</c>); <c>Outcome</c> is <c>succeeded</c>,
/// <c>failed</c> or <c>changed</c>; <c>Detail</c> is a short name (a profile, a storage location's
/// folder name or a device), never a password, PIN, token or full path.
/// </summary>
public sealed record SecurityEventSummary(
    Guid Id,
    DateTimeOffset At,
    string Kind,
    string Outcome,
    Guid? UserId,
    string? UserName,
    Guid? DeviceSessionId,
    string? DeviceName,
    string? Platform,
    string? IpAddress,
    string? Detail);

/// <summary>A page of the log, newest first; pass <c>Before</c> to read further back.</summary>
public sealed record SecurityEventPage(IReadOnlyList<SecurityEventSummary> Events, DateTimeOffset? Before);

/// <summary>A signed-in device. <c>IsNew</c> until the owner confirms it ("That was me").</summary>
public sealed record SecurityDeviceSummary(
    Guid Id,
    Guid UserId,
    string UserName,
    string DeviceName,
    string? Platform,
    string? ClientVersion,
    string? IpAddress,
    DateTimeOffset CreatedAt,
    DateTimeOffset LastSeenAt,
    bool IsNew,
    bool CanBlock,
    bool IsCurrent);

public sealed record BlockedDeviceSummary(
    Guid Id,
    string DeviceName,
    string? Platform,
    string? IpAddress,
    DateTimeOffset BlockedAt);

/// <summary>How long the log is kept, and whether owners and administrators must use Face ID or Touch ID.</summary>
public sealed record SecuritySettingsResponse(int SecurityLogDays, bool RequirePasskeysForAdministrators, int PasskeyCount);

public sealed record UpdateSecuritySettingsRequest(int SecurityLogDays, bool RequirePasskeysForAdministrators);

/// <summary>
/// What the owner should see now: devices not confirmed yet and requests to confirm a
/// management unlock on this device. <c>Version</c> changes whenever either list changes.
/// </summary>
public sealed record SecurityAlertsResponse(
    long Version,
    IReadOnlyList<SecurityDeviceSummary> NewDevices,
    IReadOnlyList<RemoteUnlockRequestSummary> UnlockRequests);

/// <summary>A one-time challenge, valid for a minute, for the profile that asked for it.</summary>
public sealed record PasskeyChallengeResponse(string Challenge, DateTimeOffset ExpiresAt);

/// <summary>
/// A Face ID or Touch ID key from this device: <c>PublicKey</c> is the P-256 key as X9.63
/// (65 bytes, base64), and <c>Signature</c> (DER, base64) signs the challenge to prove the device
/// holds the private key.
/// </summary>
public sealed record RegisterPasskeyRequest(string Name, string PublicKey, string Challenge, string Signature);

public sealed record PasskeySummary(
    Guid Id,
    Guid UserId,
    string UserName,
    string Name,
    DateTimeOffset CreatedAt,
    DateTimeOffset? LastUsedAt,
    bool IsThisDevice);

public sealed record PasskeyUnlockRequest(Guid PasskeyId, string Challenge, string Signature);

/// <summary>A device without Face ID asks one with it to confirm a management unlock; both show <c>Code</c>.</summary>
public sealed record RemoteUnlockStartResponse(Guid Id, string Code, DateTimeOffset ExpiresAt);

public sealed record RemoteUnlockRequestSummary(
    Guid Id,
    string ProfileName,
    string DeviceName,
    string? IpAddress,
    string Code,
    DateTimeOffset ExpiresAt);

/// <summary><c>State</c> is <c>pending</c>, <c>approved</c>, <c>denied</c> or <c>expired</c>.</summary>
public sealed record RemoteUnlockStatusResponse(string State, DateTimeOffset ExpiresAt, DateTimeOffset? ManagementExpiresAt);

public sealed record DecideRemoteUnlockRequest(bool Approve, Guid? PasskeyId, string? Challenge, string? Signature);

/// <summary>Whether the device went on the block list; a device that never said who it is can only be signed out.</summary>
public sealed record BlockDeviceResponse(bool Listed, int SignedOut);
