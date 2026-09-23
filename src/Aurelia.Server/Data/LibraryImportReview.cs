using Aurelia.Contracts;

namespace Aurelia.Server.Data;

public sealed class LibraryImportReview
{
    public Guid Id { get; set; }

    public Guid LibraryRootId { get; set; }

    public LibraryRoot LibraryRoot { get; set; } = null!;

    public string RelativePath { get; set; } = string.Empty;

    public string NormalizedRelativePath { get; set; } = string.Empty;

    public string DetectedTitle { get; set; } = string.Empty;

    public string Reason { get; set; } = string.Empty;

    public LibraryImportReviewState State { get; set; }

    public Guid? AssignedMovieId { get; set; }

    public MediaItem? AssignedMovie { get; set; }

    public Guid? LastSeenScanId { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset UpdatedAt { get; set; }
}
