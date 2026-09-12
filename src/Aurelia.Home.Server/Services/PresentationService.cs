using System.Security.Cryptography;
using System.Text;
using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Home.Server.Services;

public sealed class PresentationService(AureliaHomeDbContext database, TimeProvider timeProvider)
{
    public async Task<PagedResponse<CatalogItemSummary>> CatalogAsync(
        Guid userId,
        MediaKind? kind,
        int offset,
        int limit,
        CancellationToken cancellationToken)
    {
        ValidatePage(offset, limit);
        if (kind is not null and not MediaKind.Movie and not MediaKind.Series)
            throw new MetadataException(
                "invalid_catalog_kind",
                "Catalog kind must be movie or series.",
                StatusCodes.Status400BadRequest);

        var query = BaseItems(userId).Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series);
        if (kind is not null) query = query.Where(item => item.Kind == kind);
        var total = await query.CountAsync(cancellationToken);
        var items = await query.OrderBy(item => item.DetectedTitle).ThenBy(item => item.Id)
            .Skip(offset).Take(limit).ToListAsync(cancellationToken);
        return new PagedResponse<CatalogItemSummary>(
            items.Select(item => ToCatalog(item, userId)).ToList(), offset, limit, total);
    }

    public async Task<CatalogDetailPresentation> DetailAsync(
        Guid userId,
        Guid mediaId,
        CancellationToken cancellationToken)
    {
        var item = await BaseItems(userId)
            .SingleOrDefaultAsync(candidate => candidate.Id == mediaId
                && (candidate.Kind == MediaKind.Movie || candidate.Kind == MediaKind.Series), cancellationToken)
            ?? throw new MetadataException("media_not_found", "The movie or series was not found.", StatusCodes.Status404NotFound);
        var children = await BaseItems(userId).Where(candidate => candidate.ParentId == mediaId)
            .OrderBy(candidate => candidate.SeasonNumber).ThenBy(candidate => candidate.EpisodeNumber)
            .ThenBy(candidate => candidate.DetectedTitle).ThenBy(candidate => candidate.Id)
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

    public async Task<PagedResponse<CatalogItemSummary>> SearchAsync(Guid userId, string query, int offset, int limit, CancellationToken cancellationToken)
    {
        ValidatePage(offset, limit);
        var term = query.Trim();
        if (term.Length is < 1 or > 200)
            throw new MetadataException("invalid_search", "Search text must contain between 1 and 200 characters.", StatusCodes.Status400BadRequest);
        var normalized = term.ToLowerInvariant();
        var candidates = await BaseItems(userId)
            .Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series || item.Kind == MediaKind.Episode)
            .OrderBy(item => item.DetectedTitle).ThenBy(item => item.Id).Take(5000).ToListAsync(cancellationToken);
        var matches = candidates.Where(item => SearchText(item).Contains(normalized, StringComparison.OrdinalIgnoreCase)).ToList();
        return new PagedResponse<CatalogItemSummary>(matches.Skip(offset).Take(limit).Select(item => ToCatalog(item, userId)).ToList(), offset, limit, matches.Count);
    }

    public async Task<HomeResponse> HomeAsync(Guid userId, CancellationToken cancellationToken)
    {
        var items = await BaseItems(userId).Where(item => item.Availability == MediaAvailability.Available)
            .OrderBy(item => item.DetectedTitle).ToListAsync(cancellationToken);
        var topLevel = items.Where(item => item.Kind is MediaKind.Movie or MediaKind.Series).ToList();
        var playable = items.Where(item => item.Kind is MediaKind.Movie or MediaKind.Episode).ToList();
        var continueWatching = playable.Where(item => item.PlaybackProgress.Any(progress => progress.UserId == userId && !progress.IsCompleted && progress.PositionMilliseconds > 10_000))
            .OrderByDescending(item => item.PlaybackProgress.Single(progress => progress.UserId == userId).LastPlayedAt).Take(20).Select(item => ToCatalog(item, userId)).ToList();
        var recent = topLevel.OrderByDescending(item => item.CreatedAt).ThenBy(item => item.Id).Take(30).Select(item => ToCatalog(item, userId)).ToList();
        var favorites = topLevel.Where(item => item.Favorites.Any(value => value.UserId == userId)).OrderBy(item => EffectiveTitle(item)).Take(30).Select(item => ToCatalog(item, userId)).ToList();
        var now = timeProvider.GetUtcNow();
        var hour = new DateTimeOffset(now.Year, now.Month, now.Day, now.Hour, 0, 0, TimeSpan.Zero);
        var preferred = topLevel.Where(item => !item.PlaybackProgress.Any(progress => progress.UserId == userId && progress.IsCompleted)).ToList();
        if (preferred.Count == 0) preferred = topLevel;
        var recommendation = preferred.Count == 0 ? null : ToCatalog(preferred[StableIndex(userId, hour, preferred.Count)], userId);
        return new HomeResponse(
            recommendation,
            continueWatching,
            recent,
            favorites,
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
        .Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Credits)
        .Include(item => item.Parent)!.ThenInclude(parent => parent!.Metadata)
        .Include(item => item.Favorites.Where(value => value.UserId == userId))
        .Include(item => item.PlaybackProgress.Where(value => value.UserId == userId));

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
