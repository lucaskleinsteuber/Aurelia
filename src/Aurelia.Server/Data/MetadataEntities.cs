using Aurelia.Contracts;

namespace Aurelia.Server.Data;

public sealed class MediaMetadata
{
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;
    public string? Provider { get; set; }
    public string? ProviderMediaId { get; set; }
    public string? ProviderMediaType { get; set; }
    public double? MatchConfidence { get; set; }
    public string? ProviderTitle { get; set; }
    public string? ProviderOriginalTitle { get; set; }
    public string? ProviderOverview { get; set; }
    public string? ProviderReleaseDate { get; set; }
    public int? ProviderRuntimeMinutes { get; set; }
    public double? ProviderRating { get; set; }
    public string? ProviderContentRating { get; set; }
    public string ProviderGenresJson { get; set; } = "[]";
    public string ProviderStudiosJson { get; set; } = "[]";
    public string ProviderCountriesJson { get; set; } = "[]";
    public string? ManualTitle { get; set; }
    public string? ManualOriginalTitle { get; set; }
    public string? ManualOverview { get; set; }
    public string? ManualReleaseDate { get; set; }
    public int? ManualRuntimeMinutes { get; set; }
    public double? ManualRating { get; set; }
    public string? ManualContentRating { get; set; }
    public string? ManualGenresJson { get; set; }
    public string? ManualStudiosJson { get; set; }
    public string? ManualCountriesJson { get; set; }
    public int? ManualReleaseYear { get; set; }
    public string ManualFieldsJson { get; set; } = "[]";
    public string ProviderCreditsJson { get; set; } = "[]";
    public long EditorRevision { get; set; }
    public Guid? ManualPosterId { get; set; }
    public Guid? ManualBackdropId { get; set; }
    public MetadataReviewState ReviewState { get; set; } = MetadataReviewState.NeedsReview;
    public DateTimeOffset? ProviderUpdatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public List<MediaCredit> Credits { get; set; } = [];
    public List<ArtworkAsset> Artwork { get; set; } = [];
}

public sealed class MediaCredit
{
    public Guid Id { get; set; }
    public Guid MediaItemId { get; set; }
    public MediaMetadata Metadata { get; set; } = null!;
    public string? ProviderPersonId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Department { get; set; } = string.Empty;
    public string? Job { get; set; }
    public string? Character { get; set; }
    public int SortOrder { get; set; }
    public string? ProfilePath { get; set; }
    public Guid? ProfileAssetId { get; set; }
}

public sealed class ArtworkAsset
{
    public Guid Id { get; set; }
    public Guid MediaItemId { get; set; }
    public MediaMetadata Metadata { get; set; } = null!;
    public ArtworkKind Kind { get; set; }
    public string ProviderPath { get; set; } = string.Empty;
    public string RelativeFilePath { get; set; } = string.Empty;
    public string ContentType { get; set; } = string.Empty;
    public long ContentLength { get; set; }
    public long Revision { get; set; } = 1;
    public bool IsManual { get; set; }
    public string? OriginalFilePath { get; set; }
    public string? CropJson { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
}

public sealed class MetadataReview
{
    public Guid Id { get; set; }
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;
    public string Reason { get; set; } = string.Empty;
    public string CandidatesJson { get; set; } = "[]";
    public MetadataReviewState State { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

public sealed class MetadataJob
{
    public Guid? RequestedByUserId { get; set; }
    public bool WorklistInitialized { get; set; }
    public int ItemsSkipped { get; set; }
    public DateTimeOffset? NextAttemptAt { get; set; }
    public string? WaitReason { get; set; }
    public Guid Id { get; set; }
    public Guid? LibraryRootId { get; set; }
    public Guid? MediaItemId { get; set; }
    public MetadataJobState State { get; set; }
    public MetadataJobMode Mode { get; set; } = MetadataJobMode.FullRefresh;
    public int Attempt { get; set; }
    public DateTimeOffset? LeaseExpiresAt { get; set; }
    public DateTimeOffset? HeartbeatAt { get; set; }
    public DateTimeOffset? CancelRequestedAt { get; set; }
    public int ItemsTotal { get; set; }
    public int ItemsProcessed { get; set; }
    public int ItemsMatched { get; set; }
    public int ItemsNeedingReview { get; set; }
    public int ItemsFailed { get; set; }
    public string? Error { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? StartedAt { get; set; }
    public DateTimeOffset? CompletedAt { get; set; }
}

public enum MetadataWorkState { Pending, Processing, Matched, NeedsReview, Skipped, Failed }

public sealed class MetadataJobItem
{
    public Guid JobId { get; set; }
    public MetadataJob Job { get; set; } = null!;
    // Deliberately retained when a title is removed, so totals remain stable.
    public Guid MediaItemId { get; set; }
    public int Ordinal { get; set; }
    public MetadataWorkState State { get; set; }
    public int Attempt { get; set; }
    public DateTimeOffset? CompletedAt { get; set; }
}

public sealed class MetadataProviderCooldown
{
    public string Provider { get; set; } = "tmdb";
    public DateTimeOffset? NotBefore { get; set; }
    public string? WaitReason { get; set; }
}

public sealed class UserFavorite
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public ServerUser User { get; set; } = null!;
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;
    public DateTimeOffset CreatedAt { get; set; }
}

public sealed class MediaCollectionRecord
{
    public Guid Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Overview { get; set; }
    public string? SortMode { get; set; }
    public string? Provider { get; set; }
    public string? ProviderCollectionId { get; set; }
    public string? ProviderPosterPath { get; set; }
    public string? ProviderBackdropPath { get; set; }
    public string? SourceKey { get; set; }
    public Guid? PosterAssetId { get; set; }
    public Guid? BackdropAssetId { get; set; }
    public bool IsManual { get; set; }
    public Guid? UserId { get; set; }
    public ServerUser? User { get; set; }
    public bool IsSmart { get; set; }
    public string? SmartRulesJson { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public List<MediaCollectionMember> Members { get; set; } = [];
    public List<CollectionArtworkAsset> Artwork { get; set; } = [];
}

public sealed class CollectionArtworkAsset
{
    public Guid Id { get; set; }
    public Guid CollectionId { get; set; }
    public MediaCollectionRecord Collection { get; set; } = null!;
    public ArtworkKind Kind { get; set; }
    public string ProviderPath { get; set; } = string.Empty;
    public string RelativeFilePath { get; set; } = string.Empty;
    public string ContentType { get; set; } = string.Empty;
    public long ContentLength { get; set; }
    public long Revision { get; set; } = 1;
    public bool IsManual { get; set; }
    public string? OriginalFilePath { get; set; }
    public string? CropJson { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
}

public sealed class MediaCollectionMember
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid CollectionId { get; set; }
    public MediaCollectionRecord Collection { get; set; } = null!;
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;
    public int? SeasonNumber { get; set; }
    public int SortOrder { get; set; }
}
