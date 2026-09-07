namespace Aurelia.Home.Contracts;

public enum UserRole
{
    Owner,
    Admin,
    User,
}

public sealed record HealthResponse(
    string Status,
    string Version,
    DateTimeOffset CheckedAt);

public sealed record ServerInfoResponse(
    Guid ServerId,
    string Name,
    string Version,
    bool IsSetup,
    bool LanAccessEnabled,
    int? LanHttpsPort,
    string? PublicKeyFingerprint,
    string? DisplayFingerprint);

public sealed record SetupOwnerRequest(
    string Username,
    string Password,
    string DeviceName);

public sealed record LoginRequest(
    string Username,
    string Password,
    string DeviceName);

public sealed record AuthenticationResponse(
    UserSummary User,
    Guid SessionId,
    string Token,
    DateTimeOffset ExpiresAt);

public sealed record UserSummary(
    Guid Id,
    string Username,
    UserRole Role,
    DateTimeOffset CreatedAt);

public sealed record CreateUserRequest(
    string Username,
    string Password,
    UserRole Role);

public sealed record ChangeUserRoleRequest(UserRole Role);

public sealed record DeviceSessionSummary(
    Guid Id,
    Guid UserId,
    string DeviceName,
    DateTimeOffset CreatedAt,
    DateTimeOffset LastSeenAt,
    DateTimeOffset ExpiresAt,
    DateTimeOffset? RevokedAt,
    bool IsCurrent);

public sealed record CreatePairingCodeRequest;

public sealed record PairingCodeResponse(
    string Code,
    DateTimeOffset ExpiresAt);

public sealed record RedeemPairingCodeRequest(
    string Code,
    string DeviceName);

public sealed record ApiProblem(
    string Code,
    string Message);

public enum LibraryKind
{
    Movies,
    TvShows,
}

public enum LibraryAvailability
{
    Unknown,
    Available,
    Unavailable,
    Error,
}

public enum MediaKind
{
    Movie,
    Series,
    Episode,
    Extra,
    Trailer,
}

public enum MediaAvailability
{
    Available,
    Missing,
}

public enum LibraryScanState
{
    Queued,
    Running,
    Completed,
    Failed,
    Interrupted,
}

public sealed record CreateLibraryRequest(
    string Name,
    string Path,
    LibraryKind Kind);

public sealed record LibrarySummary(
    Guid Id,
    string Name,
    string Path,
    LibraryKind Kind,
    LibraryAvailability Availability,
    DateTimeOffset CreatedAt,
    DateTimeOffset? LastScanStartedAt,
    DateTimeOffset? LastScanCompletedAt,
    string? LastError);

public sealed record LibraryScanIssueSummary(
    string Code,
    string Message,
    string? Path);

public sealed record LibraryScanSummary(
    Guid Id,
    Guid LibraryId,
    LibraryScanState State,
    DateTimeOffset CreatedAt,
    DateTimeOffset? StartedAt,
    DateTimeOffset? CompletedAt,
    int FilesDiscovered,
    int FilesProcessed,
    int AddedFiles,
    int UpdatedFiles,
    int MissingFiles,
    int SkippedFiles,
    string? Error,
    IReadOnlyList<LibraryScanIssueSummary> Issues);

public sealed record PagedResponse<T>(
    IReadOnlyList<T> Items,
    int Offset,
    int Limit,
    int Total);

public sealed record MovieSummary(
    Guid Id,
    string Title,
    int? Year,
    MediaAvailability Availability);

public sealed record MovieDetail(
    Guid Id,
    string Title,
    int? Year,
    MediaAvailability Availability,
    IReadOnlyList<SupplementSummary> Supplements);

public sealed record SeriesSummary(
    Guid Id,
    string Title,
    MediaAvailability Availability,
    int SeasonCount,
    int EpisodeCount);

public sealed record SeriesDetail(
    Guid Id,
    string Title,
    MediaAvailability Availability,
    IReadOnlyList<SeasonSummary> Seasons,
    IReadOnlyList<SupplementSummary> Supplements);

public sealed record SeasonSummary(
    int Number,
    IReadOnlyList<EpisodeSummary> Episodes,
    IReadOnlyList<SupplementSummary> Supplements);

public sealed record EpisodeSummary(
    Guid Id,
    string Title,
    int SeasonNumber,
    int EpisodeNumber,
    MediaAvailability Availability);

public sealed record SupplementSummary(
    Guid Id,
    string Title,
    MediaKind Kind,
    string Category,
    int? SeasonNumber,
    MediaAvailability Availability);

public sealed record PlaybackSourceResponse(
    Guid Id,
    Guid MediaId,
    string StreamPath,
    string ContentType,
    long ContentLength,
    DateTimeOffset ExpiresAt,
    PlaybackProgressResponse Progress);

public sealed record UpdatePlaybackProgressRequest(
    long PositionMilliseconds,
    long DurationMilliseconds,
    bool IsFinished);

public sealed record PlaybackProgressResponse(
    Guid MediaId,
    long PositionMilliseconds,
    long DurationMilliseconds,
    bool IsCompleted,
    DateTimeOffset? LastPlayedAt,
    DateTimeOffset? UpdatedAt);
