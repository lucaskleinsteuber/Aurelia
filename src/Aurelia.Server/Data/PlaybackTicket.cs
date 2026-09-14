namespace Aurelia.Server.Data;

public sealed class PlaybackTicket
{
    public Guid Id { get; set; }

    public Guid MediaItemId { get; set; }

    public required MediaItem MediaItem { get; set; }

    public Guid UserId { get; set; }

    public required ServerUser User { get; set; }

    public Guid DeviceSessionId { get; set; }

    public required DeviceSession DeviceSession { get; set; }

    public required string TokenHash { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset ExpiresAt { get; set; }

    public DateTimeOffset? RevokedAt { get; set; }
}
