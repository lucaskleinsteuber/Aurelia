using Aurelia.Contracts;

namespace Aurelia.Server.Data;

public sealed class SyncChange
{
    public long Cursor { get; set; }

    public SyncChangeArea Area { get; set; }

    public Guid? UserId { get; set; }

    public Guid? MediaItemId { get; set; }

    public DateTimeOffset CreatedAt { get; set; }
}
