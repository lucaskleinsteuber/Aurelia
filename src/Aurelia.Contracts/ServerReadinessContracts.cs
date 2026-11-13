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

/// <summary>
/// What the server measured about itself since <c>Since</c> (at most seven days): how long each
/// endpoint takes and which database queries were slow. Endpoints are route templates such as
/// <c>GET /api/v1/catalog/items/{mediaId:guid}</c>; statements are SQL without values.
/// </summary>
public sealed record ServerPerformanceResponse(
    DateTimeOffset Since,
    int SlowRequestMilliseconds,
    int SlowQueryMilliseconds,
    long Requests,
    double P95Milliseconds,
    IReadOnlyList<ServerEndpointTiming> Endpoints,
    IReadOnlyList<ServerSlowQuery> SlowQueries);

/// <summary>Response times of one endpoint. Percentiles come from fixed buckets, so they are close, not exact.</summary>
public sealed record ServerEndpointTiming(
    string Method,
    string Route,
    long Count,
    long Errors,
    long SlowCount,
    double MedianMilliseconds,
    double P95Milliseconds,
    double MaxMilliseconds,
    double QueriesPerRequest);

/// <summary>
/// One database query that took at least the slow-query threshold. <c>Kind</c> is SELECT,
/// INSERT, UPDATE, DELETE or OTHER; <c>WarmUp</c> marks the first minute after the server started,
/// when the first translation of each query is slow anyway.
/// </summary>
public sealed record ServerSlowQuery(
    DateTimeOffset At,
    double Milliseconds,
    string Kind,
    string Statement,
    string? Endpoint,
    bool WarmUp);
