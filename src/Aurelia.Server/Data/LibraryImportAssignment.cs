using Aurelia.Contracts;

namespace Aurelia.Server.Data;

public sealed class LibraryImportAssignment
{
    public Guid Id { get; set; }
    public Guid LibraryRootId { get; set; }
    public LibraryRoot LibraryRoot { get; set; } = null!;
    public string RelativePath { get; set; } = string.Empty;
    public string NormalizedRelativePath { get; set; } = string.Empty;
    public bool IsDirectory { get; set; }
    public MediaKind? Kind { get; set; }
    public string? ParentRelativePath { get; set; }
    public int? SeasonNumber { get; set; }
    public int? EpisodeNumber { get; set; }
    public string? Category { get; set; }
    public string? Title { get; set; }
}

public sealed class LibraryImportPreview
{
    public Guid Id { get; set; }
    public Guid LibraryRootId { get; set; }
    public LibraryRoot LibraryRoot { get; set; } = null!;
    public string Revision { get; set; } = string.Empty;
    public long BaseAssignmentRevision { get; set; }
    public string Manifest { get; set; } = string.Empty;
    public string ItemsJson { get; set; } = "[]";
    public string AssignmentsJson { get; set; } = "[]";
    public string SummaryJson { get; set; } = "{}";
    public DateTimeOffset CreatedAt { get; set; }
    public bool Confirmed { get; set; }
    public bool WasInitialImport { get; set; }
}
