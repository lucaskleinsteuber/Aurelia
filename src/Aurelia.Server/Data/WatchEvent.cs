namespace Aurelia.Server.Data;

public sealed class WatchEvent
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public ServerUser User { get; set; } = null!;
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;
    public DateTimeOffset Timestamp { get; set; }
    public long PositionMilliseconds { get; set; }
    public long DurationMilliseconds { get; set; }
    public long SecondsWatched { get; set; }
    public bool IsCompleted { get; set; }
}
