namespace Aurelia.Contracts;

public sealed record ServerLivenessResponse(string Status);
public sealed record ServerReadinessResponse(string State);
public sealed record ServerComponentStatus(string Id, string State, string? Reason = null);
public sealed record ServerReadinessSummary(string State, IReadOnlyList<ServerComponentStatus> Components, DateTimeOffset CheckedAt);
public sealed record ServerRecoveryEvent(DateTimeOffset At, string Code);
public sealed record ServerManagementCapabilities(bool NativeHostOperations, bool EncryptedBackups, bool Transcoding);

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
