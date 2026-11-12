namespace Aurelia.Server.Data;

/// <summary>
/// TMDB's keywords for a matched movie or series (since 2.11.0), for suggestions. Kept in their
/// own table beside the metadata; a title without a row has not been asked yet.
/// </summary>
public sealed class MediaKeywords
{
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;

    /// <summary>A JSON list of at most 60 keywords, such as ["time travel","heist"].</summary>
    public string KeywordsJson { get; set; } = "[]";

    public DateTimeOffset UpdatedAt { get; set; }
}
