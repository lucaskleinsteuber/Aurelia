namespace Aurelia.Contracts;

public sealed record ServerLivenessResponse(string Status);
public sealed record ServerReadinessResponse(string State);
public sealed record ServerComponentStatus(string Id, string State, string? Reason = null);
public sealed record ServerReadinessSummary(string State, IReadOnlyList<ServerComponentStatus> Components, DateTimeOffset CheckedAt);
public sealed record ServerRecoveryEvent(DateTimeOffset At, string Code);
/// <summary>
/// What a server can do and where it runs. Platform is "macos", "linux", "windows" or "other";
/// LinuxPackage is true for the systemd service installed from the Linux package, which restarts,
/// saves power and updates itself.
/// </summary>
public sealed record ServerManagementCapabilities(bool NativeHostOperations, bool EncryptedBackups, bool Transcoding,
    string Platform = "other", bool LinuxPackage = false);

public sealed record ServerStatusResponse(
    string State,
    string Version,
    double UptimeSeconds,
    int ActiveStreams,
    long DatabaseBytes,
    int Users,
    int Libraries,
    long? FreeDiskBytes,
    DateTime? CertificateExpiresAt,
    IReadOnlyList<string> NetworkAddresses,
    ServerReadinessSummary Readiness,
    IReadOnlyList<ServerRecoveryEvent> RecentRecoveryEvents);

/// <summary>
/// Updates of a Linux server installed from the package. Versions read "1.8.7 (91)". State is
/// "idle", "checking", "installing" or "failed"; Message explains a failure.
/// </summary>
public sealed record ServerUpdateStatus(bool Available, string Installed, string? Newest, bool UpdateAvailable,
    string State, DateTimeOffset? CheckedAt, string? Message);

public sealed record ServerHealthResponse(
    double UptimeSeconds,
    long? FreeDiskBytes,
    long DatabaseBytes,
    int ScrubPreviewTitleCount,
    long ScrubPreviewBytes,
    int ScrubPreviewPendingCount,
    int ActiveLiveConversions,
    int ActiveStreams,
    int OfflineMediaCount,
    ServerHealthScanSummary? LastScan,
    ServerHealthBackgroundJobs BackgroundJobs,
    IReadOnlyList<ServerHealthEvent> RecentIssues,
    ServerHealthBackupSummary? Backup = null);

public sealed record ServerHealthBackupSummary(
    bool Enabled,
    bool LastAttemptFailed,
    DateTimeOffset? LastSucceededAt,
    int TotalBackups,
    long TotalBackupBytes,
    DateTimeOffset? LatestDailyAt,
    DateTimeOffset? LatestWeeklyAt);

public sealed record ServerHealthScanSummary(
    Guid ScanId,
    string State,
    DateTimeOffset StartedAt,
    DateTimeOffset? CompletedAt,
    double? DurationSeconds,
    int AddedFiles,
    int UpdatedFiles,
    int MissingFiles,
    int FailedFiles);

public sealed record ServerHealthBackgroundJobs(
    int ActiveScans,
    int ActiveMetadataJobs,
    int ActiveScrubPreviewJobs);

public sealed record ServerHealthEvent(
    DateTimeOffset At,
    string Code,
    string Severity,
    int? Status);
