namespace Aurelia.Server.Data;

public sealed class SceneNote
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public ServerUser User { get; set; } = null!;
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;
    public long StartMilliseconds { get; set; }
    public long? EndMilliseconds { get; set; }
    public string Text { get; set; } = string.Empty;
    public long Revision { get; set; }
}
