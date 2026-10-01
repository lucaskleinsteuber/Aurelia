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

    public async Task<PagedResponse<CatalogItemSummary>> SearchAsync(Guid userId, string query, int offset, int limit, CancellationToken cancellationToken) =>
        await SearchAsync(userId, query, new CatalogQuery(Offset: offset, Limit: limit), cancellationToken);

    public async Task<PagedResponse<CatalogItemSummary>> SearchAsync(
        Guid userId,
        string query,
        CatalogQuery request,
        CancellationToken cancellationToken)
    {
        ValidateQuery(request);
        var term = query.Trim();
        if (term.Length is < 1 or > 200)
            throw new MetadataException("invalid_search", "Search text must contain between 1 and 200 characters.", StatusCodes.Status400BadRequest);
        if (request.Kind is null && request.LibraryId is null && request.Genre is null
            && request.Availability is null && request.Favorite is null && request.WatchState is null
            && request.YearFrom is null && request.YearTo is null
            && request.Sort == CatalogSort.Title && request.Direction == SortDirection.Ascending)
        {
            var result = await searchIndex.SearchAsync(term, request.Offset, request.Limit, cancellationToken);
            var indexedItems = await Cards(BaseItems(userId).Where(item => result.Ids.Contains(item.Id)), userId)
                .ToListAsync(cancellationToken);
            var byId = indexedItems.ToDictionary(item => item.Id);
            return new PagedResponse<CatalogItemSummary>(
                result.Ids.Where(byId.ContainsKey).Select(id => ToCatalog(byId[id], userId)).ToList(),
                request.Offset,
                request.Limit,
                result.Total);
        }

        var pattern = $"%{EscapeLike(term)}%";
        var prefix = $"{EscapeLike(term)}%";
        var matches = BaseItems(userId)
            .Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series || item.Kind == MediaKind.Episode)
            .Where(item => EF.Functions.Like(item.DetectedTitle, pattern, "\\")
                || (item.OverrideTitle != null && EF.Functions.Like(item.OverrideTitle, pattern, "\\"))
                || (item.Metadata != null && (
                    (item.Metadata.ManualTitle != null && EF.Functions.Like(item.Metadata.ManualTitle, pattern, "\\"))
                    || (item.Metadata.ProviderTitle != null && EF.Functions.Like(item.Metadata.ProviderTitle, pattern, "\\"))
                    || (item.Metadata.ManualOriginalTitle != null && EF.Functions.Like(item.Metadata.ManualOriginalTitle, pattern, "\\"))
                    || (item.Metadata.ProviderOriginalTitle != null && EF.Functions.Like(item.Metadata.ProviderOriginalTitle, pattern, "\\"))
                    || EF.Functions.Like(item.Metadata.ProviderGenresJson, pattern, "\\")
                    || (item.Metadata.ManualGenresJson != null && EF.Functions.Like(item.Metadata.ManualGenresJson, pattern, "\\"))
                    || item.Metadata.Credits.Any(credit => EF.Functions.Like(credit.Name, pattern, "\\")
                        || (credit.Character != null && EF.Functions.Like(credit.Character, pattern, "\\")))))
                || (item.Parent != null && EF.Functions.Like(item.Parent.DetectedTitle, pattern, "\\")));
        matches = ApplyFilters(matches, userId, request);
        var total = await matches.CountAsync(cancellationToken);
        var ordered = matches
            .OrderByDescending(item => EF.Functions.Like(item.DetectedTitle, prefix, "\\")
                || (item.OverrideTitle != null && EF.Functions.Like(item.OverrideTitle, prefix, "\\")))
            .ThenBy(item => item.DetectedTitle)
            .ThenBy(item => item.Id);
        var items = await Cards(ordered.Skip(request.Offset).Take(request.Limit), userId).ToListAsync(cancellationToken);
        return new PagedResponse<CatalogItemSummary>(items.Select(item => ToCatalog(item, userId)).ToList(), request.Offset, request.Limit, total);
    }

    public async Task<HomeResponse> HomeAsync(Guid userId, CancellationToken cancellationToken)
    {
        var available = BaseItems(userId)
            .Where(item => item.Availability == MediaAvailability.Available);
        var topLevel = available.Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series);
        var continueItems = await Cards(available
            .Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Episode)
            .Where(item => item.PlaybackProgress.Any(progress => progress.UserId == userId
                && !progress.IsCompleted && progress.PositionMilliseconds > 10_000))
            .OrderByDescending(item => item.PlaybackProgress
                .Where(progress => progress.UserId == userId)
                .Select(progress => progress.LastPlayedAt)
                .First())
            .ThenBy(item => item.Id).Take(20), userId).ToListAsync(cancellationToken);
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
            continueItems.Select(item => ToCatalog(item, userId)).ToList(),
            recentItems.Select(item => ToCatalog(item, userId)).ToList(),
            favoriteItems.Select(item => ToCatalog(item, userId)).ToList(),
            await CollectionsAsync(userId, 0, 30, cancellationToken),
            hour.AddHours(1));
    }

    public async Task<IReadOnlyList<CollectionSummary>> CollectionsAsync(Guid userId, int offset, int limit, CancellationToken cancellationToken)
    {
        ValidatePage(offset, limit);
        var collections = await database.MediaCollections.AsNoTracking()
            .Include(collection => collection.Members).ThenInclude(member => member.MediaItem).ThenInclude(item => item.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
            .Include(collection => collection.Members).ThenInclude(member => member.MediaItem).ThenInclude(item => item.Favorites)
            .Include(collection => collection.Members).ThenInclude(member => member.MediaItem).ThenInclude(item => item.PlaybackProgress)
            .Where(collection => collection.Members.Count >= 2)
            .OrderBy(collection => collection.Name).ThenBy(collection => collection.Id).Skip(offset).Take(limit).ToListAsync(cancellationToken);
        return collections.Select(collection => new CollectionSummary(
            collection.Id,
            collection.Name,
            collection.Members.OrderBy(member => member.SortOrder).Select(member => member.MediaItem.Metadata?.Artwork.FirstOrDefault(asset => asset.Kind == ArtworkKind.Poster)).FirstOrDefault(asset => asset is not null) is { } poster ? MetadataPresentation.ToArtwork(poster) : null,
            collection.Members.OrderBy(member => member.SortOrder).Select(member => ToCatalog(member.MediaItem, userId)).ToList())).ToList();
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

    private IQueryable<MediaItem> BaseItems(Guid userId) => database.MediaItems.AsNoTracking()
        .Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
        .Include(item => item.Parent)!.ThenInclude(parent => parent!.Metadata)
        .Include(item => item.Favorites.Where(value => value.UserId == userId))
        .Include(item => item.PlaybackProgress.Where(value => value.UserId == userId));

    // Project only the fields used by cards. Credits, profile artwork, source paths,
    // provider bookkeeping and full information panels belong to the detail query.
    private static IQueryable<MediaItem> Cards(IQueryable<MediaItem> query, Guid userId) => query.Select(item => new MediaItem
    {
        Id = item.Id,
        Kind = item.Kind,
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
            ProviderReleaseDate = item.Metadata.ProviderReleaseDate,
            ManualGenresJson = item.Metadata.ManualGenresJson,
            ProviderGenresJson = item.Metadata.ProviderGenresJson,
            Artwork = item.Metadata.Artwork.Where(art => art.Kind != ArtworkKind.Profile).Select(art => new ArtworkAsset
            { Id = art.Id, Kind = art.Kind, ContentType = art.ContentType, ContentLength = art.ContentLength }).ToList(),
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
        }).ToList(),
    });

    private static CatalogItemSummary ToCatalog(MediaItem item, Guid userId)
    {
        var metadata = MetadataPresentation.ToSummary(item);
        var progress = item.PlaybackProgress.FirstOrDefault(value => value.UserId == userId);
        return new CatalogItemSummary(
            item.Id, item.Kind, metadata.Title, metadata.OriginalTitle, metadata.Year, metadata.Overview,
            metadata.Genres, metadata.Poster, metadata.Backdrop ?? metadata.Still, item.Availability,
            item.Favorites.Any(value => value.UserId == userId),
            progress is null ? null : new PlaybackProgressResponse(item.Id, progress.PositionMilliseconds, progress.DurationMilliseconds, progress.IsCompleted, progress.LastPlayedAt, progress.UpdatedAt),
            item.CreatedAt,
            item.Parent is null ? null : EffectiveTitle(item.Parent),
            item.SeasonNumber,
            item.EpisodeNumber);
    }

    private static string SearchText(MediaItem item)
    {
        var metadata = item.Metadata;
        return string.Join('\n', new[]
        {
            item.OverrideTitle, item.DetectedTitle, metadata?.ManualTitle, metadata?.ProviderTitle,
            metadata?.ManualOriginalTitle, metadata?.ProviderOriginalTitle, metadata?.ManualGenresJson,
            metadata?.ProviderGenresJson,
            metadata is null ? null : string.Join(' ', metadata.Credits.Select(credit => credit.Name)),
            item.Parent is null ? null : EffectiveTitle(item.Parent),
            item.SeasonNumber is null ? null : $"Season {item.SeasonNumber}",
            item.EpisodeNumber is null ? null : $"Episode {item.EpisodeNumber}",
        }.Where(value => !string.IsNullOrWhiteSpace(value)));
    }

    private static IQueryable<MediaItem> ApplyFilters(
        IQueryable<MediaItem> query,
        Guid userId,
        CatalogQuery request)
    {
        if (request.Kind.HasValue) query = query.Where(item => item.Kind == request.Kind.Value);
        if (request.LibraryId.HasValue) query = query.Where(item => item.LibraryRootId == request.LibraryId.Value);
        if (request.Availability.HasValue) query = query.Where(item => item.Availability == request.Availability.Value);
        if (request.YearFrom.HasValue) query = query.Where(item => item.Year >= request.YearFrom.Value);
        if (request.YearTo.HasValue) query = query.Where(item => item.Year <= request.YearTo.Value);
        if (request.Favorite.HasValue)
        {
            query = request.Favorite.Value
                ? query.Where(item => item.Favorites.Any(value => value.UserId == userId))
                : query.Where(item => !item.Favorites.Any(value => value.UserId == userId));
        }
        if (!string.IsNullOrWhiteSpace(request.Genre))
        {
            var genre = $"%\"{EscapeLike(request.Genre.Trim())}\"%";
            query = query.Where(item => item.Metadata != null
                && ((item.Metadata.ManualGenresJson != null
                        && EF.Functions.Like(item.Metadata.ManualGenresJson, genre, "\\"))
                    || (item.Metadata.ManualGenresJson == null
                        && EF.Functions.Like(item.Metadata.ProviderGenresJson, genre, "\\"))));
        }
        if (request.WatchState.HasValue)
        {
            query = request.WatchState.Value switch
            {
                CatalogWatchState.Unplayed => query.Where(item =>
                    !item.PlaybackProgress.Any(progress => progress.UserId == userId
                        && progress.PositionMilliseconds > 0)),
                CatalogWatchState.InProgress => query.Where(item =>
                    item.PlaybackProgress.Any(progress => progress.UserId == userId
                        && progress.PositionMilliseconds > 0 && !progress.IsCompleted)),
                CatalogWatchState.Completed => query.Where(item =>
                    item.PlaybackProgress.Any(progress => progress.UserId == userId && progress.IsCompleted)),
                _ => query,
            };
        }

        return query;
    }

    private static IOrderedQueryable<MediaItem> Order(
        IQueryable<MediaItem> query,
        Guid userId,
        CatalogSort sort,
        SortDirection direction)
    {
        var descending = direction == SortDirection.Descending;
        return sort switch
        {
            CatalogSort.DateAdded => descending
                ? query.OrderByDescending(item => item.CreatedAt).ThenByDescending(item => item.Id)
                : query.OrderBy(item => item.CreatedAt).ThenBy(item => item.Id),
            CatalogSort.ReleaseYear => descending
                ? query.OrderByDescending(item => item.Year).ThenBy(item => item.DetectedTitle).ThenBy(item => item.Id)
                : query.OrderBy(item => item.Year).ThenBy(item => item.DetectedTitle).ThenBy(item => item.Id),
            CatalogSort.LastPlayed => descending
                ? query.OrderByDescending(item => item.PlaybackProgress
                    .Where(progress => progress.UserId == userId)
                    .Select(progress => (DateTimeOffset?)progress.LastPlayedAt)
                    .FirstOrDefault()).ThenBy(item => item.Id)
                : query.OrderBy(item => item.PlaybackProgress
                    .Where(progress => progress.UserId == userId)
                    .Select(progress => (DateTimeOffset?)progress.LastPlayedAt)
                    .FirstOrDefault()).ThenBy(item => item.Id),
            _ => descending
                ? query.OrderByDescending(item => item.DetectedTitle).ThenByDescending(item => item.Id)
                : query.OrderBy(item => item.DetectedTitle).ThenBy(item => item.Id),
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
        if (offset < 0 || limit is < 1 or > 200)
            throw new MetadataException("invalid_page", "Offset must be zero or greater and limit must be between 1 and 200.", StatusCodes.Status400BadRequest);
    }
}
