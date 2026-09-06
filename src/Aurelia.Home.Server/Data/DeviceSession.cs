namespace Aurelia.Home.Server.Data;

public sealed class DeviceSession
{
    public Guid Id { get; set; }

    public Guid UserId { get; set; }

    public required ServerUser User { get; set; }

    public required string DeviceName { get; set; }

    public required string TokenHash { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset LastSeenAt { get; set; }

    public DateTimeOffset ExpiresAt { get; set; }

    public DateTimeOffset? RevokedAt { get; set; }

    public List<PlaybackTicket> PlaybackTickets { get; set; } = [];
}
