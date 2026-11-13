namespace Aurelia.Server.Data;

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

    /// <summary>A random identifier the app keeps for itself, used to block a device.</summary>
    public string? InstallationId { get; set; }

    /// <summary>"iPhone or iPad", "Mac", "Linux", "Apple TV" or "Browser · Safari on Mac".</summary>
    public string? Platform { get; set; }

    public string? ClientVersion { get; set; }

    public string? FirstIpAddress { get; set; }

    public string? LastIpAddress { get; set; }

    /// <summary>When the owner confirmed this device; null while it is new.</summary>
    public DateTimeOffset? AcknowledgedAt { get; set; }

    public List<PlaybackTicket> PlaybackTickets { get; set; } = [];
}
