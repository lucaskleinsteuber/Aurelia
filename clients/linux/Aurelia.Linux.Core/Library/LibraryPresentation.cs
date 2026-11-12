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

/// <summary>Pending artwork upload/crop pair when saving a Box Set.</summary>
public sealed record CollectionArtworkDraft(Guid? UploadId, byte[]? Bytes, ArtworkCrop? Crop);

/// <summary>Shared Box Set presentation and queue flattening helpers.</summary>
public static class BoxSetPresentation
{
    public static string? ProviderLabel(string? provider) => provider switch
    {
        "tmdb" => "TMDB Collection",
        "universe" => "Universe",
        { Length: > 0 } other => other,
        _ => null,
    };

    public static bool CanEditCollection(CollectionSummary collection, LibraryStore store)
    {
        if (store.Client.SupportsCollectionsV3) return collection.CanEdit;
        if (collection.Provider is not null) return collection.CanEdit;
        return collection.CanEdit
            || collection.UserId == store.Client.Profile.User.Id
            || (collection.IsShared && store.CanManageMedia);
    }

    public static string CardSubtitle(CollectionSummary collection)
    {
        var parts = new List<string>();
        if (ProviderLabel(collection.Provider) is { } label) parts.Add(label);
        else if (collection.IsSmart) parts.Add("Smart List");
        if (collection.YearRange is { Length: > 0 } range) parts.Add(range);
        var total = collection.ItemCount > 0 ? collection.ItemCount : collection.TotalCount > 0 ? collection.TotalCount : collection.Items.Count;
        if (total > 0 && collection.WatchedCount > 0) parts.Add($"{collection.WatchedCount} of {total} watched");
        else if (total > 0 && parts.Count == 0) parts.Add(total == 1 ? "1 title" : $"{total} titles");
        return parts.Count == 0 ? "Collection" : string.Join(" · ", parts);
    }

    public static string StatsLine(CollectionDetail detail)
    {
        var count = detail.ItemCount > 0 ? detail.ItemCount : detail.Members.Count;
        var parts = new List<string> { count == 1 ? "1 title" : $"{count} titles" };
        if (count > 0) parts.Add($"{detail.WatchedCount} of {count} watched");
        if (detail.YearRange is { Length: > 0 } range) parts.Add(range);
        if (detail.TotalRuntimeSeconds >= 60)
        {
            var minutes = (int)((detail.TotalRuntimeSeconds + 30) / 60);
            var hours = minutes / 60;
            var rem = minutes % 60;
            parts.Add(hours > 0 ? (rem > 0 ? $"{hours} h {rem} min" : $"{hours} h") : $"{rem} min");
        }
        return string.Join("  ·  ", parts);
    }

    public static string PlayLabel(CollectionNextResponse? next)
    {
        if (next is null) return "Play";
        var prefix = next.Resume ? "Resume" : "Play";
        var target = next.Item;
        if (target.Kind == MediaKind.Episode && target.SeasonNumber is { } season && target.EpisodeNumber is { } episode)
        {
            return $"{prefix} · S{season:00} E{episode:00}";
        }
        return target.Title.Length > 0 ? $"{prefix} · {target.Title}" : prefix;
    }

    public static IReadOnlyList<CatalogItemSummary> PlayableItems(CollectionDetail detail)
    {
        var seen = new HashSet<Guid>();
        var ordered = new List<CatalogItemSummary>();
        foreach (var member in detail.Members)
        {
            IEnumerable<CatalogItemSummary> units = member.Episodes is { Count: > 0 } episodes
                ? episodes
                : member.Item is not null ? [member.Item] : [];
            foreach (var item in units)
            {
                if (item.Kind is MediaKind.Movie or MediaKind.Episode && seen.Add(item.Id)) ordered.Add(item);
            }
        }
        return ordered;
    }
}
