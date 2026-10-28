namespace Aurelia.Contracts;

public sealed record UserAccessSummary(UserSummary User, bool IsEnabled, IReadOnlyList<Guid> LibraryIds);
public sealed record UpdateUserAccessRequest(bool IsEnabled, IReadOnlyList<Guid> LibraryIds);
public sealed record ResetUserPasswordRequest(string Password);
// Password is accepted only for wire compatibility. Authorization comes from the active management grant.
public sealed record AdministrationApprovalRequest(string Action, string PayloadHash, string? Password = null);
public sealed record AdministrationApprovalResponse(string Token, DateTimeOffset ExpiresAt);

/// <summary>
/// What a Linux server installed from the package does when nobody uses it: Mode is "off" (keeps
/// running), "stop" (stops only Aurelia Server, which starts again when a device connects) or
/// "sleep" (the computer sleeps until Wake-on-LAN). Available is false where the operating system
/// cannot act on it; times are 24-hour HH:MM and both empty when there are no awake hours.
/// </summary>
public sealed record ServerPowerSettings(bool Available, string Mode, int IdleMinutes, string? AwakeFrom, string? AwakeUntil);
public sealed record UpdateServerPowerSettingsRequest(string Mode, int IdleMinutes, string? AwakeFrom, string? AwakeUntil);

/// <summary>
/// Optional timeline scrub-preview settings and status. Small JPEG stills are kept in memory when
/// Mode is "off", or stored as bounded strips in the server's data folder when Mode is
/// "onOpenOrPlay" or "afterImport". Converted video is never stored.
/// </summary>
public sealed record ScrubPreviewSettingsResponse(
    bool Available,
    string Mode,
    int IntervalSeconds,
    int StorageCapMegabytes,
    int StoredTitleCount,
    long StoredBytes,
    int ActiveCount,
    int PendingCount,
    int CompletedCount,
    int TotalScheduledCount,
    bool PausedForPlayback);

public sealed record UpdateScrubPreviewSettingsRequest(
    string Mode,
    int IntervalSeconds,
    int StorageCapMegabytes);

public sealed record ScrubPreviewManifestResponse(
    bool Available,
    string Mode,
    int IntervalSeconds,
    int DurationSeconds,
    IReadOnlyList<int> ReadySeconds,
    string Revision);
