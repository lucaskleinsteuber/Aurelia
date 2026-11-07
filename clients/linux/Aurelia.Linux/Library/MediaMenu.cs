using Aurelia.Contracts;
using Aurelia.Linux.Core.Library;
using Avalonia.Controls;

namespace Aurelia.Linux.Library;

/// <summary>
/// The context menu on every title, in the Mac app's order: Play, Resume, Go to Series, Mark as
/// Watched/Unwatched (with season and series variants), Favorites, Watchlist, Add to Collection and
/// Continue Watching, then Edit Metadata and Remove from Library for administrators. It is built
/// when it opens, so it always shows the current state.
/// </summary>
internal static class MediaMenu
{
    public static ContextMenu For(LibraryContext context, CatalogItemSummary item)
    {
        var menu = new ContextMenu();
        menu.Opening += (_, _) => menu.ItemsSource = Items(context, item);
        menu.ItemsSource = Items(context, item);
        return menu;
    }

    internal static List<Control> Items(LibraryContext context, CatalogItemSummary item, bool onDetail = false)
    {
        var store = context.Store;
        var items = new List<Control>();
        // On a detail page Play, Favorites, Watchlist and the season choices are buttons beside
        // the menu already, so it keeps only what has no button there.
        if (LibraryPresentation.IsPlayable(item) && !onDetail)
        {
            items.Add(Item("Play", () => context.Play(item, resume: false)));
            if (item.Progress is { IsCompleted: false, PositionMilliseconds: > 0 }) items.Add(Item("Resume", () => context.Play(item, resume: true)));
        }
        if (item.Kind == MediaKind.Episode && item.ParentId is { } seriesId)
        {
            items.Add(Item("Go to Series", () =>
            {
                var series = store.Catalog.FirstOrDefault(candidate => candidate.Id == seriesId);
                if (series is not null) context.OpenDetail(series);
            }));
        }
        items.Add(new Separator());
        var watched = item.WatchState == CatalogWatchState.Completed;
        items.Add(Item(watched ? "Mark as Unwatched" : "Mark as Watched", () => _ = MarkAsync(context, item.Id, WatchStateScope.Title, !watched)));
        // Season and series changes are made on the series itself, also from one of its episodes.
        var series = item.Kind == MediaKind.Series ? item.Id : item.Kind == MediaKind.Episode ? item.ParentId : null;
        if (onDetail && item.Kind == MediaKind.Series) series = null;
        if (item.Kind == MediaKind.Episode && item.SeasonNumber is { } season && series is { } parent)
        {
            items.Add(Item("Mark Season as Watched", () => _ = MarkAsync(context, parent, WatchStateScope.Season, true, season)));
            items.Add(Item("Mark Season as Unwatched", () => _ = MarkAsync(context, parent, WatchStateScope.Season, false, season)));
        }
        if (series is { } seriesToMark)
        {
            items.Add(Item("Mark Series as Watched", () => _ = MarkAsync(context, seriesToMark, WatchStateScope.Series, true)));
            items.Add(Item("Mark Series as Unwatched", () => _ = MarkAsync(context, seriesToMark, WatchStateScope.Series, false)));
        }
        items.Add(new Separator());
        if (item.Kind is MediaKind.Movie or MediaKind.Series && !onDetail)
        {
            items.Add(Item(item.IsFavorite ? "Remove from Favorites" : "Add to Favorites", () => _ = store.SetFavoriteAsync(item, !item.IsFavorite)));
        }
        if (store.Client.SupportsWatchlist && item.Kind is MediaKind.Movie or MediaKind.Series && !onDetail)
        {
            var listed = store.IsWatchlisted(item.Id);
            items.Add(Item(listed ? "Remove from Watchlist" : "Add to Watchlist", () => _ = store.SetWatchlistAsync(item.Id, !listed)));
        }
        items.Add(CollectionsMenu(context, item));
        if (item.Progress is { PositionMilliseconds: > 0 } || item.ContinueWatchingHidden)
        {
            items.Add(Item(item.ContinueWatchingHidden ? "Show in Continue Watching" : "Remove from Continue Watching",
                () => _ = store.SetContinueWatchingHiddenAsync(item.Id, !item.ContinueWatchingHidden)));
        }
        if (context.Navigator.Downloads is { } downloads && item.Kind is MediaKind.Movie or MediaKind.Episode)
        {
            items.Add(new Separator());
            if (downloads.Active.TryGetValue(item.Id, out var share))
                items.Add(Item($"Cancel Download ({(int)(share * 100)} %)", () => downloads.Cancel(item.Id)));
            else if (downloads.Find(item.Id) is not null)
                items.Add(Item("Remove Download", () => downloads.Remove(item.Id)));
            else if (LibraryPresentation.IsPlayable(item))
                items.Add(Item("Download", () => context.Navigator.Download(item)));
        }
        // Owners and administrators edit and remove titles; media files are never changed.
        if (store.CanManageMedia && item.Kind is MediaKind.Movie or MediaKind.Series or MediaKind.Episode)
        {
            items.Add(new Separator());
            items.Add(Item("Edit Metadata…", () => _ = context.Navigator.ManageTitleAsync(item, TitleAction.EditMetadata)));
            if (onDetail) items.Add(Item("Find Metadata Match…", () => _ = context.Navigator.ManageTitleAsync(item, TitleAction.FindMatch)));
            items.Add(Item("Remove from Library…", () => _ = context.Navigator.ManageTitleAsync(item, TitleAction.Remove)));
        }
        return Tidy(items);
    }

    /// <summary>No separator at the start, at the end or twice in a row.</summary>
    private static List<Control> Tidy(List<Control> items)
    {
        var tidy = new List<Control>();
        foreach (var item in items)
        {
            if (item is Separator && (tidy.Count == 0 || tidy[^1] is Separator)) continue;
            tidy.Add(item);
        }
        while (tidy.Count > 0 && tidy[^1] is Separator) tidy.RemoveAt(tidy.Count - 1);
        return tidy;
    }

    /// <summary>Season and series changes say how many episodes they touch and ask first, as on the Mac.</summary>
    internal static async Task MarkAsync(LibraryContext context, Guid mediaId, WatchStateScope scope, bool watched, int? season = null)
    {
        var state = await context.Store.WatchStateAsync(mediaId, scope, season);
        if (state is null) return;
        if (scope != WatchStateScope.Title)
        {
            var count = state.AffectedCount;
            var what = count == 1 ? "1 episode" : $"{count} episodes";
            var confirmed = await context.Navigator.ConfirmAsync(
                watched ? $"Mark {what} as watched?" : $"Mark {what} as unwatched?",
                scope == WatchStateScope.Season ? $"This changes every episode of season {season}." : "This changes every episode of the series.",
                watched ? "Mark as Watched" : "Mark as Unwatched",
                destructive: false);
            if (!confirmed) return;
        }
        await context.Store.SetWatchedAsync(state, watched);
    }

    private static MenuItem CollectionsMenu(LibraryContext context, CatalogItemSummary item)
    {
        var store = context.Store;
        var menu = new MenuItem { Header = "Add to Collection" };
        var children = new List<Control>();
        foreach (var collection in store.Collections.Where(c => !c.IsSmart && (c.UserId == store.Client.Profile.User.Id || (c.IsShared && store.CanManageMedia))))
        {
            var contains = collection.Items.Any(candidate => candidate.Id == item.Id);
            var entry = new MenuItem { Header = collection.Name, ToggleType = MenuItemToggleType.CheckBox, IsChecked = contains };
            entry.Click += (_, _) => _ = contains ? store.RemoveFromCollectionAsync(collection.Id, item.Id) : store.AddToCollectionAsync(collection.Id, item.Id);
            children.Add(entry);
        }
        if (children.Count > 0) children.Add(new Separator());
        children.Add(Item("New Collection…", () => context.Navigator.EditCollection(null, item)));
        menu.ItemsSource = children;
        return menu;
    }

    private static MenuItem Item(string header, Action action)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => action();
        return item;
    }
}
