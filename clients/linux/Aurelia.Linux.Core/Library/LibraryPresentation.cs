using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Library;

/// <summary>A row of titles on Home.</summary>
public sealed record HomeRow(string Title, IReadOnlyList<CatalogItemSummary> Items);

/// <summary>Presentation rules shared with the Mac app.</summary>
public static class LibraryPresentation
{
    /// <summary>The first genres in alphabetical order, each with every title that has it (Mac: HomePresentationLogic).</summary>
    public static IReadOnlyList<HomeRow> GenreRows(IEnumerable<CatalogItemSummary> items, int limit = 3)
    {
        var grouped = new Dictionary<string, List<CatalogItemSummary>>(StringComparer.CurrentCultureIgnoreCase);
        foreach (var item in items)
        {
            foreach (var genre in item.Genres.Select(g => g.Trim()).Where(g => g.Length > 0).Distinct(StringComparer.CurrentCultureIgnoreCase))
            {
                if (!grouped.TryGetValue(genre, out var list)) grouped[genre] = list = [];
                list.Add(item);
            }
        }
        return [.. grouped.Keys.Order(StringComparer.CurrentCultureIgnoreCase).Take(limit).Select(genre => new HomeRow(genre, grouped[genre]))];
    }

    /// <summary>
    /// Titles shown in rows: offline titles are hidden when that setting is on, watched ones unless
    /// "Show Watched Titles in Rows" is on or the page keeps them (grids do).
    /// </summary>
    public static IReadOnlyList<CatalogItemSummary> Visible(IEnumerable<CatalogItemSummary> items, bool keepWatched, bool showWatched, bool hideOffline) =>
        [.. items.Where(item =>
            !(hideOffline && item.Kind != MediaKind.Series && item.Availability != MediaAvailability.Available)
            && (keepWatched || showWatched || item.WatchState != CatalogWatchState.Completed))];

    /// <summary>"MOVIE · 2021", "TV SHOW · 2024" or "Show · S1 E2" above a title.</summary>
    public static string Eyebrow(CatalogItemSummary item) => item.Kind switch
    {
        MediaKind.Episode when item.SeasonNumber is { } season && item.EpisodeNumber is { } episode =>
            $"{item.ParentTitle ?? "Episode"} · S{season} E{episode}",
        MediaKind.Series => item.Year is { } year ? $"TV SHOW · {year}" : "TV SHOW",
        MediaKind.Movie => item.Year is { } year ? $"MOVIE · {year}" : "MOVIE",
        _ => item.Kind.ToString().ToUpperInvariant(),
    };

    /// <summary>How far through the title the profile is, from 0 to 1, or null without progress.</summary>
    public static double? ProgressFraction(CatalogItemSummary item) =>
        item.Progress is { DurationMilliseconds: > 0 } progress && !progress.IsCompleted && progress.PositionMilliseconds > 0
            ? Math.Clamp((double)progress.PositionMilliseconds / progress.DurationMilliseconds, 0, 1)
            : null;

    public static bool IsPlayable(CatalogItemSummary item) =>
        item.Kind != MediaKind.Series && item.Availability == MediaAvailability.Available;

    /// <summary>The picture for a landscape card or hero: backdrop, else poster.</summary>
    public static ArtworkSummary? LandscapeArtwork(CatalogItemSummary item) => item.Backdrop ?? item.Poster;
}
