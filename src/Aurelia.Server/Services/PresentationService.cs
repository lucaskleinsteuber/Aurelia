using System.Security.Cryptography;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class PresentationService(
    AureliaDbContext database,
    TimeProvider timeProvider,
    MediaSearchIndexService searchIndex)
{
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
        return new CatalogDetailPresentation(
            ToCatalog(item, userId), MetadataPresentation.ToSummary(item), seasons, supplements);
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

    public async Task<HomeResponse> HomeAsync(Guid userId, CancellationToken cancellationToken)
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
        var recentItems = await Cards(topLevel.OrderByDescending(item => item.CreatedAt)
            .ThenBy(item => item.Id).Take(30), userId).ToListAsync(cancellationToken);
        var favoriteItems = await Cards(topLevel
            .Where(item => item.Favorites.Any(value => value.UserId == userId))
            .OrderBy(item => item.DetectedTitle).ThenBy(item => item.Id)
            .Take(30), userId).ToListAsync(cancellationToken);
        var now = timeProvider.GetUtcNow();
        var hour = new DateTimeOffset(now.Year, now.Month, now.Day, now.Hour, 0, 0, TimeSpan.Zero);
        var preferred = topLevel.Where(item => !item.PlaybackProgress.Any(
            progress => progress.UserId == userId && progress.IsCompleted));
        var preferredCount = await preferred.CountAsync(cancellationToken);
        var recommendationQuery = preferredCount == 0 ? topLevel : preferred;
        var recommendationCount = preferredCount == 0
            ? await topLevel.CountAsync(cancellationToken)
            : preferredCount;
        var recommendationItem = recommendationCount == 0
            ? null
            : await Cards(recommendationQuery.OrderBy(item => item.Id)
                .Skip(StableIndex(userId, hour, recommendationCount)).Take(1), userId)
                .SingleAsync(cancellationToken);
        return new HomeResponse(
            recommendationItem is null ? null : ToCatalog(recommendationItem, userId),
            continueItems,
            recentItems.Select(item => ToCatalog(item, userId)).ToList(),
            favoriteItems.Select(item => ToCatalog(item, userId)).ToList(),
            await CollectionsAsync(userId, 0, 30, cancellationToken),
            hour.AddHours(1));
    }

    public async Task<IReadOnlyList<CollectionSummary>> CollectionsAsync(Guid userId, int offset, int limit, CancellationToken cancellationToken)
    {
        ValidatePage(offset, limit);
        var collections = await database.MediaCollections.AsNoTracking()
            .Where(collection => collection.Members.Count >= 2)
            .OrderBy(collection => collection.Name).ThenBy(collection => collection.Id).Skip(offset).Take(limit)
            .Select(collection => new
            {
                collection.Id,
                collection.Name,
                Ids = collection.Members.OrderBy(member => member.SortOrder).Select(member => member.MediaItemId).ToList()
            })
            .ToListAsync(cancellationToken);
        var ids = collections.SelectMany(collection => collection.Ids).Distinct().ToList();
        var cards = ids.Count == 0 ? [] : await SummariesAsync(userId, ids, cancellationToken);
        var byId = cards.ToDictionary(item => item.Id);
        return collections.Select(collection =>
        {
            var members = collection.Ids.Where(byId.ContainsKey).Select(id => byId[id]).ToList();
            return new CollectionSummary(collection.Id, collection.Name, members.Select(item => item.Poster).FirstOrDefault(poster => poster is not null), members);
        }).ToList();
    }

    public async Task<bool> SetFavoriteAsync(Guid userId, Guid mediaId, bool isFavorite, CancellationToken cancellationToken)
    {
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
        var collection = new MediaCollectionRecord
        {
            Id = Guid.NewGuid(),
            IsManual = true,
            CreatedAt = DateTimeOffset.UtcNow,
        };
        await ApplyCollectionAsync(collection, request, cancellationToken);
        database.MediaCollections.Add(collection);
        await database.SaveChangesAsync(cancellationToken);
        return (await CollectionsAsync(userId, 0, 200, cancellationToken)).Single(value => value.Id == collection.Id);
    }

    public async Task<CollectionSummary> UpdateCollectionAsync(Guid userId, Guid id, SaveCollectionRequest request, CancellationToken cancellationToken)
    {
        var collection = await database.MediaCollections.Include(value => value.Members)
            .SingleOrDefaultAsync(value => value.Id == id && value.IsManual, cancellationToken)
            ?? throw new MetadataException("collection_not_found", "The editable collection was not found.", StatusCodes.Status404NotFound);
        await ApplyCollectionAsync(collection, request, cancellationToken);
        await database.SaveChangesAsync(cancellationToken);
        return (await CollectionsAsync(userId, 0, 200, cancellationToken)).Single(value => value.Id == collection.Id);
    }

    public async Task DeleteCollectionAsync(Guid id, CancellationToken cancellationToken)
    {
        var collection = await database.MediaCollections.SingleOrDefaultAsync(value => value.Id == id && value.IsManual, cancellationToken)
            ?? throw new MetadataException("collection_not_found", "The editable collection was not found.", StatusCodes.Status404NotFound);
        database.MediaCollections.Remove(collection);
        await database.SaveChangesAsync(cancellationToken);
    }

    private async Task ApplyCollectionAsync(MediaCollectionRecord collection, SaveCollectionRequest request, CancellationToken cancellationToken)
    {
        var name = request.Name.Trim();
        var ids = request.MediaIds.Distinct().ToList();
        if (name.Length is < 1 or > 512 || ids.Count is < 2 or > 500)
            throw new MetadataException("invalid_collection", "A collection needs a name and between 2 and 500 unique movies or series.", StatusCodes.Status400BadRequest);
        var validIds = await database.MediaItems.Where(item => ids.Contains(item.Id) && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series)).Select(item => item.Id).ToListAsync(cancellationToken);
        if (validIds.Count != ids.Count)
            throw new MetadataException("invalid_collection_items", "Every collection item must be an existing movie or series.", StatusCodes.Status400BadRequest);
        collection.Name = name;
        collection.UpdatedAt = DateTimeOffset.UtcNow;
        var desired = ids.Select((mediaId, index) => (mediaId, index)).ToDictionary(value => value.mediaId, value => value.index);
        foreach (var member in collection.Members.ToList())
        {
            if (!desired.TryGetValue(member.MediaItemId, out var sortOrder))
            {
                collection.Members.Remove(member);
                database.MediaCollectionMembers.Remove(member);
                continue;
            }

            member.SortOrder = sortOrder;
        }

        var existingIds = collection.Members.Select(member => member.MediaItemId).ToHashSet();
        collection.Members.AddRange(ids.Where(mediaId => !existingIds.Contains(mediaId)).Select(mediaId => new MediaCollectionMember
        {
            CollectionId = collection.Id,
            MediaItemId = mediaId,
            SortOrder = desired[mediaId],
        }));
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
                        && (parent.ParentId == grant.MediaItemId || database.MediaItems.Any(grandparent => grandparent.Id == parent.ParentId && grandparent.ParentId == grant.MediaItemId)))))))
        .Select(child => child.Id);

    private IQueryable<MediaItem> BaseItems(Guid userId)
    {
        return database.MediaItems.AsNoTracking()
        .Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
        .Include(item => item.Parent)!.ThenInclude(parent => parent!.Metadata)
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
                { ManualTitle = item.Parent.Metadata.ManualTitle, ProviderTitle = item.Parent.Metadata.ProviderTitle },
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
            metadata.Genres, metadata.Poster, metadata.Backdrop ?? metadata.Still, availability,
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
