namespace Aurelia.Server.Data;

public sealed class ContinueWatchingState
{
    public Guid UserId { get; set; }
    public Guid MediaItemId { get; set; }
    public ServerUser User { get; set; } = null!;
    public MediaItem MediaItem { get; set; } = null!;
    public bool IsHidden { get; set; }
    public long Revision { get; set; }
}

public sealed class LibraryStateMutation
{
    public Guid UserId { get; set; }
    public Guid ClientMutationId { get; set; }
    public ServerUser User { get; set; } = null!;
    public string Fingerprint { get; set; } = string.Empty;
    public string ResponseJson { get; set; } = string.Empty;
    public long AccessRevision { get; set; }
}
