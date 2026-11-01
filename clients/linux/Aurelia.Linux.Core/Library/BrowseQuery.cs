using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Library;

/// <summary>The library pages that list titles with filters.</summary>
public enum BrowseSection
{
    Library,
    Movies,
    TvShows,
    RecentlyAdded,
}

public enum BrowseSort
{
    Default,
    Title,
    DateAdded,
    ReleaseYear,
    LastWatched,
}

/// <summary>
/// The filters and sort of a library page, as on the Mac (CatalogBrowseQuery). Search text is not
/// part of it: it is never remembered.
/// </summary>
public sealed record BrowseQuery(
    MediaKind? Kind = null,
    bool FavoritesOnly = false,
    string? Genre = null,
    int? YearFrom = null,
    int? YearTo = null,
    CatalogWatchState? WatchState = null,
    BrowseSort Sort = BrowseSort.Default,
    bool Descending = false)
{
    public static BrowseQuery DefaultFor(BrowseSection section) => section switch
    {
        BrowseSection.Movies => new(Kind: MediaKind.Movie),
        BrowseSection.TvShows => new(Kind: MediaKind.Series),
        BrowseSection.RecentlyAdded => new(Sort: BrowseSort.DateAdded, Descending: true),
        _ => new(),
    };

    /// <summary>Movies and TV Shows always keep their kind; other pages may choose one.</summary>
    public BrowseQuery ConstrainedTo(BrowseSection section) => section switch
    {
        BrowseSection.Movies => this with { Kind = MediaKind.Movie },
        BrowseSection.TvShows => this with { Kind = MediaKind.Series },
        _ => this,
    };

    public bool HasFilters => FavoritesOnly || Genre is not null || YearFrom is not null || YearTo is not null || WatchState is not null;

    /// <summary>The query string for /api/v1/catalog/items or /search.</summary>
    public IEnumerable<KeyValuePair<string, string>> Parameters(string? search)
    {
        if (!string.IsNullOrWhiteSpace(search)) yield return new("query", search.Trim());
        if (Kind is { } kind) yield return new("kind", kind == MediaKind.Movie ? "movie" : "series");
        if (FavoritesOnly) yield return new("favorite", "true");
        if (Genre is { Length: > 0 } genre) yield return new("genre", genre);
        if (YearFrom is { } from) yield return new("yearFrom", from.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (YearTo is { } to) yield return new("yearTo", to.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (WatchState is { } state)
        {
            yield return new("watchState", state switch
            {
                CatalogWatchState.Unplayed => "unplayed",
                CatalogWatchState.InProgress => "inProgress",
                _ => "completed",
            });
        }
        if (Sort != BrowseSort.Default)
        {
            yield return new("sort", Sort switch
            {
                BrowseSort.Title => "title",
                BrowseSort.DateAdded => "dateAdded",
                BrowseSort.ReleaseYear => "releaseYear",
                _ => "lastPlayed",
            });
            yield return new("direction", Descending ? "descending" : "ascending");
        }
    }
}
