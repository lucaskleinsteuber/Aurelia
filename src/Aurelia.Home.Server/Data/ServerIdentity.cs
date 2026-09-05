namespace Aurelia.Home.Server.Data;

public sealed class ServerIdentity
{
    public int Id { get; set; }

    public Guid ServerId { get; set; }

    public DateTimeOffset CreatedAt { get; set; }
}
