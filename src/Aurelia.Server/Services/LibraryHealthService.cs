using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Library Health for administrators: duplicate files, titles whose file went missing, and titles
/// without usable metadata. Every action changes only the catalog, never a file on disk. A title
/// whose file still exists cannot be removed or merged away here, because the next scan would
/// import it again; that stays the explicit "Remove from Library" action.
/// </summary>
public sealed class LibraryHealthService(AureliaDbContext database, LibraryMutationService mutations, TimeProvider clock)
{
    public async Task<IReadOnlyList<DuplicateGroup>> GetDuplicatesAsync(int offset, int limit, CancellationToken cancellationToken)
    {
        offset = Math.Max(0, offset);
        limit = Math.Clamp(limit, 1, 50);

        // Movies match by provider identity (or, without one, by title and year); episodes only
        // when the same series has several files for the same season and episode.
        var movies = await database.MediaItems.AsNoTracking()
            .Where(item => item.Kind == MediaKind.Movie)
            .Include(item => item.Metadata)
            .ToListAsync(cancellationToken);
        var movieGroups = movies
            .GroupBy(item => item.Metadata is { ProviderMediaId: { Length: > 0 } providerId } metadata
                ? $"movie:{metadata.Provider}:{providerId}"
                : $"title:{NormalizeTitle(MetadataPresentation.ToSummary(item).Title)}:{MetadataPresentation.ToSummary(item).Year}")
            .Where(group => group.Count() > 1);

        var episodeKeys = await database.MediaItems.AsNoTracking()
            .Where(item => item.Kind == MediaKind.Episode && item.ParentId != null && item.SeasonNumber != null && item.EpisodeNumber != null)
            .GroupBy(item => new { item.ParentId, item.SeasonNumber, item.EpisodeNumber })
            .Where(group => group.Count() > 1)
            .Select(group => group.Key)
            .ToListAsync(cancellationToken);
        var parents = episodeKeys.Select(key => key.ParentId).Distinct().ToList();
        var episodes = episodeKeys.Count == 0 ? [] : await database.MediaItems.AsNoTracking()
            .Where(item => item.Kind == MediaKind.Episode && parents.Contains(item.ParentId))
            .Include(item => item.Metadata)
            .Include(item => item.Parent).ThenInclude(parent => parent!.Metadata)
            .ToListAsync(cancellationToken);
        var episodeGroups = episodes
            .GroupBy(item => $"episode:{item.ParentId}:{item.SeasonNumber}:{item.EpisodeNumber}")
            .Where(group => group.Count() > 1);

        return movieGroups.Concat(episodeGroups)
            .Select(group => ToGroup(group.Key, group.OrderBy(item => item.CreatedAt).ThenBy(item => item.Id).ToList()))
            .OrderBy(group => group.Title, StringComparer.OrdinalIgnoreCase).ThenBy(group => group.Key, StringComparer.Ordinal)
            .Skip(offset).Take(limit)
            .ToList();
    }

    /// <summary>Titles whose file has been missing for at least the given number of days.</summary>
    public async Task<IReadOnlyList<OfflineTitleSummary>> GetOfflineAsync(int days, int offset, int limit, CancellationToken cancellationToken)
    {
        offset = Math.Max(0, offset);
        limit = Math.Clamp(limit, 1, 100);
        var now = clock.GetUtcNow();
        var cutoff = now.AddDays(-Math.Max(0, days));

        var items = await database.MediaItems.AsNoTracking()
            .Where(item => item.Kind != MediaKind.Series && item.Availability != MediaAvailability.Available)
            .Select(item => new
            {
                Item = item,
                LibraryName = item.LibraryRoot.Name,
                // The last scan that still saw the file; without one, when the entry last changed.
                LastSeen = database.LibraryScans.Where(scan => scan.Id == item.LastSeenScanId)
                    .Select(scan => scan.StartedAt).FirstOrDefault() ?? item.UpdatedAt,
            })
            .ToListAsync(cancellationToken);

        return items.Where(value => value.LastSeen <= cutoff)
            .OrderBy(value => value.LastSeen).ThenBy(value => value.Item.Id)
            .Skip(offset).Take(limit)
            .Select(value =>
            {
                var summary = MetadataPresentation.ToSummary(value.Item);
                return new OfflineTitleSummary(value.Item.Id, summary.Title, value.Item.Kind, summary.Year, value.LibraryName,
                    Path.GetFileName(value.Item.SourcePath), value.LastSeen, (int)Math.Max(0, (now - value.LastSeen).TotalDays));
            })
            .ToList();
    }

    public async Task<IReadOnlyList<UnmatchedTitleSummary>> GetUnmatchedAsync(int offset, int limit, CancellationToken cancellationToken)
    {
        offset = Math.Max(0, offset);
        limit = Math.Clamp(limit, 1, 100);

        // Episodes take their details from the series, so only movies and series need a match.
        var items = await database.MediaItems.AsNoTracking()
            .Where(item => (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series)
                && (item.Metadata == null
                    || item.Metadata.ReviewState == MetadataReviewState.NeedsReview
                    || (string.IsNullOrEmpty(item.Metadata.ProviderOverview) && string.IsNullOrEmpty(item.Metadata.ManualOverview))))
            .Include(item => item.Metadata)
            .OrderBy(item => item.DetectedTitle).ThenBy(item => item.Id)
            .Skip(offset)
            .Take(limit)
            .ToListAsync(cancellationToken);

        return items.Select(item => new UnmatchedTitleSummary(
            item.Id,
            MetadataPresentation.ToSummary(item).Title,
            item.Kind,
            item.Year,
            Path.GetFileName(item.SourcePath),
            item.Metadata switch
            {
                null => "No metadata found",
                { ReviewState: MetadataReviewState.NeedsReview } => "Match needs review",
                _ => "No overview",
            })).ToList();
    }

    /// <summary>
    /// Moves every profile's favorites, progress, history and collection membership from a copy
    /// whose file is missing to another copy of the same movie or episode, then removes the missing
    /// entry the same way "Remove from Library" does.
    /// </summary>
    public async Task MergeAsync(Guid userId, Guid sourceId, Guid targetId, CancellationToken cancellationToken)
    {
        if (sourceId == targetId)
            throw new MetadataException("invalid_merge", "Choose two different copies.", StatusCodes.Status400BadRequest);

        var source = await database.MediaItems
            .Include(item => item.CollectionMemberships)
            .SingleOrDefaultAsync(item => item.Id == sourceId, cancellationToken)
            ?? throw new MetadataException("source_not_found", "The copy to merge was not found.", StatusCodes.Status404NotFound);
        var target = await database.MediaItems
            .Include(item => item.CollectionMemberships)
            .SingleOrDefaultAsync(item => item.Id == targetId, cancellationToken)
            ?? throw new MetadataException("target_not_found", "The copy to keep was not found.", StatusCodes.Status404NotFound);
        // Favorites, progress and history belong to profiles. The request's own profile filter
        // would show only the administrator's, and the others would be deleted with the copy.
        var sourceFavorites = await database.UserFavorites.IgnoreQueryFilters()
            .Where(favorite => favorite.MediaItemId == sourceId).ToListAsync(cancellationToken);
        var targetFavorites = await database.UserFavorites.IgnoreQueryFilters()
            .Where(favorite => favorite.MediaItemId == targetId).ToListAsync(cancellationToken);
        var sourceProgress = await database.PlaybackProgress.IgnoreQueryFilters()
            .Where(progress => progress.MediaItemId == sourceId).ToListAsync(cancellationToken);
        var targetProgress = await database.PlaybackProgress.IgnoreQueryFilters()
            .Where(progress => progress.MediaItemId == targetId).ToListAsync(cancellationToken);

        if (source.Kind != target.Kind || source.Kind is not (MediaKind.Movie or MediaKind.Episode))
            throw new MetadataException("invalid_merge", "Only two copies of the same movie or episode can be merged.", StatusCodes.Status400BadRequest);
        if (source.Availability == MediaAvailability.Available)
            throw new MetadataException("source_available",
                "This copy's file still exists, so the next scan would add it again. Only a missing copy can be merged into another one.",
                StatusCodes.Status409Conflict);

        var now = clock.GetUtcNow();
        foreach (var favorite in sourceFavorites.Where(favorite => targetFavorites.All(existing => existing.UserId != favorite.UserId)))
            database.UserFavorites.Add(new UserFavorite { Id = Guid.NewGuid(), UserId = favorite.UserId, MediaItemId = target.Id, CreatedAt = favorite.CreatedAt });

        foreach (var progress in sourceProgress)
        {
            var existing = targetProgress.FirstOrDefault(value => value.UserId == progress.UserId);
            if (existing is null)
            {
                database.PlaybackProgress.Add(new PlaybackProgress
                {
                    Id = Guid.NewGuid(),
                    UserId = progress.UserId,
                    User = null!,
                    MediaItemId = target.Id,
                    MediaItem = target,
                    PositionMilliseconds = progress.PositionMilliseconds,
                    DurationMilliseconds = progress.DurationMilliseconds,
                    IsCompleted = progress.IsCompleted,
                    LastPlayedAt = progress.LastPlayedAt,
                    UpdatedAt = now,
                    Revision = 1,
                });
            }
            else if (progress.IsCompleted && !existing.IsCompleted)
            {
                existing.IsCompleted = true;
                existing.PositionMilliseconds = 0;
                existing.UpdatedAt = now;
                existing.Revision = checked(existing.Revision + 1);
            }
        }

        foreach (var member in source.CollectionMemberships.Where(member => target.CollectionMemberships.All(existing => existing.CollectionId != member.CollectionId)))
            database.MediaCollectionMembers.Add(new MediaCollectionMember { CollectionId = member.CollectionId, MediaItemId = target.Id, SortOrder = member.SortOrder });

        await database.WatchEvents.IgnoreQueryFilters().Where(watch => watch.MediaItemId == sourceId)
            .ExecuteUpdateAsync(update => update.SetProperty(watch => watch.MediaItemId, targetId), cancellationToken);
        await database.SaveChangesAsync(cancellationToken);
        await mutations.RemoveAsync(userId, sourceId, cancellationToken);
    }

    /// <summary>Removes a title whose file is missing; a title with its file present needs "Remove from Library".</summary>
    public async Task RemoveEntryAsync(Guid userId, Guid mediaId, CancellationToken cancellationToken)
    {
        var availability = await database.MediaItems.Where(item => item.Id == mediaId)
            .Select(item => (MediaAvailability?)item.Availability).SingleOrDefaultAsync(cancellationToken)
            ?? throw new MetadataException("item_not_found", "The title was not found.", StatusCodes.Status404NotFound);
        if (availability == MediaAvailability.Available)
            throw new MetadataException("source_available",
                "This title's file is available. Use Remove from Library on the title to remove it and keep it out of future scans.",
                StatusCodes.Status409Conflict);
        await mutations.RemoveAsync(userId, mediaId, cancellationToken);
    }

    private static DuplicateGroup ToGroup(string key, List<MediaItem> items)
    {
        var first = items[0];
        var summary = MetadataPresentation.ToSummary(first);
        var title = first.Kind == MediaKind.Episode && first.Parent is { } parent
            ? $"{MetadataPresentation.ToSummary(parent).Title} · S{first.SeasonNumber}E{first.EpisodeNumber}"
            : summary.Title;
        return new DuplicateGroup(key, title, first.Kind, summary.Year, items.Select(item => new DuplicateItemSummary(
            item.Id,
            MetadataPresentation.ToSummary(item).Title,
            item.Kind,
            item.Year,
            Path.GetFileName(item.SourcePath),
            item.FileSize,
            item.Availability)).ToList());
    }

    private static string NormalizeTitle(string title) =>
        new(title.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
}
