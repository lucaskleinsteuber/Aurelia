using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class PresentationService(
    AureliaDbContext database,
    TimeProvider timeProvider,
    MediaSearchIndexService searchIndex,
    WatchlistService? watchlist = null,
    CatalogMutationGate? mutations = null,
    CollectionArtworkService? collectionArtwork = null)
{
    // A profile's changes run one after another: two requests that read the same state and
    // then both write (a double tap, two devices) would otherwise fail in the database.
    private async Task<IDisposable?> EnterMutationAsync(CancellationToken cancellationToken) =>
        mutations is null ? null : await mutations.EnterAsync(cancellationToken);

    public async Task<PagedResponse<CatalogItemSummary>> CatalogAsync(
        Guid userId,
        MediaKind? kind,
        int offset,
        int limit,
        CancellationToken cancellationToken) =>
        await CatalogAsync(userId, new CatalogQuery(Kind: kind, Offset: offset, Limit: limit), cancellationToken);

    public async Task<PagedResponse<CatalogItemSummary>> CatalogAsync(
        Guid userId,
        CatalogQuery request,
        CancellationToken cancellationToken)
    {
        ValidateQuery(request);
        if (request.Kind is not null and not MediaKind.Movie and not MediaKind.Series)
            throw new MetadataException(
                "invalid_catalog_kind",
                "Catalog kind must be movie or series.",
                StatusCodes.Status400BadRequest);

        var query = BaseItems(userId).Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series);
        query = ApplyFilters(query, userId, request);
        var total = await query.CountAsync(cancellationToken);
        var items = await Cards(Order(query, userId, request.Sort, request.Direction)
            .Skip(request.Offset).Take(request.Limit), userId).ToListAsync(cancellationToken);
        return new PagedResponse<CatalogItemSummary>(
            items.Select(item => ToCatalog(item, userId)).ToList(), request.Offset, request.Limit, total);
    }

    public async Task<CatalogDetailPresentation> DetailAsync(
        Guid userId,
        Guid mediaId,
        CancellationToken cancellationToken)
    {
        var item = await BaseItems(userId)
            .Include(candidate => candidate.Metadata)!.ThenInclude(metadata => metadata!.Credits)
            // One query would repeat every column, the full provider credits included, for each
            // combination of artwork and credit: gigabytes for a film with a large cast.
            .AsSplitQuery()
            .SingleOrDefaultAsync(candidate => candidate.Id == mediaId
                && (candidate.Kind == MediaKind.Movie || candidate.Kind == MediaKind.Series), cancellationToken)
            ?? throw new MetadataException("media_not_found", "The movie or series was not found.", StatusCodes.Status404NotFound);
        var children = await Cards(BaseItems(userId).Where(candidate => candidate.ParentId == mediaId)
            .OrderBy(candidate => candidate.SeasonNumber).ThenBy(candidate => candidate.EpisodeNumber)
            .ThenBy(candidate => candidate.DetectedTitle).ThenBy(candidate => candidate.Id), userId)
            .ToListAsync(cancellationToken);

        item.CardWatchState = item.Kind == MediaKind.Series
            ? LibraryStateService.Aggregate(children.Count(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0), children.Where(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0).SelectMany(child => child.PlaybackProgress))
            : null;
        var seasons = children.Where(child => child.SeasonNumber.HasValue)
            .GroupBy(child => child.SeasonNumber!.Value).OrderBy(group => group.Key)
            .Select(group => new SeasonPresentation(
                group.Key,
                group.Where(child => child.Kind == MediaKind.Episode).Select(child => new EpisodePresentation(
                    ToCatalog(child, userId), child.SeasonNumber!.Value, child.EpisodeNumber ?? 0)).ToList(),
                group.Where(child => child.Kind is MediaKind.Extra or MediaKind.Trailer).Select(child =>
                    new SupplementPresentation(ToCatalog(child, userId), child.Category, child.SeasonNumber)).ToList()))
            .ToList();
        var supplements = children.Where(child => !child.SeasonNumber.HasValue
                && (child.Kind is MediaKind.Extra or MediaKind.Trailer))
            .Select(child => new SupplementPresentation(ToCatalog(child, userId), child.Category, child.SeasonNumber))
            .ToList();

        CollectionSummary? franchiseSummary = null;
        if (item.Kind is MediaKind.Movie or MediaKind.Series)
        {
            // A movie's own film series first, then the wider universe it shares with series.
            var franchise = await database.MediaCollections.AsNoTracking()
                .Include(c => c.Artwork)
                .Include(c => c.Members)
                .Where(c => (c.Provider == "tmdb" || c.Provider == MediaUniverses.Provider) && c.Members.Count >= 2
                    && c.Members.Any(m => m.MediaItemId == mediaId))
                .OrderBy(c => c.Provider == "tmdb" ? 0 : 1)
                .FirstOrDefaultAsync(cancellationToken);

            if (franchise is not null)
            {
                var hydrated = await HydrateCollectionsAsync(userId, [franchise], isAdmin: false, includeMembers: false, cancellationToken);
                franchiseSummary = hydrated.Select(value => value.Summary).FirstOrDefault(summary => summary.Items.Count >= 2);
            }
        }

        return new CatalogDetailPresentation(
            ToCatalog(item, userId), MetadataPresentation.ToSummary(item), seasons, supplements, franchiseSummary);
    }

    public async Task<CatalogItemSummary> SummaryAsync(Guid userId, Guid mediaId, CancellationToken cancellationToken)
    {
        var item = await Cards(BaseItems(userId).Where(item => item.Id == mediaId), userId)
            .SingleOrDefaultAsync(cancellationToken)
            ?? throw new MetadataException("media_not_found", "The media item was not found.", StatusCodes.Status404NotFound);
        return ToCatalog(item, userId);
    }

    public async Task<IReadOnlyList<CatalogItemSummary>> SummariesAsync(Guid userId, IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        if (ids.Count == 0) return [];
        var items = await Cards(BaseItems(userId).Where(item => ids.Contains(item.Id)), userId).ToListAsync(cancellationToken);
        var byId = items.ToDictionary(item => item.Id);
        return ids.Where(byId.ContainsKey).Select(id => ToCatalog(byId[id], userId)).ToList();
    }

    /// <summary>The most trailers one pre-show asks for.</summary>
    public const int MaximumCinemaTrailers = 3;

    /// <summary>
    /// Up to <paramref name="count"/> trailers for the pre-show before film <paramref name="mediaId"/>,
    /// in random order: one each of other films in the profile's library that it has not
    /// started yet, whose trailer file is there.
    /// </summary>
    public async Task<CinemaTrailersResponse> CinemaTrailersAsync(
        Guid userId, Guid mediaId, int count, CancellationToken cancellationToken)
    {
        // Only a film the profile can see has a pre-show; extras, trailers and episodes don't.
        if (!await database.MediaItems.AsNoTracking()
            .AnyAsync(item => item.Id == mediaId && item.Kind == MediaKind.Movie, cancellationToken))
            throw new MetadataException("media_not_found", "The film was not found.", StatusCodes.Status404NotFound);
        count = Math.Clamp(count, 0, MaximumCinemaTrailers);
        if (count == 0) return new CinemaTrailersResponse([]);
        var candidates = await database.MediaItems.AsNoTracking()
            .Where(item => item.Kind == MediaKind.Trailer && item.ParentId != null && item.ParentId != mediaId
                && item.Availability == MediaAvailability.Available
                && item.Parent!.Kind == MediaKind.Movie
                && !item.Parent.PlaybackProgress.Any(progress => progress.UserId == userId
                    && (progress.IsCompleted || progress.PositionMilliseconds > 0)))
            .Select(item => new { item.Id, Film = item.ParentId!.Value })
            .ToListAsync(cancellationToken);
        var films = candidates.GroupBy(candidate => candidate.Film)
            .Select(group => (Film: group.Key, Trailers: group.Select(candidate => candidate.Id).ToArray()))
            .ToArray();
        Random.Shared.Shuffle(films);

        // A few spare picks, in case a file went missing since the last scan.
        var picked = films.Take(count + 3)
            .Select(film => (film.Film, Trailer: film.Trailers[Random.Shared.Next(film.Trailers.Length)]))
            .ToList();
        var trailers = (await SummariesAsync(userId, picked.Select(pick => pick.Trailer).ToList(), cancellationToken))
            .ToDictionary(trailer => trailer.Id);
        var titles = (await SummariesAsync(userId, picked.Select(pick => pick.Film).ToList(), cancellationToken))
            .ToDictionary(title => title.Id);
        var shown = picked
            .Where(pick => trailers.TryGetValue(pick.Trailer, out var trailer) && trailer.Availability == MediaAvailability.Available
                && titles.ContainsKey(pick.Film))
            .Take(count)
            .Select(pick => new CinemaTrailer(trailers[pick.Trailer], titles[pick.Film]))
            .ToList();
        return new CinemaTrailersResponse(shown);
    }

    public async Task<PersonDetailResponse> PersonAsync(
        Guid userId,
        string? name,
        string? personKey,
        CancellationToken cancellationToken)
    {
        var trimmedName = string.IsNullOrWhiteSpace(name) ? null : name.Trim();
        var trimmedKey = string.IsNullOrWhiteSpace(personKey) || personKey.StartsWith("unidentified:", StringComparison.OrdinalIgnoreCase)
            ? null
            : personKey.Trim();
        if (trimmedName is null && trimmedKey is null)
        {
            throw new MetadataException(
                "invalid_person",
                "A person name or key is required.",
                StatusCodes.Status400BadRequest);
        }

        string? providerPersonId = null;
        if (trimmedKey is not null)
        {
            const string marker = ":person:";
            var index = trimmedKey.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
            if (index >= 0 && index + marker.Length < trimmedKey.Length)
            {
                providerPersonId = trimmedKey[(index + marker.Length)..].Trim();
            }
        }

        var escapedName = trimmedName is null ? null : EscapeLike(trimmedName);
        var accessibleTopLevel = database.MediaItems.AsNoTracking()
            .Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series);
        var creditsQuery = database.MediaCredits.AsNoTracking()
            .Join(accessibleTopLevel, credit => credit.MediaItemId, item => item.Id, (credit, _) => credit);
        if (providerPersonId is not null && escapedName is not null)
        {
            creditsQuery = creditsQuery.Where(credit =>
                credit.ProviderPersonId == providerPersonId
                || (credit.ProviderPersonId == null && EF.Functions.Like(credit.Name, escapedName, "\\")));
        }
        else if (providerPersonId is not null)
        {
            creditsQuery = creditsQuery.Where(credit => credit.ProviderPersonId == providerPersonId);
        }
        else
        {
            creditsQuery = creditsQuery.Where(credit => EF.Functions.Like(credit.Name, escapedName!, "\\"));
        }

        var matches = await creditsQuery
            .OrderBy(credit => credit.SortOrder)
            .ThenBy(credit => credit.Id)
            .Select(credit => new
            {
                credit.MediaItemId,
                credit.Name,
                credit.Department,
                credit.Job,
                credit.ProfileAssetId,
                credit.ProfilePath,
            })
            .ToListAsync(cancellationToken);

        var resolvedName = matches.Select(credit => credit.Name).FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))
            ?? trimmedName
            ?? "Person";
        if (matches.Count == 0)
        {
            return new PersonDetailResponse(resolvedName, null, null, []);
        }

        var roles = matches
            .Select(credit => string.Equals(credit.Department, "Acting", StringComparison.OrdinalIgnoreCase)
                ? "Acting"
                : !string.IsNullOrWhiteSpace(credit.Job) ? credit.Job! : credit.Department)
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        var subtitle = roles.Count > 0 ? string.Join(" · ", roles) : null;

        ArtworkSummary? profile = null;
        var profileAssetId = matches.Select(credit => credit.ProfileAssetId).FirstOrDefault(id => id.HasValue);
        if (profileAssetId.HasValue)
        {
            var asset = await database.ArtworkAssets.AsNoTracking()
                .FirstOrDefaultAsync(candidate => candidate.Id == profileAssetId.Value, cancellationToken);
            if (asset is not null)
            {
                profile = MetadataPresentation.ToArtwork(asset);
            }
        }

        if (profile is null)
        {
            var profilePath = matches.Select(credit => credit.ProfilePath).FirstOrDefault(path => !string.IsNullOrWhiteSpace(path));
            if (profilePath is not null)
            {
                var asset = await database.ArtworkAssets.AsNoTracking()
                    .FirstOrDefaultAsync(
                        candidate => candidate.Kind == ArtworkKind.Profile && candidate.ProviderPath == profilePath,
                        cancellationToken);
                if (asset is not null)
                {
                    profile = MetadataPresentation.ToArtwork(asset);
                }
            }
        }

        var mediaIds = matches.Select(credit => credit.MediaItemId).Distinct().ToList();
        var items = (await SummariesAsync(userId, mediaIds, cancellationToken))
            .OrderByDescending(item => item.Year ?? 0)
            .ThenBy(item => item.Title, StringComparer.OrdinalIgnoreCase)
            .ToList();
        return new PersonDetailResponse(resolvedName, subtitle, profile, items);
    }

    public async Task<PagedResponse<CatalogItemSummary>> SearchAsync(Guid userId, string query, int offset, int limit, CancellationToken cancellationToken) =>
        await SearchAsync(userId, query, new CatalogQuery(Offset: offset, Limit: limit), cancellationToken);

    public async Task<PagedResponse<CatalogItemSummary>> SearchAsync(
        Guid userId, string query, CatalogQuery request, CancellationToken cancellationToken)
    {
        ValidateQuery(request);
        var term = query.Trim();
        if (term.Length is < 1 or > 200)
            throw new MetadataException("invalid_search", "Search text must contain between 1 and 200 characters.", StatusCodes.Status400BadRequest);
        var visible = ApplyFilters(BaseItems(userId).Where(item => item.Kind == MediaKind.Movie
            || item.Kind == MediaKind.Series || item.Kind == MediaKind.Episode), userId, request);
        var hits = searchIndex.Hits(term);
        // The transactionally maintained index contains exactly the searchable
        // media kinds. An unrestricted, unfiltered request needs no redundant
        // catalog lookup for every FTS hit before counting or ranking.
        var restricted = database.AccessUserId != null && !database.AccessWholeCatalog
            || request.Kind.HasValue || request.LibraryId.HasValue || request.Availability.HasValue
            || request.Favorite.HasValue || request.WatchState.HasValue || request.YearFrom.HasValue
            || request.YearTo.HasValue || !string.IsNullOrWhiteSpace(request.Genre);
        var matches = restricted ? visible.Join(hits, item => item.Id, hit => hit.Id, (item, hit) => hit) : hits;
        var total = await matches.CountAsync(cancellationToken);
        var orderedIds = request.Relevance
            ? matches.OrderBy(hit => hit.Rank).ThenBy(hit => hit.Id).Select(hit => hit.Id)
            : Order(visible.Join(hits, item => item.Id, hit => hit.Id, (item, hit) => item), userId, request.Sort, request.Direction).Select(item => item.Id);
        var ids = await orderedIds.Skip(request.Offset).Take(request.Limit).ToListAsync(cancellationToken);
        var items = await SummariesAsync(userId, ids, cancellationToken);
        return new PagedResponse<CatalogItemSummary>(items, request.Offset, request.Limit, total);
    }

    /// <summary>
    /// Home. With <paramref name="suggestions"/> it also has "Because You Watched …" rails, and the
    /// hour's title comes from the profile's personal top ten when it has one.
    /// </summary>
    public async Task<HomeResponse> HomeAsync(Guid userId, CancellationToken cancellationToken, SuggestionService? suggestions = null)
    {
        var available = BaseItems(userId)
            .Where(item => item.Availability == MediaAvailability.Available);
        var topLevel = available.Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series);
        var plans = new SeriesResumeQuery(database).Plans(userId);
        var seriesTargets = await BaseItems(userId).Where(item => item.Kind == MediaKind.Series
                && !item.ContinueWatchingStates.Any(state => state.UserId == userId && state.IsHidden))
            .Join(plans.Where(plan => plan.ContinueWatchingEligible), item => item.Id, plan => plan.SeriesId, (item, plan) => plan)
            .OrderByDescending(plan => plan.LastPlayedAt).ThenBy(plan => plan.TargetId).Take(20).ToListAsync(cancellationToken);
        var movieTargets = await BaseItems(userId).Where(item => item.Kind == MediaKind.Movie
                && !item.ContinueWatchingStates.Any(state => state.UserId == userId && state.IsHidden)
                && item.PlaybackProgress.Any(progress => progress.UserId == userId && !progress.IsCompleted && progress.PositionMilliseconds > 10_000))
            .Select(item => new { item.Id, Played = item.PlaybackProgress.Where(progress => progress.UserId == userId).Select(progress => progress.LastPlayedAt).FirstOrDefault() })
            .OrderByDescending(item => item.Played).ThenBy(item => item.Id).Take(20).ToListAsync(cancellationToken);
        var continueIds = seriesTargets.Select(plan => (Id: plan.TargetId, Played: plan.LastPlayedAt.HasValue ? DateTimeOffset.FromUnixTimeMilliseconds(plan.LastPlayedAt.Value) : (DateTimeOffset?)null))
            .Concat(movieTargets.Select(item => (item.Id, item.Played)))
            .OrderByDescending(item => item.Played).ThenBy(item => item.Id).Take(20).Select(item => item.Id).ToList();
        var continueItems = await SummariesAsync(userId, continueIds, cancellationToken);
        // The newest 30 by id first, then only their cards, in that order.
        var recentIds = await topLevel.OrderByDescending(item => item.CreatedAt).ThenBy(item => item.Id)
            .Take(30).Select(item => item.Id).ToListAsync(cancellationToken);
        var recentCards = await Cards(BaseItems(userId).Where(item => recentIds.Contains(item.Id)), userId).ToListAsync(cancellationToken);
        var recentOrder = recentIds.Select((id, index) => (id, index)).ToDictionary(pair => pair.id, pair => pair.index);
        var recentItems = recentCards.OrderBy(card => recentOrder[card.Id]).ToList();
        var favoriteItems = await Cards(topLevel
            .Where(item => item.Favorites.Any(value => value.UserId == userId))
            .OrderBy(item => item.DetectedTitle).ThenBy(item => item.Id)
            .Take(30), userId).ToListAsync(cancellationToken);
        var now = timeProvider.GetUtcNow();
        var hour = new DateTimeOffset(now.Year, now.Month, now.Day, now.Hour, 0, 0, TimeSpan.Zero);
        var preferred = topLevel.Where(item => !item.PlaybackProgress.Any(
            progress => progress.UserId == userId && progress.IsCompleted));
        var (rails, topTen) = suggestions is null ? ([], []) : await suggestions.HomeAsync(userId, cancellationToken);
        // The hour's title: one read of the candidates' ids, counted and chosen here, then only
        // that card. Counting and then skipping through them in the database walked them twice.
        // A profile with a watch history gets one of its personal top ten instead.
        var pool = topTen.Count > 0 ? [.. topTen] : await preferred.OrderBy(item => item.Id).Select(item => item.Id).ToListAsync(cancellationToken);
        if (pool.Count == 0) pool = await topLevel.OrderBy(item => item.Id).Select(item => item.Id).ToListAsync(cancellationToken);
        Guid? chosen = pool.Count == 0 ? null : pool[StableIndex(userId, hour, pool.Count)];
        var recommendationItem = chosen is not { } chosenId
            ? null
            : await Cards(BaseItems(userId).Where(item => item.Id == chosenId), userId).SingleOrDefaultAsync(cancellationToken);
        return new HomeResponse(
            recommendationItem is null ? null : ToCatalog(recommendationItem, userId),
            continueItems,
            recentItems.Select(item => ToCatalog(item, userId)).ToList(),
            favoriteItems.Select(item => ToCatalog(item, userId)).ToList(),
            await CollectionsAsync(userId, 0, 30, cancellationToken),
            hour.AddHours(1),
            suggestions is null ? null : rails);
    }

    private sealed record CollectionBuildResult(
        CollectionSummary Summary,
        CollectionDetail Detail,
        IReadOnlyList<MediaItem> OrderedEntities);

    private sealed record PlayableMediaItem(MediaItem Entity, CatalogItemSummary Card);

    private sealed record ResolvedMember(
        Guid MemberId,
        MediaItem Entity,
        CatalogItemSummary Card,
        int? SeasonNumber,
        int SortOrder,
        string Title,
        int? MinYear,
        IReadOnlyList<PlayableMediaItem>? Episodes,
        int ItemCount,
        int WatchedCount,
        long TotalRuntimeSeconds,
        IReadOnlyList<int> Years);

    public Task<IReadOnlyList<CollectionSummary>> CollectionsAsync(Guid userId, int offset, int limit, CancellationToken cancellationToken) =>
        CollectionsAsync(userId, offset, limit, null, cancellationToken);

    private async Task<CollectionSummary> CollectionAsync(Guid userId, Guid id, CancellationToken cancellationToken) =>
        (await CollectionsAsync(userId, 0, 1, id, cancellationToken)).Single();

    private async Task<IReadOnlyList<CollectionSummary>> CollectionsAsync(Guid userId, int offset, int limit, Guid? onlyId, CancellationToken cancellationToken)
    {
        ValidatePage(offset, limit);
        var isAdmin = await IsAdminUserAsync(userId, cancellationToken);
        // A shared collection's name tells what is in it, so a profile that may see none of its
        // titles (a children's profile, for example) does not get it. Administrators keep all of
        // them to manage, also empty ones.
        var candidates = database.MediaCollections.AsNoTracking()
            .Where(collection => (collection.UserId == null || collection.UserId == userId)
                && (onlyId == null || collection.Id == onlyId)
                && (collection.IsManual || collection.IsSmart || collection.Members.Count >= 2));
        if (!isAdmin)
            candidates = candidates.Where(collection => collection.UserId != null || collection.IsSmart || collection.Members.Any());
        var collections = await candidates
            .OrderBy(collection => collection.Name).ThenBy(collection => collection.Id).Skip(offset).Take(limit)
            .Include(collection => collection.Artwork)
            .Include(collection => collection.Members)
            .ToListAsync(cancellationToken);

        var hydrated = await HydrateCollectionsAsync(userId, collections, isAdmin, includeMembers: false, cancellationToken);
        return hydrated.Select(value => value.Summary).ToList();
    }

    public async Task<CollectionDetail> GetCollectionAsync(Guid userId, Guid id, CancellationToken cancellationToken)
    {
        var isAdmin = await IsAdminUserAsync(userId, cancellationToken);
        var collection = await LoadAccessibleCollectionAsync(userId, id, isAdmin, cancellationToken);
        var hydrated = await HydrateCollectionsAsync(userId, [collection], isAdmin, includeMembers: true, cancellationToken);
        return hydrated.Single().Detail;
    }

    public async Task<CollectionNextResponse> GetCollectionNextAsync(Guid userId, Guid id, CancellationToken cancellationToken)
    {
        var detail = await GetCollectionAsync(userId, id, cancellationToken);
        return detail.NextItem
            ?? throw new MetadataException("no_playable_items", "The collection has no playable items.", StatusCodes.Status404NotFound);
    }

    public async Task<CollectionImageResult?> ResolveCollectionImageAsync(
        Guid userId,
        Guid collectionId,
        ArtworkKind kind,
        int? width,
        CancellationToken cancellationToken)
    {
        if (collectionArtwork is null) return null;
        var isAdmin = await IsAdminUserAsync(userId, cancellationToken);
        var collection = await LoadAccessibleCollectionOrNullAsync(userId, collectionId, isAdmin, cancellationToken);
        if (collection is null) return null;

        var hydrated = await HydrateCollectionsAsync(userId, [collection], isAdmin, includeMembers: false, cancellationToken, loadEpisodes: false);
        var entities = hydrated.FirstOrDefault()?.OrderedEntities ?? [];
        return await collectionArtwork.ResolveImageAsync(database, collection, kind, width, entities, cancellationToken);
    }

    public async Task EnsureCanEditCollectionAsync(Guid userId, Guid collectionId, CancellationToken cancellationToken) =>
        await LoadEditableCollectionAsync(userId, collectionId, includeMembers: false, includeArtwork: false, cancellationToken);

    public async Task<ArtworkSummary> SaveCollectionArtworkAsync(
        Guid userId,
        Guid sessionId,
        Guid collectionId,
        ArtworkKind kind,
        Stream? rawStream,
        SaveCollectionArtworkRequest? jsonRequest,
        ArtworkCrop? queryCrop,
        CancellationToken cancellationToken)
    {
        if (collectionArtwork is null)
            throw new MetadataException("artwork_unavailable", "Collection artwork storage is unavailable.", StatusCodes.Status503ServiceUnavailable);

        using var lease = await EnterMutationAsync(cancellationToken);
        var collection = await LoadEditableCollectionAsync(userId, collectionId, includeMembers: false, includeArtwork: true, cancellationToken);
        return await collectionArtwork.SaveManualAsync(database, collection, userId, sessionId, kind, rawStream, jsonRequest, queryCrop, cancellationToken);
    }

    public async Task RemoveCollectionArtworkAsync(
        Guid userId,
        Guid collectionId,
        ArtworkKind kind,
        CancellationToken cancellationToken)
    {
        if (collectionArtwork is null) return;
        using var lease = await EnterMutationAsync(cancellationToken);
        var collection = await LoadEditableCollectionAsync(userId, collectionId, includeMembers: false, includeArtwork: true, cancellationToken);
        await collectionArtwork.RemoveManualAsync(database, collection, kind, cancellationToken);
    }

    public async Task<bool> SetFavoriteAsync(Guid userId, Guid mediaId, bool isFavorite, CancellationToken cancellationToken)
    {
        using var lease = await EnterMutationAsync(cancellationToken);
        if (!await database.MediaItems.AnyAsync(item => item.Id == mediaId && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series), cancellationToken))
            throw new MetadataException("media_not_found", "The movie or series was not found.", StatusCodes.Status404NotFound);
        var existing = await database.UserFavorites.SingleOrDefaultAsync(value => value.UserId == userId && value.MediaItemId == mediaId, cancellationToken);
        if (isFavorite && existing is null)
            database.UserFavorites.Add(new UserFavorite { Id = Guid.NewGuid(), UserId = userId, MediaItemId = mediaId, CreatedAt = DateTimeOffset.UtcNow });
        if (!isFavorite && existing is not null) database.UserFavorites.Remove(existing);
        await database.SaveChangesAsync(cancellationToken);
        return isFavorite;
    }

    public async Task<CollectionSummary> CreateCollectionAsync(Guid userId, SaveCollectionRequest request, CancellationToken cancellationToken)
    {
        using var lease = await EnterMutationAsync(cancellationToken);
        var isAdmin = await IsAdminUserAsync(userId, cancellationToken);
        if (request.IsShared && !isAdmin)
            throw new MetadataException("forbidden", "Only administrators can create shared collections.", StatusCodes.Status403Forbidden);

        var collection = new MediaCollectionRecord
        {
            Id = Guid.NewGuid(),
            IsManual = true,
            IsSmart = request.IsSmart,
            UserId = request.IsShared ? null : userId,
            CreatedAt = DateTimeOffset.UtcNow,
        };
        await ApplyCollectionAsync(collection, request, cancellationToken);
        database.MediaCollections.Add(collection);
        await database.SaveChangesAsync(cancellationToken);
        return await CollectionAsync(userId, collection.Id, cancellationToken);
    }

    public async Task<CollectionSummary> UpdateCollectionAsync(Guid userId, Guid id, SaveCollectionRequest request, CancellationToken cancellationToken)
    {
        using var lease = await EnterMutationAsync(cancellationToken);
        var collection = await database.MediaCollections.Include(value => value.Members)
            .SingleOrDefaultAsync(value => value.Id == id && (value.IsManual || value.IsSmart), cancellationToken)
            ?? throw new MetadataException("collection_not_found", "The editable collection was not found.", StatusCodes.Status404NotFound);

        var isAdmin = await RequireEditableAsync(collection, userId, cancellationToken);
        if (request.IsShared && !isAdmin)
            throw new MetadataException("forbidden", "Only administrators can make collections shared.", StatusCodes.Status403Forbidden);

        // A private collection keeps its owner; un-sharing makes it the editor's own.
        collection.UserId = request.IsShared ? null : collection.UserId ?? userId;
        collection.IsSmart = request.IsSmart;
        collection.SmartRulesJson = null;

        await ApplyCollectionAsync(collection, request, cancellationToken);
        await database.SaveChangesAsync(cancellationToken);
        collectionArtwork?.InvalidateCollectionCache(collection.Id);
        return await CollectionAsync(userId, collection.Id, cancellationToken);
    }

    public async Task DeleteCollectionAsync(Guid userId, Guid id, CancellationToken cancellationToken)
    {
        using var lease = await EnterMutationAsync(cancellationToken);
        var collection = await database.MediaCollections.SingleOrDefaultAsync(value => value.Id == id && (value.IsManual || value.IsSmart), cancellationToken)
            ?? throw new MetadataException("collection_not_found", "The editable collection was not found.", StatusCodes.Status404NotFound);

        if (userId != Guid.Empty) await RequireEditableAsync(collection, userId, cancellationToken);

        var artworkFiles = collectionArtwork is null
            ? []
            : await collectionArtwork.FileNamesForCollectionsAsync(database, [collection.Id], cancellationToken);
        database.MediaCollections.Remove(collection);
        await database.SaveChangesAsync(cancellationToken);
        collectionArtwork?.DeleteFileNames(artworkFiles);
        collectionArtwork?.InvalidateCollectionCache(collection.Id);
    }

    public Task DeleteCollectionAsync(Guid id, CancellationToken cancellationToken) =>
        DeleteCollectionAsync(Guid.Empty, id, cancellationToken);

    public Task AddCollectionItemAsync(Guid userId, Guid collectionId, Guid mediaId, CancellationToken cancellationToken) =>
        AddCollectionItemAsync(userId, collectionId, mediaId, null, cancellationToken);

    public async Task AddCollectionItemAsync(Guid userId, Guid collectionId, Guid mediaId, int? seasonNumber, CancellationToken cancellationToken)
    {
        using var lease = await EnterMutationAsync(cancellationToken);
        var collection = await LoadEditableCollectionAsync(userId, collectionId, includeMembers: true, includeArtwork: false, cancellationToken);
        if (collection.IsSmart)
            throw new MetadataException("smart_collection", "A smart list chooses its titles by its rules.", StatusCodes.Status409Conflict);

        var item = await database.MediaItems.AsNoTracking()
            .Where(m => m.Id == mediaId && (m.Kind == MediaKind.Movie || m.Kind == MediaKind.Series || m.Kind == MediaKind.Episode))
            .Select(m => new { m.Id, m.Kind })
            .SingleOrDefaultAsync(cancellationToken)
            ?? throw new MetadataException("media_not_found", "Media item not found.", StatusCodes.Status404NotFound);

        if (seasonNumber.HasValue && (item.Kind != MediaKind.Series || seasonNumber.Value < 0))
            throw new MetadataException("invalid_collection_items", "A season member must reference a series with a non-negative season number.", StatusCodes.Status400BadRequest);

        if (!collection.Members.Any(m => m.MediaItemId == mediaId && m.SeasonNumber == seasonNumber))
        {
            if (collection.Members.Count >= 500)
                throw new MetadataException("invalid_collection", "A collection cannot contain more than 500 items.", StatusCodes.Status400BadRequest);

            var nextOrder = collection.Members.Count == 0 ? 0 : collection.Members.Max(m => m.SortOrder) + 1;
            var added = new MediaCollectionMember
            {
                Id = Guid.NewGuid(),
                CollectionId = collection.Id,
                MediaItemId = mediaId,
                SeasonNumber = seasonNumber,
                SortOrder = nextOrder,
            };
            collection.Members.Add(added);
            database.MediaCollectionMembers.Add(added);
            collection.UpdatedAt = timeProvider.GetUtcNow();
            await database.SaveChangesAsync(cancellationToken);
            collectionArtwork?.InvalidateCollectionCache(collection.Id);
        }
    }

    public Task RemoveCollectionItemAsync(Guid userId, Guid collectionId, Guid mediaId, CancellationToken cancellationToken) =>
        RemoveCollectionItemAsync(userId, collectionId, mediaId, null, cancellationToken);

    public async Task RemoveCollectionItemAsync(Guid userId, Guid collectionId, Guid mediaId, int? seasonNumber, CancellationToken cancellationToken)
    {
        using var lease = await EnterMutationAsync(cancellationToken);
        var collection = await LoadEditableCollectionAsync(userId, collectionId, includeMembers: true, includeArtwork: false, cancellationToken);

        var member = collection.Members.FirstOrDefault(m => m.MediaItemId == mediaId && m.SeasonNumber == seasonNumber);
        if (member is not null)
        {
            collection.Members.Remove(member);
            database.MediaCollectionMembers.Remove(member);
            collection.UpdatedAt = timeProvider.GetUtcNow();
            await database.SaveChangesAsync(cancellationToken);
            collectionArtwork?.InvalidateCollectionCache(collection.Id);
        }
    }

    public async Task<CollectionDetail> ReorderCollectionAsync(Guid userId, Guid collectionId, CollectionOrderRequest request, CancellationToken cancellationToken)
    {
        using var lease = await EnterMutationAsync(cancellationToken);
        var collection = await LoadEditableCollectionAsync(userId, collectionId, includeMembers: true, includeArtwork: false, cancellationToken);
        if (collection.IsSmart)
            throw new MetadataException("smart_collection", "A smart list chooses its titles by its rules.", StatusCodes.Status409Conflict);

        var sortMode = NormalizeSortMode(request.SortMode, allowNullToDefault: true, fallback: "custom");
        var membersByKey = collection.Members.ToDictionary(m => (m.MediaItemId, m.SeasonNumber));
        var orderedKeys = new List<(Guid MediaId, int? SeasonNumber)>();
        var seen = new HashSet<(Guid MediaId, int? SeasonNumber)>();
        foreach (var entry in request.Members ?? [])
        {
            var key = (entry.MediaId, entry.SeasonNumber);
            if (!membersByKey.ContainsKey(key))
                throw new MetadataException("invalid_collection_items", "Every reordered item must already belong to the collection.", StatusCodes.Status400BadRequest);
            if (seen.Add(key)) orderedKeys.Add(key);
        }

        foreach (var remaining in collection.Members.OrderBy(m => m.SortOrder))
        {
            var key = (remaining.MediaItemId, remaining.SeasonNumber);
            if (seen.Add(key)) orderedKeys.Add(key);
        }

        for (var i = 0; i < orderedKeys.Count; i++)
        {
            membersByKey[orderedKeys[i]].SortOrder = i;
        }

        collection.SortMode = sortMode;
        collection.UpdatedAt = timeProvider.GetUtcNow();
        await database.SaveChangesAsync(cancellationToken);
        collectionArtwork?.InvalidateCollectionCache(collection.Id);
        return await GetCollectionAsync(userId, collection.Id, cancellationToken);
    }

    /// <summary>A film series or universe in the order its titles came out; undated ones last.</summary>
    internal static List<CatalogItemSummary> ByRelease(IEnumerable<CatalogItemSummary> items) =>
        [.. items.OrderBy(item => item.Year ?? int.MaxValue).ThenBy(item => item.Title, StringComparer.CurrentCultureIgnoreCase)];

    public async Task<IReadOnlyList<CollectionSummary>> FranchisesAsync(Guid userId, int offset, int limit, CancellationToken cancellationToken)
    {
        ValidatePage(offset, limit);
        var isAdmin = await IsAdminUserAsync(userId, cancellationToken);
        var franchises = await database.MediaCollections.AsNoTracking()
            .Where(c => (c.Provider == "tmdb" || c.Provider == MediaUniverses.Provider) && c.Members.Count >= 1)
            .OrderBy(c => c.Name).ThenBy(c => c.Id)
            .Skip(offset).Take(limit)
            .Include(c => c.Artwork)
            .Include(c => c.Members)
            .ToListAsync(cancellationToken);

        var hydrated = await HydrateCollectionsAsync(userId, franchises, isAdmin, includeMembers: false, cancellationToken);
        return hydrated.Select(value => value.Summary).ToList();
    }

    public async Task<CollectionSummary> CreateCollectionFromFranchiseAsync(Guid userId, Guid franchiseId, CancellationToken cancellationToken)
    {
        using var lease = await EnterMutationAsync(cancellationToken);
        // Only a provider franchise can be copied, never another profile's own collection.
        var franchise = await database.MediaCollections.AsNoTracking()
            .Include(c => c.Members)
            .Include(c => c.Artwork)
            .SingleOrDefaultAsync(c => c.Id == franchiseId && (c.Provider == "tmdb" || c.Provider == MediaUniverses.Provider), cancellationToken)
            ?? throw new MetadataException("franchise_not_found", "Franchise collection not found.", StatusCodes.Status404NotFound);

        var members = franchise.Members.OrderBy(m => m.SortOrder).Select(m => new CollectionMemberInput(m.MediaItemId, m.SeasonNumber)).ToList();
        var request = new SaveCollectionRequest(
            franchise.Name,
            IsSmart: false,
            IsShared: false,
            Overview: franchise.Overview,
            SortMode: franchise.SortMode ?? "release",
            Members: members);

        var collection = new MediaCollectionRecord
        {
            Id = Guid.NewGuid(),
            IsManual = true,
            IsSmart = false,
            UserId = userId,
            CreatedAt = timeProvider.GetUtcNow(),
        };
        await ApplyCollectionAsync(collection, request, cancellationToken);
        database.MediaCollections.Add(collection);
        if (collectionArtwork is not null && franchise.Artwork.Count > 0)
        {
            await collectionArtwork.CopyAssetsAsync(database, franchise, collection, cancellationToken);
        }
        await database.SaveChangesAsync(cancellationToken);
        return await CollectionAsync(userId, collection.Id, cancellationToken);
    }

    private async Task<MediaCollectionRecord?> LoadAccessibleCollectionOrNullAsync(
        Guid userId,
        Guid id,
        bool isAdmin,
        CancellationToken cancellationToken)
    {
        var collection = await database.MediaCollections.AsNoTracking()
            .Include(c => c.Artwork)
            .Include(c => c.Members)
            .Where(c => c.Id == id && (c.UserId == null || c.UserId == userId)
                && (c.IsManual || c.IsSmart || c.Members.Count >= 1))
            .SingleOrDefaultAsync(cancellationToken);
        if (collection is null) return null;
        if (!isAdmin && collection.UserId is null && !collection.IsSmart && collection.Members.Count == 0)
            return null;
        return collection;
    }

    private async Task<MediaCollectionRecord> LoadAccessibleCollectionAsync(
        Guid userId,
        Guid id,
        bool isAdmin,
        CancellationToken cancellationToken) =>
        await LoadAccessibleCollectionOrNullAsync(userId, id, isAdmin, cancellationToken)
            ?? throw new MetadataException("collection_not_found", "The collection was not found.", StatusCodes.Status404NotFound);

    private async Task<MediaCollectionRecord> LoadEditableCollectionAsync(
        Guid userId,
        Guid collectionId,
        bool includeMembers,
        bool includeArtwork,
        CancellationToken cancellationToken)
    {
        IQueryable<MediaCollectionRecord> query = database.MediaCollections;
        if (includeMembers) query = query.Include(c => c.Members);
        if (includeArtwork) query = query.Include(c => c.Artwork);
        var collection = await query
            .SingleOrDefaultAsync(c => c.Id == collectionId && (c.IsManual || c.IsSmart), cancellationToken)
            ?? throw new MetadataException("collection_not_found", "The editable collection was not found.", StatusCodes.Status404NotFound);

        await RequireEditableAsync(collection, userId, cancellationToken);
        return collection;
    }

    /// <summary>
    /// Shared collections belong to the administrators; a private collection only to its own
    /// profile, which administrators can neither see nor change. Returns whether the editor is an
    /// administrator.
    /// </summary>
    private async Task<bool> RequireEditableAsync(MediaCollectionRecord collection, Guid userId, CancellationToken cancellationToken)
    {
        var isAdmin = await IsAdminUserAsync(userId, cancellationToken);
        if (collection.UserId is null && !isAdmin)
            throw new MetadataException("forbidden", "Only administrators can change shared collections.", StatusCodes.Status403Forbidden);
        if (collection.UserId is { } owner && owner != userId)
            throw new MetadataException("collection_not_found", "The editable collection was not found.", StatusCodes.Status404NotFound);
        return isAdmin;
    }

    private static bool ComputeCanEdit(MediaCollectionRecord collection, Guid userId, bool isAdmin) =>
        (collection.IsManual || collection.IsSmart)
        && (collection.UserId is null ? isAdmin : collection.UserId == userId);

    private static string DefaultSortMode(MediaCollectionRecord collection) =>
        collection.IsSmart ? "title" : collection.Provider is not null ? "release" : "custom";

    private static string NormalizeSortMode(string? value, bool allowNullToDefault, string fallback)
    {
        if (value is null)
        {
            return allowNullToDefault
                ? fallback
                : throw new MetadataException("invalid_sort_mode", "Sort mode must be custom, release, or title.", StatusCodes.Status400BadRequest);
        }
        var normalized = value.Trim().ToLowerInvariant();
        if (normalized is "custom" or "release" or "title") return normalized;
        throw new MetadataException("invalid_sort_mode", "Sort mode must be custom, release, or title.", StatusCodes.Status400BadRequest);
    }

    private async Task<bool> IsAdminUserAsync(Guid userId, CancellationToken cancellationToken) =>
        userId != Guid.Empty && await database.Users.AnyAsync(u => u.Id == userId && u.IsEnabled && (u.Role == UserRole.Owner || u.Role == UserRole.Admin), cancellationToken);

    private async Task ApplyCollectionAsync(MediaCollectionRecord collection, SaveCollectionRequest request, CancellationToken cancellationToken)
    {
        var name = request.Name.Trim();
        if (name.Length is < 1 or > 512)
            throw new MetadataException("invalid_collection", "A collection needs a name between 1 and 512 characters.", StatusCodes.Status400BadRequest);

        if (request.Overview is not null)
        {
            var overview = request.Overview.Trim();
            if (overview.Length > 8192)
                throw new MetadataException("invalid_overview", "Overview must contain 8192 characters or fewer.", StatusCodes.Status400BadRequest);
            collection.Overview = overview.Length == 0 ? null : overview;
        }

        collection.SortMode = NormalizeSortMode(request.SortMode, allowNullToDefault: true, fallback: collection.SortMode ?? DefaultSortMode(collection));
        collection.Name = name;
        collection.UpdatedAt = timeProvider.GetUtcNow();

        if (request.IsSmart)
        {
            // Stored in one spelling, whichever app wrote the rules.
            var rules = SmartListEvaluator.Parse(request.RulesJson ?? "{}")
                ?? throw new MetadataException("invalid_smart_rules", "The smart list's rules could not be read.", StatusCodes.Status400BadRequest);
            collection.IsSmart = true;
            collection.SmartRulesJson = SmartListEvaluator.Canonical(rules);
            foreach (var member in collection.Members.ToList())
            {
                collection.Members.Remove(member);
                database.MediaCollectionMembers.Remove(member);
            }
            return;
        }

        var rawEntries = request.Members is not null
            ? request.Members
            : (request.MediaIds ?? []).Select(id => new CollectionMemberInput(id, null));
        var entries = rawEntries
            .DistinctBy(entry => (entry.MediaId, entry.SeasonNumber))
            .ToList();
        if (entries.Count > 500)
            throw new MetadataException("invalid_collection", "A collection cannot contain more than 500 items.", StatusCodes.Status400BadRequest);

        var distinctMediaIds = entries.Select(entry => entry.MediaId).Distinct().ToList();
        var itemKinds = distinctMediaIds.Count == 0
            ? new Dictionary<Guid, MediaKind>()
            : await database.MediaItems
                .Where(item => distinctMediaIds.Contains(item.Id) && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series || item.Kind == MediaKind.Episode))
                .Select(item => new { item.Id, item.Kind })
                .ToDictionaryAsync(item => item.Id, item => item.Kind, cancellationToken);

        foreach (var entry in entries)
        {
            if (!itemKinds.TryGetValue(entry.MediaId, out var kind))
                throw new MetadataException("invalid_collection_items", "Every collection item must be an existing movie, series, or episode.", StatusCodes.Status400BadRequest);
            if (entry.SeasonNumber.HasValue && (kind != MediaKind.Series || entry.SeasonNumber.Value < 0))
                throw new MetadataException("invalid_collection_items", "A season member must reference a series with a non-negative season number.", StatusCodes.Status400BadRequest);
        }

        var desired = entries.Select((entry, index) => (entry, index))
            .ToDictionary(pair => (pair.entry.MediaId, pair.entry.SeasonNumber), pair => pair.index);
        foreach (var member in collection.Members.ToList())
        {
            if (!desired.TryGetValue((member.MediaItemId, member.SeasonNumber), out var sortOrder))
            {
                collection.Members.Remove(member);
                database.MediaCollectionMembers.Remove(member);
                continue;
            }

            member.SortOrder = sortOrder;
        }

        var existingKeys = collection.Members.Select(member => (member.MediaItemId, member.SeasonNumber)).ToHashSet();
        collection.Members.AddRange(entries
            .Where(entry => !existingKeys.Contains((entry.MediaId, entry.SeasonNumber)))
            .Select(entry => new MediaCollectionMember
            {
                Id = Guid.NewGuid(),
                CollectionId = collection.Id,
                MediaItemId = entry.MediaId,
                SeasonNumber = entry.SeasonNumber,
                SortOrder = desired[(entry.MediaId, entry.SeasonNumber)],
            }));
    }

    private async Task<List<CollectionBuildResult>> HydrateCollectionsAsync(
        Guid userId,
        List<MediaCollectionRecord> collections,
        bool isAdmin,
        bool includeMembers,
        CancellationToken cancellationToken,
        bool loadEpisodes = true)
    {
        if (collections.Count == 0) return [];
        // Lists and pictures need a smart list's first titles only; its own page shows up to 500.
        var smartLimit = includeMembers ? 500 : 50;
        // Episodes are only loaded where progress is shown: a smart list's page, or a person's own boxes.
        var episodeSeries = new HashSet<Guid>();

        IReadOnlyCollection<Guid>? watchlistIds = null;
        var smartEvaluationByCollection = new Dictionary<Guid, (IReadOnlyList<Guid> Ids, int TotalCount, string SortMode)>();
        var referencedMediaIds = new HashSet<Guid>();

        foreach (var collection in collections)
        {
            if (collection.IsSmart)
            {
                var sortMode = NormalizeSortMode(collection.SortMode, allowNullToDefault: true, fallback: DefaultSortMode(collection));
                var rules = SmartListEvaluator.Parse(collection.SmartRulesJson);
                if (rules?.WatchlistOnly == true && watchlist is not null && watchlistIds is null)
                {
                    watchlistIds = await watchlist.MediaIdsAsync(userId, cancellationToken);
                }

                var (ids, total) = rules is null
                    ? ((IReadOnlyList<Guid>)[], 0)
                    : await SmartListEvaluator.EvaluateIdsAsync(database, userId, rules, 0, smartLimit, cancellationToken, watchlistIds, sortMode);
                smartEvaluationByCollection[collection.Id] = (ids, total, sortMode);
                foreach (var id in ids)
                {
                    referencedMediaIds.Add(id);
                    if (includeMembers) episodeSeries.Add(id);
                }
            }
            else
            {
                foreach (var member in collection.Members)
                {
                    referencedMediaIds.Add(member.MediaItemId);
                    episodeSeries.Add(member.MediaItemId);
                }
            }
        }

        var loadedItems = referencedMediaIds.Count == 0
            ? []
            : await Cards(BaseItems(userId).Where(item => referencedMediaIds.Contains(item.Id)), userId).ToListAsync(cancellationToken);
        var itemsById = loadedItems.ToDictionary(item => item.Id, item => new PlayableMediaItem(item, ToCatalog(item, userId)));

        var seriesIds = loadEpisodes
            ? loadedItems.Where(item => item.Kind == MediaKind.Series && episodeSeries.Contains(item.Id)).Select(item => item.Id).Distinct().ToList()
            : [];
        var loadedEpisodes = seriesIds.Count == 0
            ? []
            : await Cards(BaseItems(userId).Where(child => child.ParentId != null && seriesIds.Contains(child.ParentId.Value) && child.Kind == MediaKind.Episode), userId)
                .OrderBy(child => child.SeasonNumber).ThenBy(child => child.EpisodeNumber)
                .ThenBy(child => child.DetectedTitle).ThenBy(child => child.Id)
                .ToListAsync(cancellationToken);

        var episodesBySeries = loadedEpisodes
            .GroupBy(ep => ep.ParentId!.Value)
            .ToDictionary(group => group.Key, group => group.Select(ep => new PlayableMediaItem(ep, ToCatalog(ep, userId))).ToList());

        var results = new List<CollectionBuildResult>(collections.Count);
        foreach (var collection in collections)
        {
            var sortMode = NormalizeSortMode(collection.SortMode, allowNullToDefault: true, fallback: DefaultSortMode(collection));
            var resolvedMembers = BuildResolvedMembers(collection, smartEvaluationByCollection, itemsById, episodesBySeries, sortMode);
            var orderedEntities = resolvedMembers.Select(member => member.Entity).ToList();

            var poster = ResolveCollectionArtworkSummary(collection, ArtworkKind.Poster, orderedEntities);
            var backdrop = ResolveCollectionArtworkSummary(collection, ArtworkKind.Backdrop, orderedEntities);

            var playable = FlattenPlayable(resolvedMembers);
            var allYears = resolvedMembers.SelectMany(member => member.Years).ToList();
            var yearRange = FormatYearRange(allYears);
            var itemCount = playable.Count;
            var watchedCount = playable.Count(item => item.Card.WatchState == CatalogWatchState.Completed);
            var totalRuntimeSeconds = resolvedMembers.Sum(member => member.TotalRuntimeSeconds);
            var genres = resolvedMembers
                .SelectMany(member => member.Card.Genres)
                .Where(genre => !string.IsNullOrWhiteSpace(genre))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Take(20)
                .ToList();

            var summaryItems = (collection.IsSmart
                    ? resolvedMembers.Take(50).Select(member => member.Card)
                    : resolvedMembers.Select(member => member.Card))
                .ToList();
            var totalCount = collection.IsSmart && smartEvaluationByCollection.TryGetValue(collection.Id, out var smartResult)
                ? smartResult.TotalCount
                : resolvedMembers.Count;
            // A list card counts a smart list's matches, since only its first titles were loaded.
            if (collection.IsSmart && !includeMembers) itemCount = totalCount;
            var canEdit = ComputeCanEdit(collection, userId, isAdmin);

            var summary = new CollectionSummary(
                collection.Id,
                collection.Name,
                poster,
                summaryItems,
                IsSmart: collection.IsSmart,
                TotalCount: totalCount,
                IsShared: collection.UserId == null,
                UserId: collection.UserId,
                RulesJson: collection.IsSmart ? collection.SmartRulesJson : null,
                Overview: collection.Overview,
                Backdrop: backdrop,
                Provider: collection.Provider,
                CanEdit: canEdit,
                ItemCount: itemCount,
                WatchedCount: watchedCount,
                YearRange: yearRange,
                SortMode: sortMode);

            var memberDtos = includeMembers
                ? resolvedMembers.Select(member => new CollectionMember(
                    member.MemberId,
                    member.Card.Id,
                    member.Card.Kind,
                    member.Title,
                    member.SeasonNumber,
                    member.Card,
                    member.Episodes?.Select(ep => ep.Card).ToList(),
                    member.WatchedCount,
                    member.ItemCount,
                    member.TotalRuntimeSeconds)).ToList()
                : [];
            var nextItem = includeMembers ? ComputeNextItem(playable) : null;

            var detail = new CollectionDetail(
                collection.Id,
                collection.Name,
                collection.Overview,
                poster,
                backdrop,
                collection.Provider,
                canEdit,
                collection.IsSmart,
                collection.UserId == null,
                collection.UserId,
                collection.IsSmart ? collection.SmartRulesJson : null,
                sortMode,
                itemCount,
                watchedCount,
                yearRange,
                totalRuntimeSeconds,
                genres,
                memberDtos,
                nextItem);

            results.Add(new CollectionBuildResult(summary, detail, orderedEntities));
        }

        return results;
    }

    private static List<ResolvedMember> BuildResolvedMembers(
        MediaCollectionRecord collection,
        Dictionary<Guid, (IReadOnlyList<Guid> Ids, int TotalCount, string SortMode)> smartEvaluations,
        IReadOnlyDictionary<Guid, PlayableMediaItem> itemsById,
        IReadOnlyDictionary<Guid, List<PlayableMediaItem>> episodesBySeries,
        string sortMode)
    {
        IEnumerable<(Guid MemberId, Guid MediaId, int? SeasonNumber, int SortOrder)> inputs = collection.IsSmart
            && smartEvaluations.TryGetValue(collection.Id, out var smart)
            ? smart.Ids.Select((id, index) => (id, id, (int?)null, index))
            : collection.Members.OrderBy(member => member.SortOrder).Select(m => (m.Id, m.MediaItemId, m.SeasonNumber, m.SortOrder));

        var resolved = new List<ResolvedMember>();
        foreach (var (memberId, mediaId, seasonNumber, sortOrder) in inputs)
        {
            if (!itemsById.TryGetValue(mediaId, out var entry)) continue;
            var card = entry.Card;
            var entity = entry.Entity;
            var defaultEpisodeMinutes = MetadataPresentation.ToSummary(entity).RuntimeMinutes;

            if (seasonNumber.HasValue)
            {
                var seasonEpisodes = (episodesBySeries.GetValueOrDefault(mediaId) ?? [])
                    .Where(ep => ep.Card.SeasonNumber == seasonNumber.Value)
                    .ToList();
                var seasonTitle = seasonNumber.Value == 0 ? $"{card.Title} — Specials" : $"{card.Title} — Season {seasonNumber.Value}";
                var years = seasonEpisodes.Select(ep => ep.Card.Year).OfType<int>().ToList();
                if (years.Count == 0 && card.Year.HasValue) years.Add(card.Year.Value);
                var minYear = years.Count > 0 ? years.Min() : card.Year;
                var runtimeSec = seasonEpisodes.Sum(ep => ComputeRuntimeSeconds(ep.Entity, ep.Card, defaultEpisodeMinutes));
                var watched = seasonEpisodes.Count(ep => ep.Card.WatchState == CatalogWatchState.Completed);
                var seasonCard = card with { SeasonNumber = seasonNumber.Value, WatchState = AggregateEpisodeStates(seasonEpisodes) };
                resolved.Add(new ResolvedMember(memberId, entity, seasonCard, seasonNumber, sortOrder, seasonTitle, minYear, seasonEpisodes, seasonEpisodes.Count, watched, runtimeSec, years));
            }
            else if (card.Kind == MediaKind.Series)
            {
                var seriesEpisodes = (episodesBySeries.GetValueOrDefault(mediaId) ?? [])
                    .Where(ep => ep.Card.SeasonNumber > 0)
                    .ToList();
                var years = seriesEpisodes.Select(ep => ep.Card.Year).OfType<int>().ToList();
                if (card.Year.HasValue) years.Add(card.Year.Value);
                var minYear = years.Count > 0 ? years.Min() : card.Year;
                var runtimeSec = seriesEpisodes.Sum(ep => ComputeRuntimeSeconds(ep.Entity, ep.Card, defaultEpisodeMinutes));
                var watched = seriesEpisodes.Count(ep => ep.Card.WatchState == CatalogWatchState.Completed);
                resolved.Add(new ResolvedMember(memberId, entity, card, null, sortOrder, card.Title, minYear, seriesEpisodes, seriesEpisodes.Count, watched, runtimeSec, years));
            }
            else
            {
                var years = card.Year.HasValue ? (List<int>)[card.Year.Value] : [];
                var runtimeSec = ComputeRuntimeSeconds(entity, card);
                var watched = card.WatchState == CatalogWatchState.Completed ? 1 : 0;
                resolved.Add(new ResolvedMember(memberId, entity, card, null, sortOrder, card.Title, card.Year, null, 1, watched, runtimeSec, years));
            }
        }

        if (collection.IsSmart || sortMode == "custom") return resolved;
        if (sortMode == "release")
        {
            return [.. resolved
                .OrderBy(m => m.MinYear ?? int.MaxValue)
                .ThenBy(m => m.SeasonNumber ?? int.MinValue)
                .ThenBy(m => m.Card.EpisodeNumber ?? int.MinValue)
                .ThenBy(m => m.Title, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(m => m.SortOrder)];
        }
        return [.. resolved
            .OrderBy(m => m.Title, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(m => m.SeasonNumber ?? int.MinValue)
            .ThenBy(m => m.Card.EpisodeNumber ?? int.MinValue)
            .ThenBy(m => m.SortOrder)];
    }

    private static List<PlayableMediaItem> FlattenPlayable(IReadOnlyList<ResolvedMember> members)
    {
        var list = new List<PlayableMediaItem>();
        var seen = new HashSet<Guid>();
        foreach (var member in members)
        {
            if (member.Episodes is not null)
            {
                foreach (var episode in member.Episodes)
                {
                    if (seen.Add(episode.Card.Id)) list.Add(episode);
                }
            }
            else if (seen.Add(member.Card.Id))
            {
                list.Add(new PlayableMediaItem(member.Entity, member.Card));
            }
        }
        return list;
    }

    private static CollectionNextResponse? ComputeNextItem(IReadOnlyList<PlayableMediaItem> playable)
    {
        if (playable.Count == 0) return null;

        var lastPlayedIndex = -1;
        DateTimeOffset lastPlayedAt = DateTimeOffset.MinValue;
        for (var i = 0; i < playable.Count; i++)
        {
            var playedAt = playable[i].Card.Progress?.LastPlayedAt;
            if (playedAt.HasValue && (lastPlayedIndex < 0 || playedAt.Value > lastPlayedAt))
            {
                lastPlayedAt = playedAt.Value;
                lastPlayedIndex = i;
            }
        }

        var targetIndex = -1;
        if (lastPlayedIndex >= 0)
        {
            var lastProgress = playable[lastPlayedIndex].Card.Progress!;
            if (!lastProgress.IsCompleted && lastProgress.PositionMilliseconds > 0)
            {
                targetIndex = lastPlayedIndex;
            }
            else
            {
                var startSearch = lastPlayedIndex + (lastProgress.IsCompleted ? 1 : 0);
                for (var i = startSearch; i < playable.Count; i++)
                {
                    if (playable[i].Card.WatchState != CatalogWatchState.Completed)
                    {
                        targetIndex = i;
                        break;
                    }
                }
            }
        }

        if (targetIndex < 0)
        {
            for (var i = 0; i < playable.Count; i++)
            {
                if (playable[i].Card.WatchState != CatalogWatchState.Completed)
                {
                    targetIndex = i;
                    break;
                }
            }
        }

        if (targetIndex < 0) targetIndex = 0;

        var chosen = playable[targetIndex].Card;
        var chosenProgress = chosen.Progress;
        var resume = chosenProgress is { IsCompleted: false, PositionMilliseconds: > 0 };
        var positionMs = resume ? chosenProgress!.PositionMilliseconds : 0L;
        return new CollectionNextResponse(chosen, resume, positionMs, targetIndex, playable.Count);
    }

    private static ArtworkSummary? ResolveCollectionArtworkSummary(
        MediaCollectionRecord collection,
        ArtworkKind kind,
        IReadOnlyList<MediaItem> orderedEntities)
    {
        var preferredId = kind == ArtworkKind.Poster ? collection.PosterAssetId : collection.BackdropAssetId;
        var explicitAsset = collection.Artwork
            .Where(asset => asset.Kind == kind)
            .OrderByDescending(asset => asset.Id == preferredId)
            .ThenByDescending(asset => asset.IsManual)
            .ThenByDescending(asset => asset.Revision)
            .FirstOrDefault();
        if (explicitAsset is not null)
        {
            return CollectionArtworkService.ToSummary(collection.Id, explicitAsset);
        }

        if (kind == ArtworkKind.Backdrop)
        {
            var memberBackdrop = orderedEntities
                .Select(entity => CollectionArtworkService.SelectMemberAsset(entity, ArtworkKind.Backdrop))
                .FirstOrDefault(asset => asset is not null);
            if (memberBackdrop is null) return null;
            var backdropRev = CollectionArtworkService.ComputeFallbackRevision(collection.UpdatedAt, [(memberBackdrop.Id, memberBackdrop.Revision)]);
            return new ArtworkSummary(
                collection.Id,
                ArtworkKind.Backdrop,
                $"/api/v1/artwork/collection/{collection.Id}?kind=backdrop",
                memberBackdrop.ContentType,
                memberBackdrop.ContentLength,
                backdropRev);
        }

        var posters = orderedEntities
            .Select(entity => CollectionArtworkService.SelectMemberAsset(entity, ArtworkKind.Poster))
            .OfType<ArtworkAsset>()
            .DistinctBy(asset => asset.Id)
            .Take(4)
            .ToList();
        if (posters.Count == 0) return null;
        var rev = CollectionArtworkService.ComputeFallbackRevision(collection.UpdatedAt, posters.Select(p => (p.Id, p.Revision)));
        return new ArtworkSummary(
            collection.Id,
            ArtworkKind.Poster,
            $"/api/v1/artwork/collection/{collection.Id}?kind=poster",
            posters.Count == 1 ? posters[0].ContentType : "image/jpeg",
            posters.Count == 1 ? posters[0].ContentLength : 0,
            rev);
    }

    private static CatalogWatchState AggregateEpisodeStates(IReadOnlyList<PlayableMediaItem> episodes)
    {
        if (episodes.Count == 0) return CatalogWatchState.Unplayed;
        if (episodes.All(ep => ep.Card.WatchState == CatalogWatchState.Completed)) return CatalogWatchState.Completed;
        return episodes.Any(ep => ep.Card.WatchState != CatalogWatchState.Unplayed)
            ? CatalogWatchState.InProgress
            : CatalogWatchState.Unplayed;
    }

    private static long ComputeRuntimeSeconds(MediaItem entity, CatalogItemSummary card, int? seriesDefaultMinutes = null)
    {
        var metadataMinutes = MetadataPresentation.ToSummary(entity).RuntimeMinutes;
        if (metadataMinutes is > 0) return metadataMinutes.Value * 60L;
        if (card.Progress is { DurationMilliseconds: > 0 } progress) return progress.DurationMilliseconds / 1000L;
        if (seriesDefaultMinutes is > 0) return seriesDefaultMinutes.Value * 60L;
        return 0L;
    }

    private static string? FormatYearRange(List<int> years)
    {
        if (years.Count == 0) return null;
        var min = years.Min();
        var max = years.Max();
        return min == max ? min.ToString(CultureInfo.InvariantCulture) : string.Create(CultureInfo.InvariantCulture, $"{min}\u2013{max}");
    }

    // EF suppresses recursive MediaItem filters inside correlated navigations.
    // Keep this explicit access boundary in nested episode aggregates as well.
    private IQueryable<Guid> AllowedRegularEpisodeIds() => database.MediaItems
        .Where(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0)
        .Where(child => database.AccessUserId == null || database.AccessWholeCatalog
            || (database.AccessMode == ProfileAccessMode.LegacyLibraries && database.UserLibraryGrants.Any(grant => grant.UserId == database.AccessUserId && grant.LibraryRootId == child.LibraryRootId))
            || (database.AccessMode == ProfileAccessMode.SelectedTitles && database.UserTitleGrants.Any(grant => grant.UserId == database.AccessUserId
                && (grant.MediaItemId == child.Id || grant.MediaItemId == child.ParentId
                    || database.MediaItems.Any(parent => parent.Id == child.ParentId
                        && (parent.ParentId == grant.MediaItemId || database.MediaItems.Any(grandparent => grandparent.Id == parent.ParentId && grandparent.ParentId == grant.MediaItemId))))))
            // A children's profile: an episode follows its season or series, which the MediaItems filter already
            // checks by age. IgnoreQueryFilters would switch off every filter of this query, so it is not used here.
            || (database.AccessAgeLimited && database.MediaItems.Any(parent => parent.Id == child.ParentId)))
        .Select(child => child.Id);

    private IQueryable<MediaItem> BaseItems(Guid userId)
    {
        return database.MediaItems.AsNoTracking()
        .Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
        .Include(item => item.Parent)!.ThenInclude(parent => parent!.Metadata)
            .ThenInclude(metadata => metadata!.Artwork)
        .Include(item => item.Favorites.Where(value => value.UserId == userId))
        .Include(item => item.PlaybackProgress.Where(value => value.UserId == userId))
        .Include(item => item.LibraryRoot)
        .Include(item => item.ContinueWatchingStates.Where(value => value.UserId == userId))
        .Include(item => item.Parent)!.ThenInclude(parent => parent!.ContinueWatchingStates.Where(value => value.UserId == userId));
    }

    // Project only the fields used by cards. Credits, profile artwork, source paths,
    // provider bookkeeping and full information panels belong to the detail query.
    private IQueryable<MediaItem> Cards(IQueryable<MediaItem> query, Guid userId)
    {
        var allowedEpisodes = AllowedRegularEpisodeIds();
        return query.Select(item => new MediaItem
        {
            Id = item.Id,
            Kind = item.Kind,
            ParentId = item.ParentId,
            LibraryRootId = item.LibraryRootId,
            LibraryRoot = new LibraryRoot { Availability = item.LibraryRoot.Availability, Path = item.LibraryRoot.Path },
            SourcePath = item.SourcePath,
            ContinueWatchingStates = item.ContinueWatchingStates.Where(state => state.UserId == userId).Select(state => new ContinueWatchingState { IsHidden = state.IsHidden }).ToList(),
            CardWatchState = item.Kind == MediaKind.Series
                ? item.Children.Any(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0 && allowedEpisodes.Contains(child.Id))
                    && !item.Children.Any(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0 && allowedEpisodes.Contains(child.Id)
                        && !child.PlaybackProgress.Any(progress => progress.UserId == userId && progress.IsCompleted))
                    ? CatalogWatchState.Completed
                    : item.Children.Any(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0 && allowedEpisodes.Contains(child.Id)
                        && child.PlaybackProgress.Any(progress => progress.UserId == userId && (progress.IsCompleted || progress.PositionMilliseconds > 0)))
                        ? CatalogWatchState.InProgress : CatalogWatchState.Unplayed
                : item.PlaybackProgress.Any(progress => progress.UserId == userId && progress.IsCompleted) ? CatalogWatchState.Completed
                    : item.PlaybackProgress.Any(progress => progress.UserId == userId && progress.PositionMilliseconds > 0) ? CatalogWatchState.InProgress : CatalogWatchState.Unplayed,
            DetectedTitle = item.DetectedTitle,
            OverrideTitle = item.OverrideTitle,
            Year = item.Year,
            Availability = item.Availability,
            CreatedAt = item.CreatedAt,
            SeasonNumber = item.SeasonNumber,
            EpisodeNumber = item.EpisodeNumber,
            Category = item.Category,
            Parent = item.Parent == null ? null : new MediaItem
            {
                Id = item.Parent.Id,
                ContinueWatchingStates = item.Parent.ContinueWatchingStates.Where(state => state.UserId == userId).Select(state => new ContinueWatchingState { IsHidden = state.IsHidden }).ToList(),
                DetectedTitle = item.Parent.DetectedTitle,
                OverrideTitle = item.Parent.OverrideTitle,
                Metadata = item.Parent.Metadata == null ? null : new MediaMetadata
                {
                    ManualTitle = item.Parent.Metadata.ManualTitle,
                    ProviderTitle = item.Parent.Metadata.ProviderTitle,
                    ManualFieldsJson = item.Parent.Metadata.ManualFieldsJson,
                    ManualPosterId = item.Parent.Metadata.ManualPosterId,
                    ManualBackdropId = item.Parent.Metadata.ManualBackdropId,
                    Artwork = item.Parent.Metadata.Artwork.Where(art => art.Kind == ArtworkKind.Poster || art.Kind == ArtworkKind.Backdrop).Select(art => new ArtworkAsset
                    { Id = art.Id, Kind = art.Kind, IsManual = art.IsManual, ContentType = art.ContentType, ContentLength = art.ContentLength, Revision = art.Revision }).ToList(),
                },
            },
            Metadata = item.Metadata == null ? null : new MediaMetadata
            {
                MediaItemId = item.Id,
                ManualTitle = item.Metadata.ManualTitle,
                ProviderTitle = item.Metadata.ProviderTitle,
                ManualOriginalTitle = item.Metadata.ManualOriginalTitle,
                ProviderOriginalTitle = item.Metadata.ProviderOriginalTitle,
                ManualOverview = item.Metadata.ManualOverview,
                ProviderOverview = item.Metadata.ProviderOverview,
                ManualReleaseDate = item.Metadata.ManualReleaseDate,
                ManualReleaseYear = item.Metadata.ManualReleaseYear,
                ManualRuntimeMinutes = item.Metadata.ManualRuntimeMinutes,
                ProviderRuntimeMinutes = item.Metadata.ProviderRuntimeMinutes,
                ManualFieldsJson = item.Metadata.ManualFieldsJson,
                ManualPosterId = item.Metadata.ManualPosterId,
                ManualBackdropId = item.Metadata.ManualBackdropId,
                ProviderReleaseDate = item.Metadata.ProviderReleaseDate,
                ManualGenresJson = item.Metadata.ManualGenresJson,
                ProviderGenresJson = item.Metadata.ProviderGenresJson,
                Artwork = item.Metadata.Artwork.Where(art => art.Kind != ArtworkKind.Profile).Select(art => new ArtworkAsset
                { Id = art.Id, Kind = art.Kind, IsManual = art.IsManual, ContentType = art.ContentType, ContentLength = art.ContentLength, Revision = art.Revision }).ToList(),
            },
            Favorites = item.Favorites.Where(favorite => favorite.UserId == userId).Select(favorite => new UserFavorite { UserId = favorite.UserId }).ToList(),
            PlaybackProgress = item.PlaybackProgress.Where(progress => progress.UserId == userId).Select(progress => new PlaybackProgress
            {
                UserId = progress.UserId,
                User = null!,
                MediaItem = null!,
                PositionMilliseconds = progress.PositionMilliseconds,
                DurationMilliseconds = progress.DurationMilliseconds,
                IsCompleted = progress.IsCompleted,
                LastPlayedAt = progress.LastPlayedAt,
                UpdatedAt = progress.UpdatedAt,
                Revision = progress.Revision,
                LastMutationId = progress.LastMutationId,
            }).ToList(),
        });
    }

    // PresentationService is scoped to one request. Reuse the location probe within
    // that response, while every file is still checked and the next request probes afresh.
    private readonly Dictionary<string, LibraryAvailability> libraryAvailabilityByPath = new(StringComparer.Ordinal);

    private CatalogItemSummary ToCatalog(MediaItem item, Guid userId)
    {
        var metadata = MetadataPresentation.ToSummary(item);
        var progress = item.PlaybackProgress.FirstOrDefault(value => value.UserId == userId);
        var libraryAvailability = string.IsNullOrEmpty(item.LibraryRoot?.Path) ? item.LibraryRoot?.Availability ?? LibraryAvailability.Unknown
            : LibraryAvailabilityFor(item.LibraryRoot.Path);
        var availability = item.Kind != MediaKind.Series && libraryAvailability == LibraryAvailability.Available && !string.IsNullOrEmpty(item.SourcePath)
            ? LibraryReachabilityService.ProbeFile(item.SourcePath) : item.Availability;
        return new CatalogItemSummary(
            item.Id, item.Kind, metadata.Title, metadata.OriginalTitle, metadata.Year, metadata.Overview,
            metadata.Genres, MetadataPresentation.CardPoster(item, metadata), metadata.Backdrop ?? metadata.Still, availability,
            item.Favorites.Any(value => value.UserId == userId),
            progress is null ? null : new PlaybackProgressResponse(item.Id, progress.PositionMilliseconds, progress.DurationMilliseconds, progress.IsCompleted, progress.LastPlayedAt, progress.UpdatedAt, progress.Revision, progress.LastMutationId),
            item.CreatedAt,
            item.Parent is null ? null : EffectiveTitle(item.Parent),
            item.SeasonNumber,
            item.EpisodeNumber,
            item.ParentId,
            item.CardWatchState ?? (item.Kind == MediaKind.Series ? LibraryStateService.Aggregate(item.Children.Count, item.Children.SelectMany(child => child.PlaybackProgress).Where(value => value.UserId == userId))
                : progress is { IsCompleted: true } ? CatalogWatchState.Completed : progress is { PositionMilliseconds: > 0 } ? CatalogWatchState.InProgress : CatalogWatchState.Unplayed),
            libraryAvailability,
            (item.Kind == MediaKind.Episode ? item.Parent?.ContinueWatchingStates : item.ContinueWatchingStates)?.Any(state => state.IsHidden) ?? false);
    }

    private LibraryAvailability LibraryAvailabilityFor(string path)
    {
        if (!libraryAvailabilityByPath.TryGetValue(path, out var availability))
        {
            availability = LibraryReachabilityService.Probe(path);
            libraryAvailabilityByPath.Add(path, availability);
        }
        return availability;
    }

    private IQueryable<MediaItem> ApplyFilters(
        IQueryable<MediaItem> query,
        Guid userId,
        CatalogQuery request)
    {
        var allowedEpisodes = AllowedRegularEpisodeIds();
        if (request.Kind.HasValue) query = query.Where(item => item.Kind == request.Kind.Value);
        if (request.LibraryId.HasValue) query = query.Where(item => item.LibraryRootId == request.LibraryId.Value);
        if (request.Availability.HasValue) query = query.Where(item => item.Availability == request.Availability.Value);
        if (request.YearFrom.HasValue) query = query.Where(item => (item.Kind == MediaKind.Episode && item.Parent != null
                    ? (item.Parent.Metadata != null && item.Parent.Metadata.ManualFieldsJson.Contains("\"releaseYear\"") ? item.Parent.Metadata.ManualReleaseYear : item.Parent.Year)
                    : item.Metadata != null && item.Metadata.ManualFieldsJson.Contains("\"releaseYear\"") ? item.Metadata.ManualReleaseYear : item.Year) >= request.YearFrom.Value);
        if (request.YearTo.HasValue) query = query.Where(item => (item.Kind == MediaKind.Episode && item.Parent != null
                    ? (item.Parent.Metadata != null && item.Parent.Metadata.ManualFieldsJson.Contains("\"releaseYear\"") ? item.Parent.Metadata.ManualReleaseYear : item.Parent.Year)
                    : item.Metadata != null && item.Metadata.ManualFieldsJson.Contains("\"releaseYear\"") ? item.Metadata.ManualReleaseYear : item.Year) <= request.YearTo.Value);
        if (request.Favorite.HasValue)
        {
            query = request.Favorite.Value
                ? query.Where(item => (item.Favorites.Any(value => value.UserId == userId)
                    || (item.Kind == MediaKind.Episode && item.Parent != null && item.Parent.Favorites.Any(value => value.UserId == userId))))
                : query.Where(item => !item.Favorites.Any(value => value.UserId == userId)
                    && !(item.Kind == MediaKind.Episode && item.Parent != null && item.Parent.Favorites.Any(value => value.UserId == userId)));
        }
        if (!string.IsNullOrWhiteSpace(request.Genre))
        {
            var genre = $"%\"{EscapeLike(request.Genre.Trim())}\"%";
            query = query.Where(item => (item.Metadata != null
                && ((item.Metadata.ManualGenresJson != null
                        && EF.Functions.Like(item.Metadata.ManualGenresJson, genre, "\\"))
                    || (item.Metadata.ManualGenresJson == null
                        && EF.Functions.Like(item.Metadata.ProviderGenresJson, genre, "\\"))))
                || (item.Kind == MediaKind.Episode && item.Parent != null && item.Parent.Metadata != null
                    && ((item.Parent.Metadata.ManualGenresJson != null && EF.Functions.Like(item.Parent.Metadata.ManualGenresJson, genre, "\\"))
                        || (item.Parent.Metadata.ManualGenresJson == null && EF.Functions.Like(item.Parent.Metadata.ProviderGenresJson, genre, "\\")))));
        }
        if (request.WatchState.HasValue)
        {
            query = request.WatchState.Value switch
            {
                CatalogWatchState.Unplayed => query.Where(item => item.Kind == MediaKind.Series
                    ? !item.Children.Any(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0 && allowedEpisodes.Contains(child.Id)
                        && child.PlaybackProgress.Any(progress => progress.UserId == userId && (progress.IsCompleted || progress.PositionMilliseconds > 0)))
                    : !item.PlaybackProgress.Any(progress => progress.UserId == userId && (progress.IsCompleted || progress.PositionMilliseconds > 0))),
                CatalogWatchState.InProgress => query.Where(item => item.Kind == MediaKind.Series
                    ? item.Children.Any(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0 && allowedEpisodes.Contains(child.Id)
                        && child.PlaybackProgress.Any(progress => progress.UserId == userId && (progress.IsCompleted || progress.PositionMilliseconds > 0)))
                      && item.Children.Any(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0 && allowedEpisodes.Contains(child.Id)
                        && !child.PlaybackProgress.Any(progress => progress.UserId == userId && progress.IsCompleted))
                    : item.PlaybackProgress.Any(progress => progress.UserId == userId && progress.PositionMilliseconds > 0 && !progress.IsCompleted)),
                CatalogWatchState.Completed => query.Where(item => item.Kind == MediaKind.Series
                    ? item.Children.Any(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0 && allowedEpisodes.Contains(child.Id))
                      && !item.Children.Any(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0 && allowedEpisodes.Contains(child.Id)
                        && !child.PlaybackProgress.Any(progress => progress.UserId == userId && progress.IsCompleted))
                    : item.PlaybackProgress.Any(progress => progress.UserId == userId && progress.IsCompleted)),
                _ => query,
            };
        }

        return query;
    }

    private IOrderedQueryable<MediaItem> Order(
        IQueryable<MediaItem> query,
        Guid userId,
        CatalogSort sort,
        SortDirection direction)
    {
        var allowedEpisodes = AllowedRegularEpisodeIds();
        var descending = direction == SortDirection.Descending;
        return sort switch
        {
            CatalogSort.DateAdded => descending
                ? query.OrderByDescending(item => item.CreatedAt).ThenByDescending(item => item.Id)
                : query.OrderBy(item => item.CreatedAt).ThenBy(item => item.Id),
            CatalogSort.ReleaseYear => descending
                ? query.OrderByDescending(item => item.Kind == MediaKind.Episode && item.Parent != null
                    ? (item.Parent.Metadata != null && item.Parent.Metadata.ManualFieldsJson.Contains("\"releaseYear\"") ? item.Parent.Metadata.ManualReleaseYear : item.Parent.Year)
                    : item.Metadata != null && item.Metadata.ManualFieldsJson.Contains("\"releaseYear\"") ? item.Metadata.ManualReleaseYear : item.Year).ThenBy(item => item.DetectedTitle).ThenBy(item => item.Id)
                : query.OrderBy(item => item.Kind == MediaKind.Episode && item.Parent != null
                    ? (item.Parent.Metadata != null && item.Parent.Metadata.ManualFieldsJson.Contains("\"releaseYear\"") ? item.Parent.Metadata.ManualReleaseYear : item.Parent.Year)
                    : item.Metadata != null && item.Metadata.ManualFieldsJson.Contains("\"releaseYear\"") ? item.Metadata.ManualReleaseYear : item.Year).ThenBy(item => item.DetectedTitle).ThenBy(item => item.Id),
            CatalogSort.LastPlayed => descending
                ? query.OrderByDescending(item => item.Kind == MediaKind.Series
                    ? item.Children.Where(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0 && allowedEpisodes.Contains(child.Id)).SelectMany(child => child.PlaybackProgress).Where(progress => progress.UserId == userId).Max(progress => progress.LastPlayedAt)
                    : item.PlaybackProgress.Where(progress => progress.UserId == userId).Select(progress => progress.LastPlayedAt).FirstOrDefault()).ThenBy(item => item.Id)
                : query.OrderBy(item => item.Kind == MediaKind.Series
                    ? item.Children.Where(child => child.Kind == MediaKind.Episode && child.SeasonNumber > 0 && allowedEpisodes.Contains(child.Id)).SelectMany(child => child.PlaybackProgress).Where(progress => progress.UserId == userId).Max(progress => progress.LastPlayedAt)
                    : item.PlaybackProgress.Where(progress => progress.UserId == userId).Select(progress => progress.LastPlayedAt).FirstOrDefault()).ThenBy(item => item.Id),
            _ => descending
                ? query.OrderByDescending(item => item.Metadata != null ? item.Metadata.ManualTitle ?? item.Metadata.ProviderTitle ?? item.OverrideTitle ?? item.DetectedTitle : item.OverrideTitle ?? item.DetectedTitle).ThenByDescending(item => item.Id)
                : query.OrderBy(item => item.Metadata != null ? item.Metadata.ManualTitle ?? item.Metadata.ProviderTitle ?? item.OverrideTitle ?? item.DetectedTitle : item.OverrideTitle ?? item.DetectedTitle).ThenBy(item => item.Id),
        };
    }

    private static void ValidateQuery(CatalogQuery request)
    {
        ValidatePage(request.Offset, request.Limit);
        if (request.YearFrom is < 1800 or > 3000 || request.YearTo is < 1800 or > 3000)
            throw new MetadataException("invalid_year_range", "Years must be between 1800 and 3000.", StatusCodes.Status400BadRequest);
        if (request.YearFrom.HasValue && request.YearTo.HasValue && request.YearFrom > request.YearTo)
            throw new MetadataException("invalid_year_range", "yearFrom cannot be greater than yearTo.", StatusCodes.Status400BadRequest);
        if (request.Genre is { Length: > 100 })
            throw new MetadataException("invalid_genre", "Genre must contain 100 characters or fewer.", StatusCodes.Status400BadRequest);
    }

    private static string EscapeLike(string value) => value
        .Replace("\\", "\\\\", StringComparison.Ordinal)
        .Replace("%", "\\%", StringComparison.Ordinal)
        .Replace("_", "\\_", StringComparison.Ordinal);

    private static string EffectiveTitle(MediaItem item) => item.Metadata?.ManualTitle ?? item.Metadata?.ProviderTitle ?? item.OverrideTitle ?? item.DetectedTitle;
    private static int StableIndex(Guid userId, DateTimeOffset hour, int count)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes($"{userId:N}:{hour:O}"));
        return (int)(BitConverter.ToUInt32(bytes, 0) % count);
    }
    private static void ValidatePage(int offset, int limit)
    {
        if (offset < 0 || limit is < 1 or > ServerFeatures.MaximumCatalogPageSize)
            throw new MetadataException("invalid_page",
                $"Offset must be zero or greater and limit must be between 1 and {ServerFeatures.MaximumCatalogPageSize}.", StatusCodes.Status400BadRequest);
    }
}
