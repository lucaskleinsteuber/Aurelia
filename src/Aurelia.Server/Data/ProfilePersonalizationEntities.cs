namespace Aurelia.Server.Data;

/// <summary>A profile's own photo, re-encoded as a small square JPEG. It lives in the database so backups keep it.</summary>
public sealed class ProfilePhoto
{
    public Guid UserId { get; set; }
    public ServerUser User { get; set; } = null!;
    public byte[] Jpeg { get; set; } = [];
    public DateTimeOffset UpdatedAt { get; set; }
}

/// <summary>A children's profile's exception for one film or series: watch it anyway, or always hide it.</summary>
public sealed class UserTitleRule
{
    public Guid UserId { get; set; }
    public ServerUser User { get; set; } = null!;
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;
    public bool Allowed { get; set; }
}
