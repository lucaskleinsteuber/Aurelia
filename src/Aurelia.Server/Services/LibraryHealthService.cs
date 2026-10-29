using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class LibraryHealthService(AureliaDbContext database)
{
    public async Task<IReadOnlyList<DuplicateGroup>> GetDuplicatesAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken)
    {
        offset = Math.Max(0, offset);
        limit = Math.Clamp(limit, 1, 50);

        // Group by ProviderMediaId (non-empty TMDB IDs)
        var moviesAndEpisodes = await database.MediaItems.AsNoTracking()
            .Where(m => m.Kind == MediaKind.Movie || m.Kind == MediaKind.Episode)
            .Include(m => m.Metadata)
            .Include(m => m.LibraryRoot)
            .ToListAsync(cancellationToken);

        var groups = new List<DuplicateGroup>();

        // 1. Group by TMDB ID
        var tmdbGroups = moviesAndEpisodes
            .Where(m => !string.IsNullOrEmpty(m.Metadata?.ProviderMediaId))
            .GroupBy(m => $"{m.Metadata!.Provider}:{m.Metadata.ProviderMediaId}")
            .Where(g => g.Count() > 1);

        var seenMediaIds = new HashSet<Guid>();

        foreach (var group in tmdbGroups)
        {
            var first = group.First();
            var title = MetadataPresentation.ToSummary(first).Title;
            var year = MetadataPresentation.ToSummary(first).Year;
            var items = group.Select(ToDuplicateItem).ToList();
            foreach (var item in items) seenMediaIds.Add(item.MediaId);
            groups.Add(new DuplicateGroup(group.Key, title, year, items));
        }

        // 2. Group by normalized title and year (for items not already grouped)
        var titleGroups = moviesAndEpisodes
            .Where(m => !seenMediaIds.Contains(m.Id))
            .GroupBy(m => $"{NormalizeTitle(MetadataPresentation.ToSummary(m).Title)}:{MetadataPresentation.ToSummary(m).Year}:{m.Kind}")
            .Where(g => g.Count() > 1);

        foreach (var group in titleGroups)
        {
            var first = group.First();
            var title = MetadataPresentation.ToSummary(first).Title;
            var year = MetadataPresentation.ToSummary(first).Year;
            var items = group.Select(ToDuplicateItem).ToList();
            groups.Add(new DuplicateGroup($"title:{group.Key}", title, year, items));
        }

        return groups.Skip(offset).Take(limit).ToList();
    }

    public async Task<IReadOnlyList<OfflineTitleSummary>> GetOfflineAsync(
        int days,
        int offset,
        int limit,
        CancellationToken cancellationToken)
    {
        offset = Math.Max(0, offset);
        limit = Math.Clamp(limit, 1, 100);
        days = Math.Max(0, days);

        var cutoff = DateTimeOffset.UtcNow.AddDays(-days);

        var items = await database.MediaItems.AsNoTracking()
            .Where(m => m.Availability == MediaAvailability.Missing || m.Availability == MediaAvailability.Error || m.UpdatedAt <= cutoff)
            .Include(m => m.Metadata)
            .OrderBy(m => m.UpdatedAt)
            .Skip(offset)
            .Take(limit)
            .ToListAsync(cancellationToken);

        return items.Select(m =>
        {
            var summary = MetadataPresentation.ToSummary(m);
            var daysOffline = (int)Math.Max(0, (DateTimeOffset.UtcNow - m.UpdatedAt).TotalDays);
            var relPath = Path.GetFileName(m.SourcePath);
            return new OfflineTitleSummary(
                m.Id,
                summary.Title,
                summary.Year,
                m.Kind,
                relPath,
                m.UpdatedAt,
                daysOffline);
        }).ToList();
    }

    public async Task<IReadOnlyList<UnmatchedTitleSummary>> GetUnmatchedAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken)
    {
        offset = Math.Max(0, offset);
        limit = Math.Clamp(limit, 1, 100);

        var items = await database.MediaItems.AsNoTracking()
            .Where(m => m.Metadata == null
                || m.Metadata.ReviewState == MetadataReviewState.NeedsReview
                || (string.IsNullOrEmpty(m.Metadata.ProviderOverview) && string.IsNullOrEmpty(m.Metadata.ManualOverview)))
            .Include(m => m.Metadata)
            .OrderBy(m => m.DetectedTitle)
            .Skip(offset)
            .Take(limit)
            .ToListAsync(cancellationToken);

        return items.Select(m =>
        {
            string reason = m.Metadata switch
            {
                null => "No metadata found",
                { ReviewState: MetadataReviewState.NeedsReview } => "Pending review",
                _ => "Missing overview or artwork"
            };

            return new UnmatchedTitleSummary(
                m.Id,
                m.DetectedTitle,
                m.SourcePath,
                m.Kind,
                reason);
        }).ToList();
    }

    public async Task MergeAsync(
        Guid sourceId,
        Guid targetId,
        CancellationToken cancellationToken)
    {
        if (sourceId == targetId) return;

        var source = await database.MediaItems
            .Include(m => m.Favorites)
            .Include(m => m.PlaybackProgress)
            .Include(m => m.CollectionMemberships)
            .Include(m => m.ContinueWatchingStates)
            .SingleOrDefaultAsync(m => m.Id == sourceId, cancellationToken)
            ?? throw new MetadataException("source_not_found", "Source item not found.", StatusCodes.Status404NotFound);

        var target = await database.MediaItems
            .Include(m => m.Favorites)
            .Include(m => m.PlaybackProgress)
            .Include(m => m.CollectionMemberships)
            .SingleOrDefaultAsync(m => m.Id == targetId, cancellationToken)
            ?? throw new MetadataException("target_not_found", "Target item not found.", StatusCodes.Status404NotFound);

        // Move favorites
        foreach (var fav in source.Favorites)
        {
            if (!target.Favorites.Any(f => f.UserId == fav.UserId))
            {
                target.Favorites.Add(new UserFavorite
                {
                    UserId = fav.UserId,
                    MediaItemId = target.Id,
                    CreatedAt = fav.CreatedAt
                });
            }
        }

        // Move progress if target has none or source is further ahead
        foreach (var prog in source.PlaybackProgress)
        {
            var targetProg = target.PlaybackProgress.FirstOrDefault(p => p.UserId == prog.UserId);
            if (targetProg == null)
            {
                target.PlaybackProgress.Add(new PlaybackProgress
                {
                    Id = Guid.NewGuid(),
                    UserId = prog.UserId,
                    MediaItemId = target.Id,
                    MediaItem = target,
                    User = null!,
                    PositionMilliseconds = prog.PositionMilliseconds,
                    DurationMilliseconds = prog.DurationMilliseconds,
                    IsCompleted = prog.IsCompleted,
                    LastPlayedAt = prog.LastPlayedAt,
                    UpdatedAt = prog.UpdatedAt
                });
            }
            else if (!targetProg.IsCompleted && prog.IsCompleted)
            {
                targetProg.IsCompleted = true;
                targetProg.PositionMilliseconds = 0;
                targetProg.UpdatedAt = DateTimeOffset.UtcNow;
            }
        }

        // Reassign watch events
        var watchEvents = await database.WatchEvents
            .Where(e => e.MediaItemId == sourceId)
            .ToListAsync(cancellationToken);
        foreach (var ev in watchEvents)
        {
            ev.MediaItemId = targetId;
        }

        // Reassign collection memberships
        foreach (var member in source.CollectionMemberships)
        {
            if (!target.CollectionMemberships.Any(m => m.CollectionId == member.CollectionId))
            {
                target.CollectionMemberships.Add(new MediaCollectionMember
                {
                    CollectionId = member.CollectionId,
                    MediaItemId = target.Id,
                    SortOrder = member.SortOrder
                });
            }
        }

        // Remove source MediaItem (files on disk are NEVER touched)
        database.MediaItems.Remove(source);
        await database.SaveChangesAsync(cancellationToken);
    }

    public async Task SetPreferredVersionAsync(
        Guid preferredId,
        CancellationToken cancellationToken)
    {
        var item = await database.MediaItems
            .SingleOrDefaultAsync(m => m.Id == preferredId, cancellationToken)
            ?? throw new MetadataException("item_not_found", "Media item not found.", StatusCodes.Status404NotFound);

        // Preference can be signified by updating UpdatedAt timestamp so it ranks first in duplicate listings
        item.UpdatedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
    }

    public async Task RemoveEntryAsync(
        Guid mediaId,
        CancellationToken cancellationToken)
    {
        var item = await database.MediaItems
            .SingleOrDefaultAsync(m => m.Id == mediaId, cancellationToken)
            ?? throw new MetadataException("item_not_found", "Media item not found.", StatusCodes.Status404NotFound);

        // Delete from database only - NEVER delete media files from disk
        database.MediaItems.Remove(item);
        await database.SaveChangesAsync(cancellationToken);
    }

    private static DuplicateItemSummary ToDuplicateItem(MediaItem item)
    {
        var summary = MetadataPresentation.ToSummary(item);
        var relPath = Path.GetFileName(item.SourcePath);
        return new DuplicateItemSummary(
            item.Id,
            summary.Title,
            summary.Year,
            relPath,
            item.FileSize,
            null,
            null,
            null,
            null,
            item.CreatedAt);
    }

    private static string NormalizeTitle(string title)
    {
        return new string(title
            .ToLowerInvariant()
            .Where(char.IsLetterOrDigit)
            .ToArray());
    }
}
