using System.Collections.Concurrent;
using System.Linq.Expressions;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class SmartListEvaluator
{
    private static readonly ConcurrentDictionary<string, (DateTimeOffset CachedAt, List<Guid> ItemIds)> Cache = new();
    private static readonly TimeSpan CacheDuration = TimeSpan.FromSeconds(60);
    private const int MaximumCachedLists = 512;
    private static readonly JsonSerializerOptions CanonicalJson = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public static void InvalidateCache() => Cache.Clear();

    /// <summary>
    /// Reads a smart list's rules as the apps send them. Earlier apps named fields differently
    /// ("watched" or "watchState", "search", "match" or "matchAny", plural kinds such as
    /// "movies"); every spelling is understood, so lists they saved choose titles as intended.
    /// Returns null when the text is not a JSON object.
    /// </summary>
    public static SmartCollectionRules? Parse(string? json)
    {
        if (string.IsNullOrWhiteSpace(json) || json.Length > 16_384) return null;
        JsonDocument document;
        try { document = JsonDocument.Parse(json); }
        catch (JsonException) { return null; }
        using (document)
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object) return null;
            var fields = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in document.RootElement.EnumerateObject())
                if (property.Value.ValueKind != JsonValueKind.Null) fields[property.Name] = property.Value.Clone();

            string? Text(params string[] names) => names.Select(name => fields.TryGetValue(name, out var value)
                && value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() : null).FirstOrDefault(value => !string.IsNullOrEmpty(value));
            double? Number(string name) => fields.TryGetValue(name, out var value) && value.ValueKind == JsonValueKind.Number
                && value.TryGetDouble(out var number) && double.IsFinite(number) ? number : null;
            int? Whole(string name, int minimum, int maximum) => Number(name) is { } number
                && number >= minimum && number <= maximum ? (int)number : null;
            bool Flag(string name) => fields.TryGetValue(name, out var value) && value.ValueKind == JsonValueKind.True;

            var kind = Text("kind")?.ToLowerInvariant() switch
            {
                "movie" or "movies" => "movie",
                "series" or "show" or "shows" or "tv" => "series",
                "episode" or "episodes" => "episode",
                _ => null,
            };
            var watched = Text("watchedState", "watchState", "watched")?.ToLowerInvariant().Replace("_", "", StringComparison.Ordinal)
                .Replace(" ", "", StringComparison.Ordinal) switch
            {
                "unwatched" or "unplayed" => "unwatched",
                "inprogress" => "inProgress",
                "watched" or "completed" => "watched",
                _ => null,
            };
            var combination = Flag("matchAny") || Text("combination", "match")?.ToLowerInvariant() is "or" or "any" ? "or" : "and";
            var genres = fields.TryGetValue("genres", out var list) && list.ValueKind == JsonValueKind.Array
                ? list.EnumerateArray().Where(value => value.ValueKind == JsonValueKind.String)
                    .Select(value => value.GetString()!.Trim()).Where(value => value.Length is > 0 and <= 64)
                    .Distinct(StringComparer.OrdinalIgnoreCase).Take(20).ToList()
                : [];
            var search = Text("textContains", "search");
            return new SmartCollectionRules(
                Kind: kind,
                Genres: genres.Count > 0 ? genres : null,
                YearMin: Whole("yearMin", 1800, 3000),
                YearMax: Whole("yearMax", 1800, 3000),
                Decade: Whole("decade", 1800, 3000),
                RatingMin: Number("ratingMin") is >= 0 and <= 10 ? Number("ratingMin") : null,
                RatingMax: Number("ratingMax") is >= 0 and <= 10 ? Number("ratingMax") : null,
                WatchedState: watched,
                AddedWithinDays: Whole("addedWithinDays", 1, 36_500),
                FavoritesOnly: Flag("favoritesOnly") ? true : null,
                WatchlistOnly: Flag("watchlistOnly") ? true : null,
                TextContains: search is null ? null : search.Length > 200 ? search[..200] : search,
                Combination: combination);
        }
    }

    /// <summary>The one spelling the server stores and the apps read back.</summary>
    public static string Canonical(SmartCollectionRules rules) => JsonSerializer.Serialize(rules, CanonicalJson);

    /// <summary>Makes a user's text match literally: % and _ are not wildcards.</summary>
    private static string Literal(string text) =>
        text.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("%", "\\%", StringComparison.Ordinal).Replace("_", "\\_", StringComparison.Ordinal);

    public static async Task<(IReadOnlyList<MediaItem> Items, int TotalCount)> EvaluateAsync(
        AureliaDbContext database,
        Guid userId,
        SmartCollectionRules rules,
        int offset,
        int limit,
        CancellationToken cancellationToken,
        IReadOnlyCollection<Guid>? watchlist = null)
    {
        var cacheKey = $"{userId}:{JsonSerializer.Serialize(rules)}";
        List<Guid> matchedIds;

        // A watchlist changes with every tap, so those lists are always chosen afresh.
        if (rules.WatchlistOnly != true && Cache.TryGetValue(cacheKey, out var entry) && (DateTimeOffset.UtcNow - entry.CachedAt) < CacheDuration)
        {
            matchedIds = entry.ItemIds;
        }
        else
        {
            matchedIds = await QueryMatchedIdsAsync(database, userId, rules, watchlist, cancellationToken);
            if (rules.WatchlistOnly != true) Remember(cacheKey, matchedIds);
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
            // One query would repeat a title's whole description, full cast included, for each of its pictures.
            .AsSplitQuery()
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

        var matchedIds = await QueryMatchedIdsAsync(database, userId, rules, null, cancellationToken);
        Remember(cacheKey, matchedIds);
        return matchedIds.Count;
    }

    // Lists are few, but every distinct rule set leaves an entry; old ones must not pile up.
    private static void Remember(string key, List<Guid> ids)
    {
        if (Cache.Count >= MaximumCachedLists) Cache.Clear();
        Cache[key] = (DateTimeOffset.UtcNow, ids);
    }

    private static async Task<List<Guid>> QueryMatchedIdsAsync(
        AureliaDbContext database,
        Guid userId,
        SmartCollectionRules rules,
        IReadOnlyCollection<Guid>? watchlist,
        CancellationToken cancellationToken)
    {
        var query = database.MediaItems.AsNoTracking()
            .Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series || item.Kind == MediaKind.Episode);
        var any = string.Equals(rules.Combination, "or", StringComparison.OrdinalIgnoreCase);
        var conditions = new List<Expression<Func<MediaItem, bool>>>();

        if (!string.IsNullOrWhiteSpace(rules.Kind) && Enum.TryParse<MediaKind>(rules.Kind, true, out var kind))
            conditions.Add(item => item.Kind == kind);

        var minYear = rules.YearMin;
        var maxYear = rules.YearMax;
        if (rules.Decade.HasValue)
        {
            minYear = rules.Decade.Value;
            maxYear = rules.Decade.Value + 9;
        }
        if (minYear.HasValue)
        {
            var year = minYear.Value;
            conditions.Add(item => (item.Metadata != null && item.Metadata.ManualFieldsJson.Contains("\"releaseYear\"")
                ? item.Metadata.ManualReleaseYear : item.Year) >= year);
        }
        if (maxYear.HasValue)
        {
            var year = maxYear.Value;
            conditions.Add(item => (item.Metadata != null && item.Metadata.ManualFieldsJson.Contains("\"releaseYear\"")
                ? item.Metadata.ManualReleaseYear : item.Year) <= year);
        }

        if (rules.RatingMin.HasValue)
        {
            var rating = rules.RatingMin.Value;
            conditions.Add(item => item.Metadata != null && (
                (item.Metadata.ManualFieldsJson.Contains("\"rating\"") ? item.Metadata.ManualRating : item.Metadata.ProviderRating ?? item.Metadata.ManualRating) >= rating));
        }
        if (rules.RatingMax.HasValue)
        {
            var rating = rules.RatingMax.Value;
            conditions.Add(item => item.Metadata != null && (
                (item.Metadata.ManualFieldsJson.Contains("\"rating\"") ? item.Metadata.ManualRating : item.Metadata.ProviderRating ?? item.Metadata.ManualRating) <= rating));
        }

        if (rules.AddedWithinDays is > 0 and <= 36_500)
        {
            var cutoff = DateTimeOffset.UtcNow.AddDays(-rules.AddedWithinDays.Value);
            conditions.Add(item => item.CreatedAt >= cutoff);
        }

        if (rules.FavoritesOnly == true)
            conditions.Add(item => item.Favorites.Any(f => f.UserId == userId));

        if (rules.WatchlistOnly == true)
        {
            var ids = watchlist?.ToList() ?? [];
            conditions.Add(item => ids.Contains(item.Id));
        }

        switch (rules.WatchedState?.ToLowerInvariant())
        {
            case "unplayed" or "unwatched":
                conditions.Add(item => !item.PlaybackProgress.Any(p => p.UserId == userId && (p.IsCompleted || p.PositionMilliseconds > 0)));
                break;
            case "in_progress" or "inprogress":
                conditions.Add(item => item.PlaybackProgress.Any(p => p.UserId == userId && p.PositionMilliseconds > 0 && !p.IsCompleted));
                break;
            case "completed" or "watched":
                conditions.Add(item => item.PlaybackProgress.Any(p => p.UserId == userId && p.IsCompleted));
                break;
        }

        if (!string.IsNullOrWhiteSpace(rules.TextContains))
        {
            var term = $"%{Literal(rules.TextContains.Trim())}%";
            conditions.Add(item =>
                EF.Functions.Like(item.DetectedTitle, term, "\\")
                || (item.OverrideTitle != null && EF.Functions.Like(item.OverrideTitle, term, "\\"))
                || (item.Metadata != null && (
                    (item.Metadata.ProviderTitle != null && EF.Functions.Like(item.Metadata.ProviderTitle, term, "\\"))
                    || (item.Metadata.ManualTitle != null && EF.Functions.Like(item.Metadata.ManualTitle, term, "\\"))
                    || (item.Metadata.ProviderOverview != null && EF.Functions.Like(item.Metadata.ProviderOverview, term, "\\"))
                    || (item.Metadata.ManualOverview != null && EF.Functions.Like(item.Metadata.ManualOverview, term, "\\")))));
        }

        // Each genre is its own rule: with "or" one of them is enough, with "and" all must match.
        foreach (var genre in (rules.Genres ?? []).Where(g => !string.IsNullOrWhiteSpace(g)))
        {
            var pattern = $"%\"{Literal(genre.Trim())}\"%";
            conditions.Add(item => item.Metadata != null && (
                (item.Metadata.ManualGenresJson != null && EF.Functions.Like(item.Metadata.ManualGenresJson, pattern, "\\"))
                || (item.Metadata.ManualGenresJson == null && EF.Functions.Like(item.Metadata.ProviderGenresJson, pattern, "\\"))));
        }

        // "Match any rule" as both apps offer it: a title qualifies by one of the rules.
        if (any && conditions.Count > 0)
            query = query.Where(conditions.Aggregate(Either));
        else
            foreach (var condition in conditions) query = query.Where(condition);
        return await query
            .OrderBy(item => item.DetectedTitle)
            .ThenBy(item => item.Id)
            .Select(item => item.Id)
            .Take(1000)
            .ToListAsync(cancellationToken);
    }

    private static Expression<Func<MediaItem, bool>> Either(Expression<Func<MediaItem, bool>> left, Expression<Func<MediaItem, bool>> right)
    {
        var item = left.Parameters[0];
        var body = new ParameterSwap(right.Parameters[0], item).Visit(right.Body);
        return Expression.Lambda<Func<MediaItem, bool>>(Expression.OrElse(left.Body, body), item);
    }

    private sealed class ParameterSwap(ParameterExpression from, ParameterExpression to) : ExpressionVisitor
    {
        protected override Expression VisitParameter(ParameterExpression node) => node == from ? to : base.VisitParameter(node);
    }
}
