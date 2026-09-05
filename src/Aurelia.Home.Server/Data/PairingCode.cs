namespace Aurelia.Home.Server.Data;

public sealed class PairingCode
{
    public Guid Id { get; set; }

    public Guid UserId { get; set; }

    public required ServerUser User { get; set; }

    public required string CodeHash { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset ExpiresAt { get; set; }

    public DateTimeOffset? ConsumedAt { get; set; }
}
