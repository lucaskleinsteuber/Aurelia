using Aurelia.Home.Contracts;

namespace Aurelia.Home.Server.Data;

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
    public Guid Id { get; set; }
    public Guid? LibraryRootId { get; set; }
    public Guid? MediaItemId { get; set; }
    public MetadataJobState State { get; set; }
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
    public string? Provider { get; set; }
    public string? ProviderCollectionId { get; set; }
    public string? SourceKey { get; set; }
    public bool IsManual { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public List<MediaCollectionMember> Members { get; set; } = [];
}

public sealed class MediaCollectionMember
{
    public Guid CollectionId { get; set; }
    public MediaCollectionRecord Collection { get; set; } = null!;
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;
    public int SortOrder { get; set; }
}
