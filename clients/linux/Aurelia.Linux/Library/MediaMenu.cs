using Aurelia.Contracts;
using Aurelia.Linux.Core.Library;
using Avalonia.Controls;

namespace Aurelia.Linux.Library;

/// <summary>
/// The context menu on every title, in the Mac app's order: Play, Resume, Go to Series, Mark as
/// Watched/Unwatched (with season and series variants), Favorites, Watchlist, Add to Collection and
/// Continue Watching. It is built when it opens, so it always shows the current state.
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

    internal static List<Control> Items(LibraryContext context, CatalogItemSummary item)
    {
        var store = context.Store;
        var items = new List<Control>();
        if (LibraryPresentation.IsPlayable(item))
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
        if (item.Kind is MediaKind.Movie or MediaKind.Series)
        {
            items.Add(Item(item.IsFavorite ? "Remove from Favorites" : "Add to Favorites", () => _ = store.SetFavoriteAsync(item, !item.IsFavorite)));
        }
        if (store.Client.SupportsWatchlist && item.Kind is MediaKind.Movie or MediaKind.Series)
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
        return items;
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
