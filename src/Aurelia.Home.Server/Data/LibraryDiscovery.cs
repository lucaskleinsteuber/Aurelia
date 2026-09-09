using Aurelia.Home.Contracts;

namespace Aurelia.Home.Server.Data;

public sealed class LibraryDiscovery
{
    public Guid Id { get; set; }

    public Guid LibraryRootId { get; set; }

    public LibraryRoot LibraryRoot { get; set; } = null!;

    public string RelativePath { get; set; } = string.Empty;

    public string NormalizedRelativePath { get; set; } = string.Empty;

    public string DetectedTitle { get; set; } = string.Empty;

    public LibraryKind? SuggestedKind { get; set; }

    public string Reason { get; set; } = string.Empty;

    public ClassificationDecision? Decision { get; set; }

    public Guid? LastSeenScanId { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset UpdatedAt { get; set; }
}
