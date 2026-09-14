namespace Aurelia.Server.Data;

public sealed class LibraryScanIssue
{
    public long Id { get; set; }

    public Guid LibraryScanId { get; set; }

    public LibraryScan LibraryScan { get; set; } = null!;

    public string Code { get; set; } = string.Empty;

    public string Message { get; set; } = string.Empty;

    public string? Path { get; set; }
}
