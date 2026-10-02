using Aurelia.Contracts;

namespace Aurelia.Server.Data;

public sealed class MediaItem
{
    public Guid Id { get; set; }

    public Guid LibraryRootId { get; set; }

    public LibraryRoot LibraryRoot { get; set; } = null!;

    public Guid? ParentId { get; set; }

    public MediaItem? Parent { get; set; }

    public List<MediaItem> Children { get; } = [];

    public MediaKind Kind { get; set; }

    public string SourcePath { get; set; } = string.Empty;

    public string NormalizedSourcePath { get; set; } = string.Empty;

    public bool ManualSourceBinding { get; set; }

    public string DetectedTitle { get; set; } = string.Empty;

    public string? OverrideTitle { get; set; }

    public int? Year { get; set; }

    public int? SeasonNumber { get; set; }

    public int? EpisodeNumber { get; set; }

    public string Category { get; set; } = string.Empty;

    public string? Extension { get; set; }

    public long? FileSize { get; set; }

    public DateTimeOffset? FileModifiedAt { get; set; }

    public string? FileSystemIdentity { get; set; }

    public MediaAvailability Availability { get; set; }

    public Guid? LastSeenScanId { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset UpdatedAt { get; set; }

    public List<PlaybackTicket> PlaybackTickets { get; set; } = [];

    public List<PlaybackProgress> PlaybackProgress { get; set; } = [];

    public MediaMetadata? Metadata { get; set; }

    public List<MetadataReview> MetadataReviews { get; set; } = [];

    public List<UserFavorite> Favorites { get; set; } = [];

    public List<MediaCollectionMember> CollectionMemberships { get; set; } = [];
}
