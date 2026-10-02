namespace Aurelia.Server.Data;

public sealed class MediaExclusion
{
    public Guid Id { get; set; }
    public Guid LibraryRootId { get; set; }
    public LibraryRoot LibraryRoot { get; set; } = null!;
    public string RelativePath { get; set; } = string.Empty;
    public string NormalizedSourcePath { get; set; } = string.Empty;
    public string? FileSystemIdentity { get; set; }
    public bool IsDirectory { get; set; }
}

// The database commits the catalog removal and its cleanup receipt together.
// A crash or full disk cannot lose the list of managed image files to remove.
public sealed class LibraryMutation
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public string State { get; set; } = "cleaning";
    public int RemovedItems { get; set; }
    public string FilesJson { get; set; } = "[]";
    public string? Error { get; set; }
}
