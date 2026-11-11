namespace Aurelia.Contracts;

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
    string? DisplayFingerprint,
    IReadOnlyList<string>? Capabilities = null,
    // Hardware addresses of the network cards that reach the home network, so a client can wake
    // a sleeping server with Wake-on-LAN. Only reported while network access is on.
    IReadOnlyList<string>? WakeOnLanAddresses = null,
    // From 2.10.0: "macApp" or "linuxApp" when Aurelia for Mac or for Linux hosts the server on a
    // desktop or laptop (no Wake-on-LAN then: when it is off, a device asks to start Aurelia there),
    // "linuxServer" for the Linux package, "server" otherwise.
    string? Hosting = null);

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
    DateTimeOffset CreatedAt,
    ProfileAccessMode AccessMode = ProfileAccessMode.LegacyLibraries,
    bool PinProtectionEnabled = true,
    bool NeedsPinSetup = false,
    long ProfileRevision = 0,
    string? DisplayName = null,
    string? PictureKey = null,
    long PictureRevision = 0,
    int? AgeLimit = null);

public sealed record CreateUserRequest(
    string Username,
    string? Password,
    UserRole Role,
    string? Pin = null,
    bool? PinProtectionEnabled = null,
    ProfileAccessMode? AccessMode = null,
    IReadOnlyList<Guid>? TitleIds = null,
    bool IsEnabled = true,
    string? DisplayName = null,
    string? PictureKey = null,
    int? AgeLimit = null);

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
    Automatic,
}

public enum ClassificationDecision
{
    Movie,
    TvShows,
    Ignore,
}

public enum LibraryAvailability
{
    Unknown,
    Available,
    Unavailable,
    Error,
}

public enum LibraryHealthStatus
{
    Unknown,
    Healthy,
    WaitingForStorage,
    PermissionDenied,
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
    Error,
}

public enum LibraryScanState
{
    Queued,
    Running,
    Completed,
    Failed,
    Interrupted,
    WaitingForStorage,
    Cancelled,
}

public enum LibraryScanTrigger
{
    Manual,
    FileChange,
    Startup,
    Scheduled,
    StorageReconnected,
    ClassificationChanged,
}

public sealed record CreateLibraryRequest(
    string? Name,
    string Path,
    LibraryKind Kind,
    bool CombineExisting = false,
    bool RequireImportPreview = false);

public sealed record UpdateLibraryMonitoringRequest(bool Enabled);

/// <summary>A folder on the server computer that can become a storage location.</summary>
public sealed record ServerFolder(string Name, string Path);

/// <summary>
/// The folders inside one folder on the server, for choosing a storage location from another
/// computer. Without a path it lists the usual places for drives and media.
/// </summary>
public sealed record ServerFolderListing(
    string? Path,
    string? Parent,
    IReadOnlyList<ServerFolder> Folders);

public sealed record LibraryDiscoverySummary(
    Guid Id,
    Guid LibraryId,
    string RelativePath,
    string DetectedTitle,
    LibraryKind? SuggestedKind,
    string Reason,
    ClassificationDecision? Decision);

public sealed record ClassificationDecisionUpdate(
    Guid DiscoveryId,
    ClassificationDecision Decision);

public sealed record UpdateClassificationDecisionsRequest(
    IReadOnlyList<ClassificationDecisionUpdate> Decisions);

public enum LibraryImportReviewState
{
    Pending,
    Assigned,
    Ignored,
}

public enum LibraryImportReviewAction
{
    AssignToMovie,
    Ignore,
}

public sealed record LibraryImportReviewSummary(
    Guid Id,
    Guid LibraryId,
    string RelativePath,
    string DetectedTitle,
    string Reason,
    LibraryImportReviewState State);

public sealed record UpdateLibraryImportReviewRequest(
    LibraryImportReviewAction Action,
    Guid? MovieId = null);

public sealed record LibrarySummary(
    Guid Id,
    string Name,
    string Path,
    LibraryKind Kind,
    LibraryAvailability Availability,
    DateTimeOffset CreatedAt,
    DateTimeOffset? LastScanStartedAt,
    DateTimeOffset? LastScanCompletedAt,
    string? LastError,
    bool MonitoringEnabled = true,
    DateTimeOffset? LastObservedAt = null,
    LibraryHealthStatus Health = LibraryHealthStatus.Unknown,
    bool ImportPreviewRequired = false);

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
    IReadOnlyList<LibraryScanIssueSummary> Issues,
    LibraryScanTrigger Trigger = LibraryScanTrigger.Manual,
    int Attempt = 0,
    string? TargetRelativePath = null,
    string Phase = "Queued",
    int RecognizedFiles = 0,
    int PendingFiles = 0,
    int IgnoredFiles = 0,
    int FailedFiles = 0);

public sealed record PagedResponse<T>(
    IReadOnlyList<T> Items,
    int Offset,
    int Limit,
    int Total,
    string? Revision = null);

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
    PlaybackProgressResponse Progress,
    MediaSegmentsDto? Segments = null);

public sealed record UpdatePlaybackProgressRequest(
    long PositionMilliseconds,
    long DurationMilliseconds,
    bool IsFinished,
    Guid? ClientMutationId = null,
    bool EnforceRevision = false,
    long? ExpectedRevision = null);

public sealed record PlaybackProgressResponse(
    Guid MediaId,
    long PositionMilliseconds,
    long DurationMilliseconds,
    bool IsCompleted,
    DateTimeOffset? LastPlayedAt,
    DateTimeOffset? UpdatedAt,
    long Revision = 0,
    Guid? LastMutationId = null);

public enum MetadataJobState
{
    Queued,
    Running,
    Completed,
    Failed,
    Interrupted,
    Cancelled,
}

public enum MetadataJobMode
{
    Incremental,
    FullRefresh,
    SingleItem,
    RetryFailed,
}

public sealed record StartMetadataJobRequest(
    MetadataJobMode Mode = MetadataJobMode.FullRefresh,
    Guid? LibraryId = null,
    Guid? MediaId = null);

public enum MetadataReviewState
{
    NeedsReview,
    Matched,
    Ignored,
}

public enum ArtworkKind
{
    Poster,
    Backdrop,
    Still,
    Profile,
}

public sealed record MetadataProviderStatus(
    bool Enabled,
    bool HasToken,
    string Language,
    long ArtworkBytes,
    long ArtworkLimitBytes,
    string Provider,
    string Attribution);

public sealed record UpdateMetadataProviderRequest(
    bool Enabled,
    string Language,
    string? Token);

public sealed record MetadataCandidateSummary(
    string Provider,
    string ProviderMediaId,
    string MediaType,
    string Title,
    string? OriginalTitle,
    int? Year,
    string? Overview,
    string? PosterPath,
    double Confidence,
    int? VoteCount = null);

public sealed record SelectMetadataMatchRequest(
    string ProviderMediaId,
    string MediaType);

public sealed record UpdateMediaMetadataRequest(
    string? Title = null,
    string? OriginalTitle = null,
    string? Overview = null,
    string? ReleaseDate = null,
    int? RuntimeMinutes = null,
    double? Rating = null,
    string? ContentRating = null,
    IReadOnlyList<string>? Genres = null,
    IReadOnlyList<string>? Studios = null,
    IReadOnlyList<string>? Countries = null,
    IReadOnlyList<string>? ClearFields = null);

public sealed record ArtworkSummary(
    Guid Id,
    ArtworkKind Kind,
    string Path,
    string ContentType,
    long ContentLength,
    long? Revision = null);

public sealed record CreditSummary(
    string Name,
    string Department,
    string? Job,
    string? Character,
    int Order,
    ArtworkSummary? Profile,
    Guid? Id = null,
    string? PersonKey = null);

public sealed record MediaMetadataSummary(
    Guid MediaId,
    string Title,
    string? OriginalTitle,
    string? Overview,
    string? ReleaseDate,
    int? Year,
    int? RuntimeMinutes,
    double? Rating,
    string? ContentRating,
    IReadOnlyList<string> Genres,
    IReadOnlyList<string> Studios,
    IReadOnlyList<string> Countries,
    IReadOnlyList<CreditSummary> Credits,
    ArtworkSummary? Poster,
    ArtworkSummary? Backdrop,
    ArtworkSummary? Still,
    string? Provider,
    string? ProviderMediaId,
    MetadataReviewState ReviewState,
    int? FskAge = null);

public sealed record MetadataReviewSummary(
    Guid Id,
    Guid MediaId,
    string Title,
    string Reason,
    MetadataReviewState State,
    IReadOnlyList<MetadataCandidateSummary> Candidates,
    DateTimeOffset UpdatedAt);

public sealed record MetadataJobSummary(
    Guid Id,
    Guid? LibraryId,
    Guid? MediaId,
    MetadataJobState State,
    int ItemsTotal,
    int ItemsProcessed,
    int ItemsMatched,
    int ItemsNeedingReview,
    int ItemsFailed,
    string? Error,
    DateTimeOffset CreatedAt,
    DateTimeOffset? StartedAt,
    DateTimeOffset? CompletedAt,
    MetadataJobMode Mode = MetadataJobMode.FullRefresh,
    int Attempt = 0,
    DateTimeOffset? NextAttemptAt = null,
    string? WaitReason = null,
    int ItemsSkipped = 0);

public enum CatalogWatchState
{
    Unplayed,
    InProgress,
    Completed,
}

public enum CatalogSort
{
    Title,
    DateAdded,
    ReleaseYear,
    LastPlayed,
}

public enum SortDirection
{
    Ascending,
    Descending,
}

public sealed record CatalogQuery(
    MediaKind? Kind = null,
    Guid? LibraryId = null,
    string? Genre = null,
    MediaAvailability? Availability = null,
    bool? Favorite = null,
    CatalogWatchState? WatchState = null,
    int? YearFrom = null,
    int? YearTo = null,
    CatalogSort Sort = CatalogSort.Title,
    SortDirection Direction = SortDirection.Ascending,
    int Offset = 0,
    int Limit = 100,
    bool Relevance = true);

public enum SyncChangeArea
{
    Catalog,
    Libraries,
    Metadata,
    Collections,
    UserState,
}

public sealed record SyncChangesResponse(
    long Cursor,
    bool ResetRequired,
    IReadOnlyList<SyncChangeArea> ChangedAreas,
    IReadOnlyList<Guid> ChangedMediaIds,
    string? Generation = null);

public sealed record SetFavoriteRequest(bool IsFavorite);

public sealed record SetWatchlistRequest(bool IsWatchlisted);

public sealed record WatchlistItemStateResponse(
    Guid MediaId,
    bool IsWatchlisted);

public sealed record WatchlistResponse(
    IReadOnlyList<CatalogItemSummary> Items,
    IReadOnlyList<Guid> MediaIds);

public sealed record PersonDetailResponse(
    string Name,
    string? Subtitle,
    ArtworkSummary? Profile,
    IReadOnlyList<CatalogItemSummary> Items);

public sealed record CatalogItemSummary(
    Guid Id,
    MediaKind Kind,
    string Title,
    string? OriginalTitle,
    int? Year,
    string? Overview,
    IReadOnlyList<string> Genres,
    ArtworkSummary? Poster,
    ArtworkSummary? Backdrop,
    MediaAvailability Availability,
    bool IsFavorite,
    PlaybackProgressResponse? Progress,
    DateTimeOffset AddedAt,
    string? ParentTitle = null,
    int? SeasonNumber = null,
    int? EpisodeNumber = null,
    Guid? ParentId = null,
    CatalogWatchState WatchState = CatalogWatchState.Unplayed,
    LibraryAvailability LibraryAvailability = LibraryAvailability.Unknown,
    bool ContinueWatchingHidden = false);

public sealed record EpisodePresentation(
    CatalogItemSummary Item,
    int SeasonNumber,
    int EpisodeNumber);

/// <summary>A trailer for a film's pre-show in cinema mode, and the film in the library it is for.</summary>
public sealed record CinemaTrailer(
    CatalogItemSummary Trailer,
    CatalogItemSummary Title);

public sealed record CinemaTrailersResponse(IReadOnlyList<CinemaTrailer> Trailers);

public sealed record SupplementPresentation(
    CatalogItemSummary Item,
    string Category,
    int? SeasonNumber);

public sealed record SeasonPresentation(
    int Number,
    IReadOnlyList<EpisodePresentation> Episodes,
    IReadOnlyList<SupplementPresentation> Supplements);

public sealed record CatalogDetailPresentation(
    CatalogItemSummary Item,
    MediaMetadataSummary Metadata,
    IReadOnlyList<SeasonPresentation> Seasons,
    IReadOnlyList<SupplementPresentation> Supplements,
    CollectionSummary? Franchise = null);

public sealed record CollectionSummary(
    Guid Id,
    string Name,
    ArtworkSummary? Poster,
    IReadOnlyList<CatalogItemSummary> Items,
    bool IsSmart = false,
    int TotalCount = 0,
    bool IsShared = true,
    Guid? UserId = null,
    string? RulesJson = null);

public sealed record SaveCollectionRequest(
    string Name,
    IReadOnlyList<Guid> MediaIds,
    bool IsSmart = false,
    bool IsShared = false,
    string? RulesJson = null);

public sealed record SmartCollectionRules(
    string? Kind = null,
    IReadOnlyList<string>? Genres = null,
    int? YearMin = null,
    int? YearMax = null,
    int? Decade = null,
    double? RatingMin = null,
    double? RatingMax = null,
    string? WatchedState = null,
    int? AddedWithinDays = null,
    bool? FavoritesOnly = null,
    bool? WatchlistOnly = null,
    string? TextContains = null,
    string Combination = "and");

public sealed record WatchHistoryItem(
    Guid Id,
    Guid MediaId,
    string Title,
    string? Eyebrow,
    int? Year,
    MediaKind Kind,
    ArtworkSummary? Poster,
    DateTimeOffset WatchedAt,
    long PositionMilliseconds,
    long DurationMilliseconds,
    long SecondsWatched,
    bool IsCompleted);

public sealed record WatchHistoryPage(
    IReadOnlyList<WatchHistoryItem> Items,
    int Offset,
    int Limit,
    int Total);

public sealed record UserStatistics(
    double TotalHoursWatched,
    double HoursPast7Days,
    double HoursPast30Days,
    IReadOnlyList<PeriodHours> HoursByWeek,
    IReadOnlyList<PeriodHours> HoursByMonth,
    IReadOnlyList<NamedCount> TopGenres,
    IReadOnlyList<NamedCount> TopTitles,
    int CurrentStreakDays,
    int LongestStreakDays,
    string BusiestWeekday,
    string BusiestTimeOfDay,
    double CompletionRate,
    IReadOnlyList<int> YearsAvailable);

public sealed record PeriodHours(string Period, double Hours);
public sealed record NamedCount(string Name, int Count, double? Hours = null);

public sealed record YearInReview(
    int Year,
    double TotalHoursWatched,
    int TitlesWatched,
    int MoviesWatched,
    int EpisodesWatched,
    string? TopGenre,
    string? TopTitle,
    string? BusiestDay,
    double? BusiestDayHours);

/// <summary>
/// A profile's year, or with <see cref="Month"/> one month, as slides, like a story: the server
/// chooses what to show and the lines, so every app shows the same.
/// <see cref="WrappedSlide.Accent"/> names one of the Wrapped colors: <c>night</c>,
/// <c>ember</c>, <c>violet</c>, <c>gold</c>, <c>rose</c>, <c>mint</c>, <c>ocean</c> or
/// <c>lime</c>.
/// </summary>
public sealed record YearWrapped(int Year, string ProfileName, IReadOnlyList<WrappedSlide> Slides, int? Month = null);

/// <summary>
/// One slide. <see cref="Kind"/> is <c>intro</c>, <c>hours</c>, <c>top-series</c>,
/// <c>top-movie</c>, <c>genre</c>, <c>night-owl</c>, <c>early-bird</c>,
/// <c>binge</c>, <c>rhythm</c>, <c>summary</c> or <c>empty</c>; a client that does not know a
/// kind shows it like any other. <see cref="BigNumber"/> is already formatted ("143", "02:47").
/// </summary>
public sealed record WrappedSlide(
    string Kind,
    string Eyebrow,
    string Headline,
    string? BigNumber,
    string? Unit,
    string? Detail,
    string Quip,
    string Accent,
    Guid? MediaId = null,
    ArtworkSummary? Poster = null,
    IReadOnlyList<ArtworkSummary>? Posters = null,
    IReadOnlyList<WrappedFact>? Facts = null);

public sealed record WrappedFact(string Label, string Value);

/// <summary>One file of a title that exists several times; the file name only, never the full path.</summary>
public sealed record DuplicateItemSummary(
    Guid Id,
    string Title,
    MediaKind Kind,
    int? Year,
    string FileName,
    long? FileSize,
    MediaAvailability Availability);

public sealed record DuplicateGroup(
    string Key,
    string Title,
    MediaKind Kind,
    int? Year,
    IReadOnlyList<DuplicateItemSummary> Items);

public sealed record OfflineTitleSummary(
    Guid Id,
    string Title,
    MediaKind Kind,
    int? Year,
    string LibraryName,
    string FileName,
    DateTimeOffset LastSeenAt,
    int DaysOffline);

public sealed record UnmatchedTitleSummary(
    Guid Id,
    string Title,
    MediaKind Kind,
    int? Year,
    string FileName,
    string IssueReason);

/// <summary>Moves personal data from a copy whose file is missing to another copy, then removes the missing one.</summary>
public sealed record MergeMediaRequest(
    Guid SourceMediaId,
    Guid TargetMediaId);

public sealed record HomeResponse(
    CatalogItemSummary? Recommendation,
    IReadOnlyList<CatalogItemSummary> ContinueWatching,
    IReadOnlyList<CatalogItemSummary> RecentlyAdded,
    IReadOnlyList<CatalogItemSummary> Favorites,
    IReadOnlyList<CollectionSummary> Collections,
    DateTimeOffset RecommendationChangesAt);
