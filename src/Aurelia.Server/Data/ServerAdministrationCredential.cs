namespace Aurelia.Server.Data;

// Exactly one server-wide administration secret, independent of viewing PINs.
public sealed class ServerAdministrationCredential
{
    public int Id { get; set; } = 1;
    public required string PasswordHash { get; set; }
}
