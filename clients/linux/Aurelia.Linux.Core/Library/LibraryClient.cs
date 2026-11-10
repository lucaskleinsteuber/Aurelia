using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;

namespace Aurelia.Linux.Core.Library;

/// <summary>
/// The library endpoints for the open watching profile: Home, catalog pages, details, collections,
/// watchlist, favorites, watch state, history, statistics, artwork and sync. Every call carries the
/// profile's token over the pinned connection.
/// </summary>
public sealed class LibraryClient(AureliaApi api, StoredServer server, ProfileSession profile, IReadOnlyCollection<string> capabilities)
    : Aurelia.Linux.Core.Playback.IMovieNightApi
{
    public const int DefaultPageSize = 100;
    public const int LargePageSize = 500;

    public StoredServer Server { get; } = server;

    public ProfileSession Profile { get; } = profile;

    public bool Supports(string capability) => capabilities.Contains(capability);

    public bool SupportsWatchlist => Supports("watchlist-people-v1");

    public bool SupportsArtworkVariants => Supports("artwork-variants-v1");

    public bool SupportsMovieNight => Supports(ServerFeatures.MovieNight);

    public bool SupportsWrapped => Supports(ServerFeatures.YearWrapped);

    public bool SupportsMonthlyWrapped => Supports(ServerFeatures.MonthlyWrapped);

    public Task<HomeResponse> HomeAsync(CancellationToken cancellation) => Get<HomeResponse>("/api/v1/home", cancellation);

    /// <summary>
    /// Every title for a query, page by page (100, or 500 when the server allows it). When the
    /// library changes while loading ("catalog_changed", or a new revision or total), it starts
    /// again, up to three times, so a list never mixes two states of the library.
    /// </summary>
    public async Task<IReadOnlyList<CatalogItemSummary>> BrowseAsync(BrowseQuery query, string? search, CancellationToken cancellation)
    {
        var path = string.IsNullOrWhiteSpace(search) ? "/api/v1/catalog/items" : "/api/v1/catalog/search";
        var pageSize = Supports("catalog-pages-500-v1") ? LargePageSize : DefaultPageSize;
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                return await LoadAllPagesAsync(path, query.Parameters(search).ToList(), pageSize, cancellation);
            }
            catch (AureliaApiException error) when (error.Code == "catalog_changed" && attempt < 2)
            {
            }
        }
    }

    public Task<CatalogDetailPresentation> DetailAsync(Guid mediaId, CancellationToken cancellation) =>
        Get<CatalogDetailPresentation>($"/api/v1/catalog/items/{mediaId}", cancellation);

    public Task<CatalogItemSummary> SummaryAsync(Guid mediaId, CancellationToken cancellation) =>
        Get<CatalogItemSummary>($"/api/v1/catalog/items/{mediaId}/summary", cancellation);

    public Task<PersonDetailResponse> PersonAsync(string name, string? personKey, CancellationToken cancellation)
    {
        var query = "name=" + Uri.EscapeDataString(name) + (personKey is { Length: > 0 } key ? "&personKey=" + Uri.EscapeDataString(key) : "");
        return Get<PersonDetailResponse>("/api/v1/catalog/person?" + query, cancellation);
    }

    public Task<IReadOnlyList<CollectionSummary>> CollectionsAsync(CancellationToken cancellation) =>
        Get<IReadOnlyList<CollectionSummary>>("/api/v1/catalog/collections?offset=0&limit=200", cancellation);

    /// <summary>Film series found in the library (GET /api/v1/catalog/franchises).</summary>
    public Task<IReadOnlyList<CollectionSummary>> FranchisesAsync(CancellationToken cancellation) =>
        Get<IReadOnlyList<CollectionSummary>>("/api/v1/catalog/franchises?offset=0&limit=100", cancellation);

    public Task<CollectionSummary> SaveFranchiseAsync(Guid franchiseId, CancellationToken cancellation) =>
        Send<CollectionSummary>(HttpMethod.Post, $"/api/v1/collections/from-franchise/{franchiseId}", null, cancellation);

    public Task<CollectionSummary> CreateCollectionAsync(SaveCollectionRequest request, CancellationToken cancellation) =>
        Send<CollectionSummary>(HttpMethod.Post, "/api/v1/collections", request, cancellation);

    public Task<CollectionSummary> UpdateCollectionAsync(Guid id, SaveCollectionRequest request, CancellationToken cancellation) =>
        Send<CollectionSummary>(HttpMethod.Put, $"/api/v1/collections/{id}", request, cancellation);

    public Task DeleteCollectionAsync(Guid id, CancellationToken cancellation) =>
        Send<AureliaApi.NoContent>(HttpMethod.Delete, $"/api/v1/collections/{id}", null, cancellation);

    public Task AddToCollectionAsync(Guid collectionId, Guid mediaId, CancellationToken cancellation) =>
        Send<AureliaApi.NoContent>(HttpMethod.Post, $"/api/v1/collections/{collectionId}/items/{mediaId}", null, cancellation);

    public Task RemoveFromCollectionAsync(Guid collectionId, Guid mediaId, CancellationToken cancellation) =>
        Send<AureliaApi.NoContent>(HttpMethod.Delete, $"/api/v1/collections/{collectionId}/items/{mediaId}", null, cancellation);

    public Task<WatchlistResponse> WatchlistAsync(CancellationToken cancellation) => Get<WatchlistResponse>("/api/v1/watchlist", cancellation);

    public Task<WatchlistItemStateResponse> SetWatchlistAsync(Guid mediaId, bool watchlisted, CancellationToken cancellation) =>
        Send<WatchlistItemStateResponse>(HttpMethod.Put, $"/api/v1/media/{mediaId}/watchlist", new SetWatchlistRequest(watchlisted), cancellation);

    public Task SetFavoriteAsync(Guid mediaId, bool favorite, CancellationToken cancellation) =>
        Send<AureliaApi.NoContent>(HttpMethod.Put, $"/api/v1/media/{mediaId}/favorite", new SetFavoriteRequest(favorite), cancellation);

    public Task<PlaybackPlanResponse> PlaybackPlanAsync(Guid mediaId, CancellationToken cancellation) =>
        Get<PlaybackPlanResponse>($"/api/v1/media/{mediaId}/playback-plan", cancellation);

    public Task<WatchStateResponse> WatchStateAsync(Guid mediaId, WatchStateScope scope, int? seasonNumber, CancellationToken cancellation) =>
        Get<WatchStateResponse>($"/api/v1/media/{mediaId}/watch-state?scope={ScopeName(scope)}"
            + (seasonNumber is { } season ? "&seasonNumber=" + season.ToString(CultureInfo.InvariantCulture) : ""), cancellation);

    public Task<WatchStateResponse> SetWatchStateAsync(Guid mediaId, SetWatchStateRequest request, CancellationToken cancellation) =>
        Send<WatchStateResponse>(HttpMethod.Put, $"/api/v1/media/{mediaId}/watch-state", request, cancellation);

    public Task<WatchStateResponse> SetContinueWatchingAsync(Guid mediaId, SetContinueWatchingRequest request, CancellationToken cancellation) =>
        Send<WatchStateResponse>(HttpMethod.Put, $"/api/v1/media/{mediaId}/continue-watching", request, cancellation);

    public Task<WatchHistoryPage> HistoryAsync(int offset, int limit, CancellationToken cancellation) =>
        Get<WatchHistoryPage>($"/api/v1/history?offset={offset}&limit={limit}", cancellation);

    public Task RemoveHistoryEntryAsync(Guid id, CancellationToken cancellation) =>
        Send<AureliaApi.NoContent>(HttpMethod.Delete, $"/api/v1/history/{id}", null, cancellation);

    public Task ClearHistoryAsync(CancellationToken cancellation) =>
        Send<AureliaApi.NoContent>(HttpMethod.Delete, "/api/v1/history", null, cancellation);

    public Task<UserStatistics> StatisticsAsync(CancellationToken cancellation) => Get<UserStatistics>("/api/v1/statistics", cancellation);

    public Task<YearInReview> YearInReviewAsync(int year, CancellationToken cancellation) =>
        Get<YearInReview>($"/api/v1/statistics/year/{year}", cancellation);

    /// <summary>A year's Wrapped, or with <paramref name="month"/> one month's.</summary>
    public Task<YearWrapped> WrappedAsync(int year, int? month, CancellationToken cancellation) =>
        Get<YearWrapped>(month is { } m ? $"/api/v1/statistics/year/{year}/month/{m}/wrapped" : $"/api/v1/statistics/year/{year}/wrapped", cancellation);

    /// <summary>GET /api/v1/sync/changes: waits up to <paramref name="waitSeconds"/> for the library to change after the cursor.</summary>
    public Task<SyncChangesResponse> ChangesAsync(long after, int waitSeconds, string? generation, CancellationToken cancellation)
    {
        var path = $"/api/v1/sync/changes?after={after}&waitSeconds={waitSeconds}" + (generation is { Length: > 0 } g ? "&generation=" + Uri.EscapeDataString(g) : "");
        return Get<SyncChangesResponse>(path, cancellation, TimeSpan.FromSeconds(waitSeconds + 5));
    }

    /// <summary>
    /// Artwork bytes. The width (320, 640, 1280 or 1920) is sent only when the server offers
    /// sized artwork and the artwork has a revision; otherwise the stored original comes back.
    /// </summary>
    public async Task<byte[]> ArtworkAsync(ArtworkSummary artwork, int? width, CancellationToken cancellation)
    {
        var path = $"/api/v1/artwork/{artwork.Id}";
        if (width is { } requested && SupportsArtworkVariants && artwork.Revision is not null) path += "?width=" + requested.ToString(CultureInfo.InvariantCulture);
        using var request = new HttpRequestMessage(HttpMethod.Get, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Profile.Token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("image/*"));
        HttpResponseMessage response;
        try
        {
            response = await api.Pinned(Server.Address, Server.Fingerprint).SendAsync(request, cancellation);
        }
        catch (HttpRequestException)
        {
            throw AureliaApiException.Unreachable();
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode) throw await AureliaApi.ProblemAsync(response, cancellation);
            return await response.Content.ReadAsByteArrayAsync(cancellation);
        }
    }

    private async Task<IReadOnlyList<CatalogItemSummary>> LoadAllPagesAsync(string path, List<KeyValuePair<string, string>> parameters,
        int pageSize, CancellationToken cancellation)
    {
        var items = new List<CatalogItemSummary>();
        var seen = new HashSet<Guid>();
        string? revision = null;
        int? total = null;
        while (true)
        {
            var query = parameters.Select(p => p.Key + "=" + Uri.EscapeDataString(p.Value))
                .Append("offset=" + items.Count.ToString(CultureInfo.InvariantCulture))
                .Append("limit=" + pageSize.ToString(CultureInfo.InvariantCulture));
            if (revision is not null) query = query.Append("revision=" + Uri.EscapeDataString(revision));
            var page = await Get<PagedResponse<CatalogItemSummary>>(path + "?" + string.Join('&', query), cancellation);
            if (page.Offset != items.Count || (total is { } known && known != page.Total) || (revision is not null && page.Revision != revision))
                throw new AureliaApiException(409, "catalog_changed", "The library changed while loading.");
            revision ??= page.Revision;
            total ??= page.Total;
            foreach (var item in page.Items)
            {
                if (!seen.Add(item.Id)) throw new AureliaApiException(409, "catalog_changed", "The library changed while loading.");
                items.Add(item);
            }
            if (items.Count >= page.Total || page.Items.Count == 0) return items;
        }
    }

    // Watch Together.
    public Task<IReadOnlyList<WatchPartySummary>> WatchPartiesAsync(CancellationToken cancellation) =>
        Get<IReadOnlyList<WatchPartySummary>>("/api/v1/watch-together", cancellation);

    public Task<WatchPartyState> CreateWatchPartyAsync(CreateWatchPartyRequest request, CancellationToken cancellation) =>
        Send<WatchPartyState>(HttpMethod.Post, "/api/v1/watch-together", request, cancellation);

    public Task<WatchPartyState> JoinWatchPartyAsync(Guid partyId, JoinWatchPartyRequest request, CancellationToken cancellation) =>
        Send<WatchPartyState>(HttpMethod.Post, $"/api/v1/watch-together/{partyId}/join", request, cancellation);

    /// <summary>The party once its revision is newer than <paramref name="after"/>, or after the wait.</summary>
    public Task<WatchPartyState> WatchPartyAsync(Guid partyId, long? after, int waitMilliseconds, CancellationToken cancellation) =>
        Get<WatchPartyState>(after is { } revision
            ? $"/api/v1/watch-together/{partyId}?after={revision.ToString(System.Globalization.CultureInfo.InvariantCulture)}&waitMs={waitMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture)}"
            : $"/api/v1/watch-together/{partyId}", cancellation, TimeSpan.FromMilliseconds(waitMilliseconds + 10_000));

    public Task<WatchPartyState> WatchPartyCommandAsync(Guid partyId, WatchPartyCommandRequest request, CancellationToken cancellation) =>
        Send<WatchPartyState>(HttpMethod.Post, $"/api/v1/watch-together/{partyId}/commands", request, cancellation);

    public Task LeaveWatchPartyAsync(Guid partyId, CancellationToken cancellation) =>
        Send<AureliaApi.NoContent>(HttpMethod.Delete, $"/api/v1/watch-together/{partyId}/members/me", null, cancellation);

    // Movie Night.
    public Task<IReadOnlyList<MovieNightSummary>> MovieNightsAsync(CancellationToken cancellation) =>
        Get<IReadOnlyList<MovieNightSummary>>("/api/v1/movie-night", cancellation);

    public Task<MovieNightState> CreateMovieNightAsync(CreateMovieNightRequest request, CancellationToken cancellation) =>
        Send<MovieNightState>(HttpMethod.Post, "/api/v1/movie-night", request, cancellation);

    public Task<MovieNightState> JoinMovieNightAsync(Guid nightId, JoinMovieNightRequest request, CancellationToken cancellation) =>
        Send<MovieNightState>(HttpMethod.Post, $"/api/v1/movie-night/{nightId}/join", request, cancellation);

    /// <summary>The night once its revision is newer than <paramref name="after"/>, or after the wait.</summary>
    public Task<MovieNightState> MovieNightAsync(Guid nightId, long? after, int? deckVersion, int waitMilliseconds, CancellationToken cancellation) =>
        Get<MovieNightState>(after is { } revision
            ? $"/api/v1/movie-night/{nightId}?after={revision.ToString(CultureInfo.InvariantCulture)}&waitMs={waitMilliseconds.ToString(CultureInfo.InvariantCulture)}"
              + (deckVersion is { } known ? "&deckVersion=" + known.ToString(CultureInfo.InvariantCulture) : "")
            : $"/api/v1/movie-night/{nightId}", cancellation, TimeSpan.FromMilliseconds(waitMilliseconds + 10_000));

    public Task<MovieNightState> MovieNightSettingsAsync(Guid nightId, MovieNightSettingsRequest request, CancellationToken cancellation) =>
        Send<MovieNightState>(HttpMethod.Post, $"/api/v1/movie-night/{nightId}/settings", request, cancellation);

    public Task<MovieNightState> DealMovieNightAsync(Guid nightId, CancellationToken cancellation) =>
        Send<MovieNightState>(HttpMethod.Post, $"/api/v1/movie-night/{nightId}/deal", new { }, cancellation);

    public Task<MovieNightState> VoteMovieNightAsync(Guid nightId, MovieNightVoteRequest request, CancellationToken cancellation) =>
        Send<MovieNightState>(HttpMethod.Post, $"/api/v1/movie-night/{nightId}/votes", request, cancellation);

    public Task<MovieNightState> KeepSwipingAsync(Guid nightId, CancellationToken cancellation) =>
        Send<MovieNightState>(HttpMethod.Post, $"/api/v1/movie-night/{nightId}/keep-swiping", new { }, cancellation);

    public Task<MovieNightState> MovieNightRoleAsync(Guid nightId, MovieNightRoleRequest request, CancellationToken cancellation) =>
        Send<MovieNightState>(HttpMethod.Post, $"/api/v1/movie-night/{nightId}/role", request, cancellation);

    public Task LeaveMovieNightAsync(Guid nightId, CancellationToken cancellation) =>
        Send<AureliaApi.NoContent>(HttpMethod.Delete, $"/api/v1/movie-night/{nightId}/members/me", null, cancellation);

    private static string ScopeName(WatchStateScope scope) => scope switch
    {
        WatchStateScope.Season => "season",
        WatchStateScope.Series => "series",
        _ => "title",
    };

    private Task<T> Get<T>(string path, CancellationToken cancellation, TimeSpan? timeout = null) => Send<T>(HttpMethod.Get, path, null, cancellation, timeout);

    private async Task<T> Send<T>(HttpMethod method, string path, object? body, CancellationToken cancellation, TimeSpan? timeout = null)
    {
        if (timeout is { } limit)
        {
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            linked.CancelAfter(limit);
            try
            {
                return await AureliaApi.SendAsync<T>(api.Pinned(Server.Address, Server.Fingerprint), method, path, Profile.Token, body, false, linked.Token);
            }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
            {
                throw AureliaApi.Timeout();
            }
        }
        return await AureliaApi.SendAsync<T>(api.Pinned(Server.Address, Server.Fingerprint), method, path, Profile.Token, body, false, cancellation);
    }
}
