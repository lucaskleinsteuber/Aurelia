using Aurelia.Contracts;

namespace Aurelia.Server.Data;

public sealed class LibraryScan
{
    public Guid Id { get; set; }

    public Guid LibraryRootId { get; set; }

    public LibraryRoot LibraryRoot { get; set; } = null!;

    public LibraryScanState State { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset? StartedAt { get; set; }

    public DateTimeOffset? CompletedAt { get; set; }

    public int FilesDiscovered { get; set; }

    public int FilesProcessed { get; set; }

    public int AddedFiles { get; set; }

    public int UpdatedFiles { get; set; }

    public int MissingFiles { get; set; }

    public int SkippedFiles { get; set; }

    public string? Error { get; set; }

    public List<LibraryScanIssue> Issues { get; } = [];
}
