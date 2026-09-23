using Aurelia.Contracts;

namespace Aurelia.Server.Data;

public sealed class LibraryRoot
{
    public Guid Id { get; set; }

    public string Name { get; set; } = string.Empty;

    public string Path { get; set; } = string.Empty;

    public string NormalizedPath { get; set; } = string.Empty;

    public LibraryKind Kind { get; set; }

    public LibraryAvailability Availability { get; set; }

    public bool MonitoringEnabled { get; set; } = true;

    public DateTimeOffset? LastObservedAt { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset? LastScanStartedAt { get; set; }

    public DateTimeOffset? LastScanCompletedAt { get; set; }

    public string? LastError { get; set; }

    public List<MediaItem> MediaItems { get; } = [];

    public List<LibraryScan> Scans { get; } = [];

    public List<LibraryDiscovery> Discoveries { get; } = [];

    public List<LibraryImportReview> ImportReviews { get; } = [];
}
