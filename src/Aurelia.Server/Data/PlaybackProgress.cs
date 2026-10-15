namespace Aurelia.Server.Data;

public sealed class PlaybackProgress
{
    public Guid Id { get; set; }

    public Guid MediaItemId { get; set; }

    public required MediaItem MediaItem { get; set; }

    public Guid UserId { get; set; }

    public required ServerUser User { get; set; }

    public long PositionMilliseconds { get; set; }

    public long DurationMilliseconds { get; set; }

    public bool IsCompleted { get; set; }

    public DateTimeOffset? LastPlayedAt { get; set; }

    public DateTimeOffset UpdatedAt { get; set; }

    public long Revision { get; set; }

    public Guid? LastMutationId { get; set; }

    public string? LastMutationFingerprint { get; set; }
}
