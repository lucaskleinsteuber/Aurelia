namespace Aurelia.Server.Data;

public sealed class UserLibraryGrant
{
    public Guid UserId { get; set; }
    public Guid LibraryRootId { get; set; }
    public ServerUser User { get; set; } = null!;
    public LibraryRoot LibraryRoot { get; set; } = null!;
}
