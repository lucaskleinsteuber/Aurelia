using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Library;

/// <summary>
/// A library page's list (Library, Movies, TV Shows, Recently Added), as on the Mac: filters and
/// sort are remembered per server, profile and page; search waits 220 ms after typing; a list known
/// from before shows at once and is refreshed quietly; an older request never replaces a newer one.
/// </summary>
public sealed class BrowseModel : ObservableObject
{
    public static readonly TimeSpan SearchDelay = TimeSpan.FromMilliseconds(220);

    private readonly LibraryStore store;
    private readonly TimeProvider time;
    private BrowseQuery query;
    private string search = "";
    private IReadOnlyList<CatalogItemSummary> items = [];
    private bool isLoading;
    private string? error;
    private int generation;

    public BrowseModel(LibraryStore store, BrowseSection section, TimeProvider? time = null)
    {
        this.store = store;
        this.time = time ?? TimeProvider.System;
        Section = section;
        query = store.Preferences.BrowseQuery(store.Client.Server.ServerId, store.Client.Profile.User.Id, section);
    }

    public BrowseSection Section { get; }

    public BrowseQuery Query
    {
        get => query;
        set
        {
            var constrained = value.ConstrainedTo(Section);
            if (!SetProperty(ref query, constrained)) return;
            store.Preferences.SaveBrowseQuery(store.Client.Server.ServerId, store.Client.Profile.User.Id, Section, constrained);
            _ = LoadAsync();
        }
    }

    public string Search
    {
        get => search;
        set
        {
            if (!SetProperty(ref search, value ?? "")) return;
            _ = LoadAsync(debounce: true);
        }
    }

    public IReadOnlyList<CatalogItemSummary> Items
    {
        get => items;
        private set => SetProperty(ref items, value);
    }

    public bool IsLoading
    {
        get => isLoading;
        private set => SetProperty(ref isLoading, value);
    }

    public string? Error
    {
        get => error;
        private set => SetProperty(ref error, value);
    }

    public bool IsSearching => Search.Trim().Length > 0;

    /// <summary>Every genre in the library, for the genre filter.</summary>
    public IReadOnlyList<string> Genres => [.. store.Catalog.SelectMany(item => item.Genres).Select(g => g.Trim()).Where(g => g.Length > 0)
        .Distinct(StringComparer.CurrentCultureIgnoreCase).Order(StringComparer.CurrentCultureIgnoreCase)];

    /// <summary>The release years in the library, newest first, for the year filter.</summary>
    public IReadOnlyList<int> Years => [.. store.Catalog.Select(item => item.Year).OfType<int>().Distinct().OrderDescending()];

    public void ClearFilters() => Query = Query with { FavoritesOnly = false, Genre = null, YearFrom = null, YearTo = null, WatchState = null };

    public async Task LoadAsync(bool debounce = false, bool quietly = false)
    {
        var request = ++generation;
        var text = Search.Trim();
        if (!quietly && store.CachedBrowse(Section, Query, text) is { } known)
        {
            Items = known;
            Error = null;
            quietly = true;
        }
        IsLoading = true;
        try
        {
            if (debounce && text.Length > 0) await Task.Delay(SearchDelay, time);
            if (request != generation) return;
            var result = await store.BrowseAsync(Section, Query, text, CancellationToken.None);
            if (request != generation) return;
            Items = result;
            Error = null;
        }
        catch (AureliaApiException failure)
        {
            if (request != generation) return;
            if (failure.IsAuthenticationFailure)
            {
                store.Report(failure);
                return;
            }
            if (!quietly)
            {
                Items = [];
                Error = failure.Message;
            }
        }
        finally
        {
            if (request == generation) IsLoading = false;
        }
    }
}
