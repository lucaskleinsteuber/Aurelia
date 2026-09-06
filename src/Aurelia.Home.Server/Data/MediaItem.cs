using Aurelia.Home.Contracts;

namespace Aurelia.Home.Server.Data;

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

    public string DetectedTitle { get; set; } = string.Empty;

    public string? OverrideTitle { get; set; }

    public int? Year { get; set; }

    public int? SeasonNumber { get; set; }

    public int? EpisodeNumber { get; set; }

    public string Category { get; set; } = string.Empty;

    public string? Extension { get; set; }

    public long? FileSize { get; set; }

    public DateTimeOffset? FileModifiedAt { get; set; }

    public MediaAvailability Availability { get; set; }

    public Guid? LastSeenScanId { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset UpdatedAt { get; set; }

    public List<PlaybackTicket> PlaybackTickets { get; set; } = [];
}
