using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Library;

/// <summary>
/// What the open profile sees of the library: Home, every title (for genre rows, filters and the
/// collection editor), collections and the watchlist. Pages read from here and call its actions;
/// after a change it reloads what the change touched and raises <see cref="Changed"/>. When the
/// server refuses the profile, <paramref name="onSessionFailure"/> returns the app to the picker.
/// </summary>
public sealed class LibraryStore(LibraryClient client, ArtworkCache artwork, GeneralPreferences preferences, Action<AureliaApiException> onSessionFailure)
    : ObservableObject
{
    private const int BrowseCacheSize = 24;
    private readonly Dictionary<(BrowseSection, BrowseQuery, string), IReadOnlyList<CatalogItemSummary>> browseCache = [];
    private readonly LinkedList<(BrowseSection, BrowseQuery, string)> browseOrder = new();
    private HomeResponse? home;
    private IReadOnlyList<CatalogItemSummary> catalog = [];
    private IReadOnlyList<CollectionSummary> collections = [];
    private HashSet<Guid> watchlist = [];
    private bool isLoading;
    private string? error;
    private long revision;

    /// <summary>Raised after any data changed, so pages reload what they show.</summary>
    public event Action? Changed;

    public LibraryClient Client { get; } = client;

    public ArtworkCache Artwork { get; } = artwork;

    public GeneralPreferences Preferences { get; } = preferences;

    public HomeResponse? Home
    {
        get => home;
        private set => SetProperty(ref home, value);
    }

    public IReadOnlyList<CatalogItemSummary> Catalog
    {
        get => catalog;
        private set => SetProperty(ref catalog, value);
    }

    public IReadOnlyList<CollectionSummary> Collections
    {
        get => collections;
        private set => SetProperty(ref collections, value);
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

    /// <summary>Counts changes; pages compare it to know whether to reload.</summary>
    public long Revision
    {
        get => revision;
        private set => SetProperty(ref revision, value);
    }

    public bool CanManageMedia => Client.Profile.CanManageMedia;

    public bool IsWatchlisted(Guid mediaId) => watchlist.Contains(mediaId);

    /// <summary>Loads Home, the catalog, collections and the watchlist together.</summary>
    public async Task RefreshAsync()
    {
        IsLoading = true;
        try
        {
            var homeTask = Client.HomeAsync(CancellationToken.None);
            var catalogTask = Client.BrowseAsync(new BrowseQuery(), null, CancellationToken.None);
            var collectionsTask = Client.CollectionsAsync(CancellationToken.None);
            var watchlistTask = Client.SupportsWatchlist ? Client.WatchlistAsync(CancellationToken.None) : Task.FromResult<WatchlistResponse?>(null)!;
            await Task.WhenAll(homeTask, catalogTask, collectionsTask, watchlistTask);
            Home = homeTask.Result;
            Catalog = catalogTask.Result;
            Collections = collectionsTask.Result;
            if (watchlistTask.Result is { } list) watchlist = [.. list.MediaIds];
            Error = null;
            ClearBrowseCache();
            NotifyChanged();
        }
        catch (AureliaApiException failure)
        {
            Report(failure);
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task RefreshHomeAsync()
    {
        try
        {
            Home = await Client.HomeAsync(CancellationToken.None);
            NotifyChanged();
        }
        catch (AureliaApiException failure)
        {
            Report(failure);
        }
    }

    public async Task RefreshCollectionsAsync()
    {
        try
        {
            Collections = await Client.CollectionsAsync(CancellationToken.None);
            NotifyChanged();
        }
        catch (AureliaApiException failure)
        {
            Report(failure);
        }
    }

    public async Task RefreshWatchlistAsync()
    {
        if (!Client.SupportsWatchlist) return;
        try
        {
            watchlist = [.. (await Client.WatchlistAsync(CancellationToken.None)).MediaIds];
            NotifyChanged();
        }
        catch (AureliaApiException failure)
        {
            Report(failure);
        }
    }

    /// <summary>A page's list, from the cache when it is known (shown at once) and then reloaded.</summary>
    public IReadOnlyList<CatalogItemSummary>? CachedBrowse(BrowseSection section, BrowseQuery query, string search) =>
        browseCache.GetValueOrDefault((section, query, search.Trim()));

    public async Task<IReadOnlyList<CatalogItemSummary>> BrowseAsync(BrowseSection section, BrowseQuery query, string search, CancellationToken cancellation)
    {
        var items = await Client.BrowseAsync(query, search, cancellation);
        var key = (section, query, search.Trim());
        if (browseCache.ContainsKey(key)) browseOrder.Remove(key);
        browseCache[key] = items;
        browseOrder.AddFirst(key);
        while (browseOrder.Count > BrowseCacheSize)
        {
            browseCache.Remove(browseOrder.Last!.Value);
            browseOrder.RemoveLast();
        }
        return items;
    }

    public Task<bool> SetFavoriteAsync(CatalogItemSummary item, bool favorite) =>
        MutateAsync(() => Client.SetFavoriteAsync(item.Id, favorite, CancellationToken.None), reloadCatalog: true);

    public async Task<bool> SetWatchlistAsync(Guid mediaId, bool watchlisted)
    {
        try
        {
            var state = await Client.SetWatchlistAsync(mediaId, watchlisted, CancellationToken.None);
            if (state.IsWatchlisted) watchlist.Add(mediaId);
            else watchlist.Remove(mediaId);
            NotifyChanged();
            return true;
        }
        catch (AureliaApiException failure)
        {
            Report(failure);
            return false;
        }
    }

    /// <summary>Reads how many episodes a watched/unwatched change would touch, for the confirmation.</summary>
    public async Task<WatchStateResponse?> WatchStateAsync(Guid mediaId, WatchStateScope scope, int? seasonNumber)
    {
        try
        {
            return await Client.WatchStateAsync(mediaId, scope, seasonNumber, CancellationToken.None);
        }
        catch (AureliaApiException failure)
        {
            Report(failure);
            return null;
        }
    }

    public Task<bool> SetWatchedAsync(WatchStateResponse state, bool watched) =>
        MutateAsync(() => Client.SetWatchStateAsync(state.MediaId,
            new SetWatchStateRequest(watched, state.Scope, state.SeasonNumber, state.StateToken, Guid.NewGuid()), CancellationToken.None), reloadCatalog: true);

    /// <summary>"Show in / Remove from Continue Watching".</summary>
    public async Task<bool> SetContinueWatchingHiddenAsync(Guid mediaId, bool hidden)
    {
        var state = await WatchStateAsync(mediaId, WatchStateScope.Title, null);
        if (state is null) return false;
        return await MutateAsync(() => Client.SetContinueWatchingAsync(mediaId,
            new SetContinueWatchingRequest(hidden, state.StateToken, Guid.NewGuid()), CancellationToken.None), reloadCatalog: false);
    }

    public Task<bool> AddToCollectionAsync(Guid collectionId, Guid mediaId) =>
        MutateAsync(() => Client.AddToCollectionAsync(collectionId, mediaId, CancellationToken.None), reloadCatalog: false, reloadCollections: true);

    public Task<bool> RemoveFromCollectionAsync(Guid collectionId, Guid mediaId) =>
        MutateAsync(() => Client.RemoveFromCollectionAsync(collectionId, mediaId, CancellationToken.None), reloadCatalog: false, reloadCollections: true);

    public async Task<CollectionSummary?> SaveCollectionAsync(Guid? id, SaveCollectionRequest request)
    {
        try
        {
            var saved = id is { } existing
                ? await Client.UpdateCollectionAsync(existing, request, CancellationToken.None)
                : await Client.CreateCollectionAsync(request, CancellationToken.None);
            await RefreshCollectionsAsync();
            await RefreshHomeAsync();
            return saved;
        }
        catch (AureliaApiException failure)
        {
            Report(failure);
            return null;
        }
    }

    public Task<bool> DeleteCollectionAsync(Guid id) =>
        MutateAsync(() => Client.DeleteCollectionAsync(id, CancellationToken.None), reloadCatalog: false, reloadCollections: true);

    public async Task<CollectionSummary?> SaveFranchiseAsync(Guid franchiseId)
    {
        try
        {
            var saved = await Client.SaveFranchiseAsync(franchiseId, CancellationToken.None);
            await RefreshCollectionsAsync();
            return saved;
        }
        catch (AureliaApiException failure)
        {
            Report(failure);
            return null;
        }
    }

    /// <summary>Applies changes reported by the sync loop: a full reload, or Home plus the changed titles.</summary>
    public async Task ApplyChangesAsync(SyncChangesResponse changes)
    {
        var areas = changes.ChangedAreas;
        var full = changes.ResetRequired || areas.Contains(SyncChangeArea.Catalog) || areas.Contains(SyncChangeArea.Libraries)
            || changes.ChangedMediaIds.Count > 32
            || ((areas.Contains(SyncChangeArea.Metadata) || areas.Contains(SyncChangeArea.UserState)) && changes.ChangedMediaIds.Count == 0);
        if (full)
        {
            await RefreshAsync();
            return;
        }
        try
        {
            Home = await Client.HomeAsync(CancellationToken.None);
            if (changes.ChangedMediaIds.Count > 0)
            {
                var updated = Catalog.ToDictionary(item => item.Id);
                foreach (var id in changes.ChangedMediaIds)
                {
                    try
                    {
                        updated[id] = await Client.SummaryAsync(id, CancellationToken.None);
                    }
                    catch (AureliaApiException missing) when (missing.Status == 404)
                    {
                        await RefreshAsync();
                        return;
                    }
                }
                Catalog = [.. Catalog.Select(item => updated[item.Id])];
            }
            if (areas.Contains(SyncChangeArea.Collections)) Collections = await Client.CollectionsAsync(CancellationToken.None);
            if (areas.Contains(SyncChangeArea.UserState) && Client.SupportsWatchlist)
                watchlist = [.. (await Client.WatchlistAsync(CancellationToken.None)).MediaIds];
            ClearBrowseCache();
            NotifyChanged();
        }
        catch (AureliaApiException failure)
        {
            Report(failure);
        }
    }

    /// <summary>Shows a failure to the person, or returns to the profile picker when the server refused the profile.</summary>
    public void Report(AureliaApiException failure)
    {
        if (failure.IsAuthenticationFailure || failure.Code is "profile_session_expired" or "profile_session_revoked" or "device_session_revoked")
        {
            onSessionFailure(failure);
            return;
        }
        Error = failure.Message;
    }

    public void ClearError() => Error = null;

    private async Task<bool> MutateAsync(Func<Task> change, bool reloadCatalog, bool reloadCollections = false)
    {
        try
        {
            await change();
            var tasks = new List<Task> { RefreshHomeAsync() };
            if (reloadCatalog) tasks.Add(ReloadCatalogAsync());
            if (reloadCollections) tasks.Add(RefreshCollectionsAsync());
            await Task.WhenAll(tasks);
            ClearBrowseCache();
            NotifyChanged();
            return true;
        }
        catch (AureliaApiException failure)
        {
            Report(failure);
            return false;
        }
    }

    private async Task ReloadCatalogAsync() => Catalog = await Client.BrowseAsync(new BrowseQuery(), null, CancellationToken.None);

    private void ClearBrowseCache()
    {
        browseCache.Clear();
        browseOrder.Clear();
    }

    private void NotifyChanged()
    {
        Revision++;
        Changed?.Invoke();
    }
}
