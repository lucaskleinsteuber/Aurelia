using Aurelia.Contracts;

namespace Aurelia.Server.Data;

/// <summary>A movie or series wished by a family profile.</summary>
public sealed class WishRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public ServerUser? User { get; set; }
    public MediaKind Kind { get; set; } = MediaKind.Movie;
    public string? Provider { get; set; }
    public string? ProviderMediaId { get; set; }
    public string Title { get; set; } = string.Empty;
    public int? Year { get; set; }
    public string? Overview { get; set; }
    public string? PosterPath { get; set; }
    public string? AgeRating { get; set; }
    public string? Note { get; set; }
    public WishState State { get; set; } = WishState.Open;
    public Guid? ResolvedByUserId { get; set; }
    public ServerUser? ResolvedByUser { get; set; }
    public string? ResolutionNote { get; set; }
    public Guid? FulfilledMediaItemId { get; set; }
    public MediaItem? FulfilledMediaItem { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? ResolvedAt { get; set; }
    public DateTimeOffset? SeenByWisherAt { get; set; }
    public ICollection<WishSupport> Supports { get; set; } = [];
}

/// <summary>Another profile supporting an open wish ("Me Too").</summary>
public sealed class WishSupport
{
    public Guid WishId { get; set; }
    public WishRecord? Wish { get; set; }
    public Guid UserId { get; set; }
    public ServerUser? User { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
}
