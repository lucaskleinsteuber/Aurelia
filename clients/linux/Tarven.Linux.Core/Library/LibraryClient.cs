using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Tarven.Contracts;
using Tarven.Linux.Core.Api;
using Tarven.Linux.Core.Connection;

namespace Tarven.Linux.Core.Library;

/// <summary>
/// The library endpoints for the open watching profile: Home, catalog pages, details, collections,
/// watchlist, favorites, watch state, history, statistics, artwork and sync. Every call carries the
/// profile's token over the pinned connection.
/// </summary>
public sealed class LibraryClient(TarvenApi api, StoredServer server, ProfileSession profile, IReadOnlyCollection<string> capabilities)
{
    public const int DefaultPageSize = 100;
    public const int LargePageSize = 500;

    public StoredServer Server { get; } = server;

    public ProfileSession Profile { get; } = profile;

    public bool Supports(string capability) => capabilities.Contains(capability);

    public bool SupportsWatchlist => Supports("watchlist-people-v1");

    public bool SupportsArtworkVariants => Supports("artwork-variants-v1");

    public bool SupportsWrapped => Supports(ServerFeatures.YearWrapped);

    public bool SupportsMonthlyWrapped => Supports(ServerFeatures.MonthlyWrapped);
    /// <summary>HLS in several qualities, converted live by the server.</summary>
    public bool SupportsAdaptiveStreaming => Supports(ServerFeatures.AdaptiveStreaming);

    public bool SupportsCollectionsV3 => Supports(ServerFeatures.CollectionsV3);

    public bool SupportsWishes => Supports(ServerFeatures.Wishes);

    /// <summary>People in the sidebar and a person's life and other titles from TMDB.</summary>
    public bool SupportsPeople => Supports(ServerFeatures.People);

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
            catch (TarvenApiException error) when (error.Code == "catalog_changed" && attempt < 2)
            {
            }
        }
    }

    public Task<CatalogDetailPresentation> DetailAsync(Guid mediaId, CancellationToken cancellation) =>
        Get<CatalogDetailPresentation>($"/api/v1/catalog/items/{mediaId}", cancellation);

    public Task<CatalogItemSummary> SummaryAsync(Guid mediaId, CancellationToken cancellation) =>
        Get<CatalogItemSummary>($"/api/v1/catalog/items/{mediaId}/summary", cancellation);

    public Task<PersonDetailResponse> PersonAsync(string name, string? personKey, CancellationToken cancellation) =>
        Get<PersonDetailResponse>("/api/v1/catalog/person?" + PersonQuery(name, personKey), cancellation);

    /// <summary>Builds the query string for GET /api/v1/catalog/person using the server's key parameter (audit SRV-API-002).</summary>
    public static string PersonQuery(string name, string? personKey) =>
        "name=" + Uri.EscapeDataString(name)
        + (personKey is { Length: > 0 } key && !key.StartsWith("unidentified:", StringComparison.Ordinal)
            ? "&key=" + Uri.EscapeDataString(key)
            : "");

    /// <summary>People in the library's credits, those in the most titles first ("people-v1").</summary>
    public Task<PeoplePageResponse> PeopleAsync(string? query, int offset, int limit, CancellationToken cancellation)
    {
        var path = FormattableString.Invariant($"/api/v1/people?offset={offset}&limit={limit}");
        if (!string.IsNullOrWhiteSpace(query)) path += "&query=" + Uri.EscapeDataString(query.Trim());
        return Get<PeoplePageResponse>(path, cancellation);
    }

    /// <summary>A person's life and the titles TMDB knows them for; empty without TMDB.</summary>
    public Task<PersonProfileResponse> PersonProfileAsync(string personKey, CancellationToken cancellation) =>
        Get<PersonProfileResponse>("/api/v1/people/profile?key=" + Uri.EscapeDataString(personKey), cancellation);

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

    public Task<CollectionDetail> CollectionAsync(Guid id, CancellationToken cancellation) =>
        Get<CollectionDetail>($"/api/v1/collections/{id}", cancellation);

    public Task<CollectionNextResponse> CollectionNextAsync(Guid id, CancellationToken cancellation) =>
        Get<CollectionNextResponse>($"/api/v1/collections/{id}/next", cancellation);

    public Task<CollectionDetail> UpdateCollectionOrderAsync(Guid id, CollectionOrderRequest request, CancellationToken cancellation) =>
        Send<CollectionDetail>(HttpMethod.Put, $"/api/v1/collections/{id}/order", request, cancellation);

    public Task DeleteCollectionAsync(Guid id, CancellationToken cancellation) =>
        Send<TarvenApi.NoContent>(HttpMethod.Delete, $"/api/v1/collections/{id}", null, cancellation);

    public Task AddToCollectionAsync(Guid collectionId, Guid mediaId, CancellationToken cancellation) =>
        AddToCollectionAsync(collectionId, mediaId, null, cancellation);

    public Task AddToCollectionAsync(Guid collectionId, Guid mediaId, int? seasonNumber, CancellationToken cancellation)
    {
        var query = seasonNumber is { } season ? "?seasonNumber=" + season.ToString(CultureInfo.InvariantCulture) : "";
        return Send<TarvenApi.NoContent>(HttpMethod.Post, $"/api/v1/collections/{collectionId}/items/{mediaId}{query}", null, cancellation);
    }

    public Task RemoveFromCollectionAsync(Guid collectionId, Guid mediaId, CancellationToken cancellation) =>
        RemoveFromCollectionAsync(collectionId, mediaId, null, cancellation);

    public Task RemoveFromCollectionAsync(Guid collectionId, Guid mediaId, int? seasonNumber, CancellationToken cancellation)
    {
        var query = seasonNumber is { } season ? "?seasonNumber=" + season.ToString(CultureInfo.InvariantCulture) : "";
        return Send<TarvenApi.NoContent>(HttpMethod.Delete, $"/api/v1/collections/{collectionId}/items/{mediaId}{query}", null, cancellation);
    }

    public Task<EditorUploadSummary> UploadCollectionEditorImageAsync(Guid id, byte[] image, CancellationToken cancellation)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, $"/api/v1/collections/{id}/editor/uploads")
        {
            Content = new ByteArrayContent(image),
        };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Profile.Token);
        return TarvenApi.SendRequestAsync<EditorUploadSummary>(api.Pinned(Server.Address, Server.Fingerprint), request, inspecting: false, cancellation);
    }

    public Task DiscardCollectionEditorImageAsync(Guid id, Guid uploadId, CancellationToken cancellation) =>
        Send<TarvenApi.NoContent>(HttpMethod.Delete, $"/api/v1/collections/{id}/editor/uploads/{uploadId}", null, cancellation);

    public Task<ArtworkSummary> SaveCollectionArtworkAsync(Guid id, string kind, SaveCollectionArtworkRequest request, CancellationToken cancellation) =>
        Send<ArtworkSummary>(HttpMethod.Post, $"/api/v1/collections/{id}/artwork/{kind}", request, cancellation);

    public Task DeleteCollectionArtworkAsync(Guid id, string kind, CancellationToken cancellation) =>
        Send<TarvenApi.NoContent>(HttpMethod.Delete, $"/api/v1/collections/{id}/artwork/{kind}", null, cancellation);

    public Task<WatchlistResponse> WatchlistAsync(CancellationToken cancellation) => Get<WatchlistResponse>("/api/v1/watchlist", cancellation);

    public Task<WatchlistItemStateResponse> SetWatchlistAsync(Guid mediaId, bool watchlisted, CancellationToken cancellation) =>
        Send<WatchlistItemStateResponse>(HttpMethod.Put, $"/api/v1/media/{mediaId}/watchlist", new SetWatchlistRequest(watchlisted), cancellation);

    public Task SetFavoriteAsync(Guid mediaId, bool favorite, CancellationToken cancellation) =>
        Send<TarvenApi.NoContent>(HttpMethod.Put, $"/api/v1/media/{mediaId}/favorite", new SetFavoriteRequest(favorite), cancellation);

    public Task<PlaybackPlanResponse> PlaybackPlanAsync(Guid mediaId, CancellationToken cancellation) =>
        Get<PlaybackPlanResponse>($"/api/v1/media/{mediaId}/playback-plan", cancellation);

    private (PlaybackPlanResponse Plan, long At)? shownPlan;

    /// <summary>
    /// The plan a page shows, handed over just before its Play starts the player, so the player
    /// does not ask the server for the same plan again before anything appears (as on iPhone
    /// and Apple TV). It is taken once, within a few seconds, and only for the plan's own target.
    /// </summary>
    public void OfferShownPlan(PlaybackPlanResponse? plan) =>
        shownPlan = plan?.Target is null ? null : (plan, Environment.TickCount64);

    /// <summary>The plan offered a moment ago if it plays <paramref name="targetId"/>; otherwise null.</summary>
    public PlaybackPlanResponse? TakeShownPlan(Guid targetId)
    {
        var offered = shownPlan;
        shownPlan = null;
        return offered is { } known && known.Plan.Target?.Id == targetId && Environment.TickCount64 - known.At < 5_000 ? known.Plan : null;
    }

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
        Send<TarvenApi.NoContent>(HttpMethod.Delete, $"/api/v1/history/{id}", null, cancellation);

    public Task ClearHistoryAsync(CancellationToken cancellation) =>
        Send<TarvenApi.NoContent>(HttpMethod.Delete, "/api/v1/history", null, cancellation);

    public Task<UserStatistics> StatisticsAsync(CancellationToken cancellation) => Get<UserStatistics>("/api/v1/statistics", cancellation);

    public Task<YearInReview> YearInReviewAsync(int year, CancellationToken cancellation) =>
        Get<YearInReview>($"/api/v1/statistics/year/{year}", cancellation);

    /// <summary>A year's Wrapped, or with <paramref name="month"/> one month's.</summary>
    public Task<YearWrapped> WrappedAsync(int year, int? month, CancellationToken cancellation) =>
        Get<YearWrapped>(month is { } m ? $"/api/v1/statistics/year/{year}/month/{m}/wrapped" : $"/api/v1/statistics/year/{year}/wrapped", cancellation);

    /// <summary>GET /api/v1/sync/changes: waits up to <paramref name="waitSeconds"/> for the library to change after the cursor.</summary>
    public Task<SyncChangesResponse> ChangesAsync(long after, int waitSeconds, string? generation, CancellationToken cancellation)
    {
        // The first request after loading everything starts at the newest change (server 2.21.0)
        // instead of paging through the whole kept history; older servers ignore it.
        var path = $"/api/v1/sync/changes?after={after}&waitSeconds={waitSeconds}" + (generation is { Length: > 0 } g ? "&generation=" + Uri.EscapeDataString(g) : "")
            + (after == 0 && generation is not { Length: > 0 } ? "&latest=true" : "");
        return Get<SyncChangesResponse>(path, cancellation, TimeSpan.FromSeconds(waitSeconds + 5));
    }

    /// <summary>
    /// Artwork bytes. The width (320, 640, 1280 or 1920) is sent only when the server offers
    /// sized artwork and the artwork has a revision; otherwise the stored original comes back.
    /// </summary>
    public async Task<byte[]> ArtworkAsync(ArtworkSummary artwork, int? width, CancellationToken cancellation)
    {
        var path = artwork.Path is { Length: > 0 } p && p.StartsWith("/api/v1/artwork/", StringComparison.Ordinal)
            ? p
            : $"/api/v1/artwork/{artwork.Id}";
        if (width is { } requested && SupportsArtworkVariants && artwork.Revision is not null && !path.Contains("width=", StringComparison.Ordinal))
        {
            path += (path.Contains('?', StringComparison.Ordinal) ? "&width=" : "?width=") + requested.ToString(CultureInfo.InvariantCulture);
        }
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
            throw TarvenApiException.Unreachable();
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode) throw await TarvenApi.ProblemAsync(response, cancellation);
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
                throw new TarvenApiException(409, "catalog_changed", "The library changed while loading.");
            revision ??= page.Revision;
            total ??= page.Total;
            foreach (var item in page.Items)
            {
                if (!seen.Add(item.Id)) throw new TarvenApiException(409, "catalog_changed", "The library changed while loading.");
                items.Add(item);
            }
            if (items.Count >= page.Total || page.Items.Count == 0) return items;
        }
    }

    // Family Wishes.
    public Task<WishSummaryResponse> WishSummaryAsync(CancellationToken cancellation) =>
        Get<WishSummaryResponse>("/api/v1/wishes/summary", cancellation);

    public Task<WishListResponse> WishesAsync(WishState? state, CancellationToken cancellation)
    {
        var path = state is { } value
            ? $"/api/v1/wishes?state={value.ToString().ToLowerInvariant()}"
            : "/api/v1/wishes";
        return Get<WishListResponse>(path, cancellation);
    }

    public Task<WishSearchResponse> SearchWishesAsync(string query, MediaKind? kind, CancellationToken cancellation)
    {
        var path = "/api/v1/wishes/search?query=" + Uri.EscapeDataString(query);
        if (kind is { } filter)
            path += "&kind=" + (filter == MediaKind.Series ? "series" : "movie");
        return Get<WishSearchResponse>(path, cancellation);
    }

    public async Task<CreateWishOutcome> CreateWishAsync(CreateWishRequest requestBody, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/wishes");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Profile.Token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Content = JsonContent.Create(requestBody, options: TarvenJson.Options);
        HttpResponseMessage response;
        try
        {
            response = await api.Pinned(Server.Address, Server.Fingerprint).SendAsync(request, cancellation);
        }
        catch (HttpRequestException)
        {
            throw TarvenApiException.Unreachable();
        }
        catch (TaskCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw TarvenApiException.Unreachable();
        }
        using (response)
        {
            if (response.StatusCode == HttpStatusCode.Conflict)
            {
                try
                {
                    var conflict = await response.Content.ReadFromJsonAsync<WishAlreadyInLibraryProblem>(TarvenJson.Options, cancellation);
                    if (conflict is not null)
                        return new CreateWishOutcome(CreateWishStatus.AlreadyInLibrary, Existing: conflict);
                }
                catch (System.Text.Json.JsonException)
                {
                }
            }
            if (!response.IsSuccessStatusCode) throw await TarvenApi.ProblemAsync(response, cancellation);
            var created = await response.Content.ReadFromJsonAsync<CreateWishResponse>(TarvenJson.Options, cancellation)
                ?? throw TarvenApiException.InvalidResponse();
            return new CreateWishOutcome(
                created.MergedIntoExistingSupport ? CreateWishStatus.MergedSupport : CreateWishStatus.Created,
                Wish: created.Wish);
        }
    }

    public Task<WishSummary> SetWishSupportAsync(Guid wishId, bool supported, CancellationToken cancellation) =>
        Send<WishSummary>(HttpMethod.Put, $"/api/v1/wishes/{wishId}/support", new SetWishSupportRequest(supported), cancellation);

    public Task<WishSummary> UpdateWishStateAsync(Guid wishId, UpdateWishStateRequest request, CancellationToken cancellation) =>
        Send<WishSummary>(HttpMethod.Put, $"/api/v1/wishes/{wishId}/state", request, cancellation);

    public Task DeleteWishAsync(Guid wishId, CancellationToken cancellation) =>
        Send<TarvenApi.NoContent>(HttpMethod.Delete, $"/api/v1/wishes/{wishId}", null, cancellation);

    public Task MarkWishesSeenAsync(CancellationToken cancellation) =>
        Send<TarvenApi.NoContent>(HttpMethod.Post, "/api/v1/wishes/seen", new { }, cancellation);

    public async Task<byte[]?> WishPosterAsync(string posterPath, CancellationToken cancellation, int width = 200)
    {
        var path = $"/api/v1/wishes/poster?path={Uri.EscapeDataString(posterPath)}&width={width.ToString(CultureInfo.InvariantCulture)}";
        using var request = new HttpRequestMessage(HttpMethod.Get, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Profile.Token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("image/*"));
        try
        {
            using var response = await api.Pinned(Server.Address, Server.Fingerprint).SendAsync(request, cancellation);
            return response.IsSuccessStatusCode ? await response.Content.ReadAsByteArrayAsync(cancellation) : null;
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
        {
            return null;
        }
    }

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
                return await TarvenApi.SendAsync<T>(api.Pinned(Server.Address, Server.Fingerprint), method, path, Profile.Token, body, false, linked.Token);
            }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
            {
                throw TarvenApi.Timeout();
            }
        }
        return await TarvenApi.SendAsync<T>(api.Pinned(Server.Address, Server.Fingerprint), method, path, Profile.Token, body, false, cancellation);
    }
}
