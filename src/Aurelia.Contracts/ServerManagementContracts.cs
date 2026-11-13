namespace Aurelia.Contracts;

public sealed record UserAccessSummary(UserSummary User, bool IsEnabled, IReadOnlyList<Guid> LibraryIds);
public sealed record UpdateUserAccessRequest(bool IsEnabled, IReadOnlyList<Guid> LibraryIds);
public sealed record ResetUserPasswordRequest(string Password);
// Password is accepted only for wire compatibility. Authorization comes from the active management grant.
public sealed record AdministrationApprovalRequest(string Action, string PayloadHash, string? Password = null);
public sealed record AdministrationApprovalResponse(string Token, DateTimeOffset ExpiresAt);

/// <summary>
/// What a Linux server installed from the package does when nobody uses it: Mode is "off" (keeps
/// running), "stop" (stops only Aurelia Server, which starts again when a device connects),
/// "sleep" (the computer sleeps until Wake-on-LAN) or "shutdown" (the computer turns off until
/// Wake-on-LAN starts it; from server 2.8.0). Available is false where the operating system
/// cannot act on it, such as a server hosted by the Mac or Linux app; times are 24-hour HH:MM and
/// both empty when there are no awake hours. WakeOnAccess: the network card also wakes the
/// computer when a device sends it anything directly, such as a browser opening the address.
/// WakeSupport holds the card's ethtool wake letters ("u" allows WakeOnAccess), empty when unknown.
/// From 2.10.0: Hosting is where the server runs (see ServerInfoResponse.Hosting); a server hosted
/// by the Mac or Linux app offers only "off" and "stop", where "stop" ends the server after the
/// unused minutes until someone opens Aurelia on that computer. AfterSleepTimer: power down five
/// minutes after a player's sleep timer ended (on by default).
/// From 2.16.0, the Wake-on-LAN check of a Linux package server (empty when unknown, on older
/// servers and on servers hosted by an app): Network is how the computer reaches the home network
/// ("wired", "wifi" or "other"); WakeOn is the card's current ethtool wake letters ("g" means a
/// Wake-on-LAN packet wakes it now); SleepKind is the sleep "sleep" mode uses ("deep": suspend to
/// RAM, fans off; "light": only s2idle; "none": the computer can't sleep).
/// </summary>
public sealed record ServerPowerSettings(bool Available, string Mode, int IdleMinutes, string? AwakeFrom, string? AwakeUntil,
    bool WakeOnAccess = false, string WakeSupport = "", string Hosting = "server", bool AfterSleepTimer = true,
    string Network = "", string WakeOn = "", string SleepKind = "");
/// <summary>WakeOnAccess and AfterSleepTimer null keep the stored choice, so clients that don't know them never change them.</summary>
public sealed record UpdateServerPowerSettingsRequest(string Mode, int IdleMinutes, string? AwakeFrom, string? AwakeUntil,
    bool? WakeOnAccess = null, bool? AfterSleepTimer = null);

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
