using Aurelia.Contracts;

namespace Aurelia.Server.Data;

public sealed class LibraryScan
{
    public Guid Id { get; set; }
    public Guid? ConfirmedPreviewId { get; set; }

    public Guid LibraryRootId { get; set; }

    public LibraryRoot LibraryRoot { get; set; } = null!;

    public LibraryScanState State { get; set; }

    public LibraryScanTrigger Trigger { get; set; } = LibraryScanTrigger.Manual;

    public string? TargetRelativePath { get; set; }

    public int Attempt { get; set; }

    public DateTimeOffset? LeaseExpiresAt { get; set; }

    public DateTimeOffset? HeartbeatAt { get; set; }

    public DateTimeOffset? CancelRequestedAt { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset? StartedAt { get; set; }

    public DateTimeOffset? CompletedAt { get; set; }

    public int FilesDiscovered { get; set; }

    public int FilesProcessed { get; set; }

    public int AddedFiles { get; set; }

    public int UpdatedFiles { get; set; }

    public int MissingFiles { get; set; }

    public int SkippedFiles { get; set; }
    public string Phase { get; set; } = "Queued";
    public int RecognizedFiles { get; set; }
    public int PendingFiles { get; set; }
    public int IgnoredFiles { get; set; }
    public int FailedFiles { get; set; }

    public string? Error { get; set; }

    public List<LibraryScanIssue> Issues { get; } = [];
}
