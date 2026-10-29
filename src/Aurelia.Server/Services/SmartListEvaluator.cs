using System.Collections.Concurrent;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class SmartListEvaluator
{
    private static readonly ConcurrentDictionary<string, (DateTimeOffset CachedAt, List<Guid> ItemIds)> Cache = new();
    private static readonly TimeSpan CacheDuration = TimeSpan.FromSeconds(60);

    public static void InvalidateCache() => Cache.Clear();

    public static async Task<(IReadOnlyList<MediaItem> Items, int TotalCount)> EvaluateAsync(
        AureliaDbContext database,
        Guid userId,
        SmartCollectionRules rules,
        int offset,
        int limit,
        CancellationToken cancellationToken)
    {
        var cacheKey = $"{userId}:{JsonSerializer.Serialize(rules)}";
        List<Guid> matchedIds;

        if (Cache.TryGetValue(cacheKey, out var entry) && (DateTimeOffset.UtcNow - entry.CachedAt) < CacheDuration)
        {
            matchedIds = entry.ItemIds;
        }
        else
        {
            matchedIds = await QueryMatchedIdsAsync(database, userId, rules, cancellationToken);
            Cache[cacheKey] = (DateTimeOffset.UtcNow, matchedIds);
        }

        var total = matchedIds.Count;
        var pagedIds = matchedIds.Skip(offset).Take(limit).ToList();

        if (pagedIds.Count == 0)
        {
            return (Array.Empty<MediaItem>(), total);
        }

        var items = await database.MediaItems.AsNoTracking()
            .Where(item => pagedIds.Contains(item.Id))
            .Include(item => item.Metadata)
                .ThenInclude(metadata => metadata!.Artwork)
            .Include(item => item.Favorites)
            .Include(item => item.PlaybackProgress)
            .Include(item => item.Parent)
                .ThenInclude(parent => parent!.Metadata)
            .ToListAsync(cancellationToken);

        // Preserve order of pagedIds
        var itemMap = items.ToDictionary(item => item.Id);
        var ordered = pagedIds.Where(id => itemMap.ContainsKey(id)).Select(id => itemMap[id]).ToList();

        return (ordered, total);
    }

    public static async Task<int> CountAsync(
        AureliaDbContext database,
        Guid userId,
        SmartCollectionRules rules,
        CancellationToken cancellationToken)
    {
        var cacheKey = $"{userId}:{JsonSerializer.Serialize(rules)}";
        if (Cache.TryGetValue(cacheKey, out var entry) && (DateTimeOffset.UtcNow - entry.CachedAt) < CacheDuration)
        {
            return entry.ItemIds.Count;
        }

        var matchedIds = await QueryMatchedIdsAsync(database, userId, rules, cancellationToken);
        Cache[cacheKey] = (DateTimeOffset.UtcNow, matchedIds);
        return matchedIds.Count;
    }

    private static async Task<List<Guid>> QueryMatchedIdsAsync(
        AureliaDbContext database,
        Guid userId,
        SmartCollectionRules rules,
        CancellationToken cancellationToken)
    {
        var query = database.MediaItems.AsNoTracking()
            .Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series || item.Kind == MediaKind.Episode);

        // Apply Kind
        if (!string.IsNullOrWhiteSpace(rules.Kind) && Enum.TryParse<MediaKind>(rules.Kind, true, out var kind))
        {
            query = query.Where(item => item.Kind == kind);
        }

        // Apply Year limits / Decade
        var minYear = rules.YearMin;
        var maxYear = rules.YearMax;
        if (rules.Decade.HasValue)
        {
            minYear = rules.Decade.Value;
            maxYear = rules.Decade.Value + 9;
        }

        if (minYear.HasValue)
        {
            query = query.Where(item => (item.Metadata != null && item.Metadata.ManualFieldsJson.Contains("\"releaseYear\"")
                ? item.Metadata.ManualReleaseYear : item.Year) >= minYear.Value);
        }
        if (maxYear.HasValue)
        {
            query = query.Where(item => (item.Metadata != null && item.Metadata.ManualFieldsJson.Contains("\"releaseYear\"")
                ? item.Metadata.ManualReleaseYear : item.Year) <= maxYear.Value);
        }

        // Apply Rating limits
        if (rules.RatingMin.HasValue)
        {
            query = query.Where(item => item.Metadata != null && (
                (item.Metadata.ManualFieldsJson.Contains("\"rating\"") ? item.Metadata.ManualRating : item.Metadata.ProviderRating ?? item.Metadata.ManualRating) >= rules.RatingMin.Value));
        }
        if (rules.RatingMax.HasValue)
        {
            query = query.Where(item => item.Metadata != null && (
                (item.Metadata.ManualFieldsJson.Contains("\"rating\"") ? item.Metadata.ManualRating : item.Metadata.ProviderRating ?? item.Metadata.ManualRating) <= rules.RatingMax.Value));
        }

        // Apply AddedWithinDays
        if (rules.AddedWithinDays.HasValue && rules.AddedWithinDays.Value > 0)
        {
            var cutoff = DateTimeOffset.UtcNow.AddDays(-rules.AddedWithinDays.Value);
            query = query.Where(item => item.CreatedAt >= cutoff);
        }

        // Apply FavoritesOnly
        if (rules.FavoritesOnly == true)
        {
            query = query.Where(item => item.Favorites.Any(f => f.UserId == userId));
        }

        // Apply WatchedState
        if (!string.IsNullOrWhiteSpace(rules.WatchedState))
        {
            var state = rules.WatchedState.ToLowerInvariant();
            if (state is "unplayed" or "unwatched")
            {
                query = query.Where(item => !item.PlaybackProgress.Any(p => p.UserId == userId && (p.IsCompleted || p.PositionMilliseconds > 0)));
            }
            else if (state is "in_progress" or "inprogress")
            {
                query = query.Where(item => item.PlaybackProgress.Any(p => p.UserId == userId && p.PositionMilliseconds > 0 && !p.IsCompleted));
            }
            else if (state is "completed" or "watched")
            {
                query = query.Where(item => item.PlaybackProgress.Any(p => p.UserId == userId && p.IsCompleted));
            }
        }

        // Apply TextContains
        if (!string.IsNullOrWhiteSpace(rules.TextContains))
        {
            var term = $"%{rules.TextContains.Trim()}%";
            query = query.Where(item =>
                EF.Functions.Like(item.DetectedTitle, term, "\\")
                || (item.OverrideTitle != null && EF.Functions.Like(item.OverrideTitle, term, "\\"))
                || (item.Metadata != null && (
                    (item.Metadata.ProviderTitle != null && EF.Functions.Like(item.Metadata.ProviderTitle, term, "\\"))
                    || (item.Metadata.ManualTitle != null && EF.Functions.Like(item.Metadata.ManualTitle, term, "\\"))
                    || (item.Metadata.ProviderOverview != null && EF.Functions.Like(item.Metadata.ProviderOverview, term, "\\"))
                    || (item.Metadata.ManualOverview != null && EF.Functions.Like(item.Metadata.ManualOverview, term, "\\")))));
        }

        // Apply Genres
        if (rules.Genres is { Count: > 0 })
        {
            var genrePatterns = rules.Genres
                .Where(g => !string.IsNullOrWhiteSpace(g))
                .Select(g => $"%\"{g.Trim()}\"%")
                .ToList();

            if (genrePatterns.Count > 0)
            {
                var isOr = string.Equals(rules.Combination, "or", StringComparison.OrdinalIgnoreCase);
                if (isOr)
                {
                    // Any genre matches
                    query = query.Where(item => item.Metadata != null && genrePatterns.Any(pattern =>
                        (item.Metadata.ManualGenresJson != null && EF.Functions.Like(item.Metadata.ManualGenresJson, pattern, "\\"))
                        || (item.Metadata.ManualGenresJson == null && EF.Functions.Like(item.Metadata.ProviderGenresJson, pattern, "\\"))));
                }
                else
                {
                    // All genres match
                    foreach (var pattern in genrePatterns)
                    {
                        query = query.Where(item => item.Metadata != null && (
                            (item.Metadata.ManualGenresJson != null && EF.Functions.Like(item.Metadata.ManualGenresJson, pattern, "\\"))
                            || (item.Metadata.ManualGenresJson == null && EF.Functions.Like(item.Metadata.ProviderGenresJson, pattern, "\\"))));
                    }
                }
            }
        }

        return await query
            .OrderBy(item => item.DetectedTitle)
            .ThenBy(item => item.Id)
            .Select(item => item.Id)
            .Take(1000)
            .ToListAsync(cancellationToken);
    }
}
