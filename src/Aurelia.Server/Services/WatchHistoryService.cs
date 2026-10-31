using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// A profile's own viewing history and statistics. Days, weekdays and hours are counted in the
/// server's time zone, which is the household's, so an evening show is not filed under the night.
/// </summary>
public sealed class WatchHistoryService(AureliaDbContext database, TimeProvider clock)
{
    private DateTimeOffset Local(DateTimeOffset value) => TimeZoneInfo.ConvertTime(value, clock.LocalTimeZone);

    public async Task<WatchHistoryPage> GetHistoryAsync(
        Guid userId,
        int offset,
        int limit,
        CancellationToken cancellationToken)
    {
        offset = Math.Max(0, offset);
        limit = Math.Clamp(limit, 1, 100);

        var query = database.WatchEvents.AsNoTracking()
            .Where(e => e.UserId == userId)
            .OrderByDescending(e => e.Timestamp);

        var total = await query.CountAsync(cancellationToken);

        var events = await query
            .Skip(offset)
            .Take(limit)
            .Include(e => e.MediaItem)
                .ThenInclude(item => item.Metadata)
                    .ThenInclude(metadata => metadata!.Artwork)
            .Include(e => e.MediaItem)
                .ThenInclude(item => item.Parent)
                    .ThenInclude(parent => parent!.Metadata)
            .ToListAsync(cancellationToken);

        var items = events.Select(e =>
        {
            var item = e.MediaItem;
            var metadata = MetadataPresentation.ToSummary(item);
            string? eyebrow = null;
            if (item.Kind == MediaKind.Episode)
            {
                var parentTitle = item.Parent is not null ? MetadataPresentation.ToSummary(item.Parent).Title : null;
                eyebrow = parentTitle is not null
                    ? $"{parentTitle} · S{item.SeasonNumber}E{item.EpisodeNumber}"
                    : $"S{item.SeasonNumber}E{item.EpisodeNumber}";
            }
            else if (metadata.Year.HasValue)
            {
                eyebrow = metadata.Year.Value.ToString(CultureInfo.InvariantCulture);
            }

            return new WatchHistoryItem(
                e.Id,
                e.MediaItemId,
                metadata.Title,
                eyebrow,
                metadata.Year,
                item.Kind,
                metadata.Poster,
                e.Timestamp,
                e.PositionMilliseconds,
                e.DurationMilliseconds,
                e.SecondsWatched,
                e.IsCompleted);
        }).ToList();

        return new WatchHistoryPage(items, offset, limit, total);
    }

    public async Task DeleteHistoryItemAsync(
        Guid userId,
        Guid eventId,
        CancellationToken cancellationToken)
    {
        var item = await database.WatchEvents
            .SingleOrDefaultAsync(e => e.Id == eventId && e.UserId == userId, cancellationToken);
        if (item is not null)
        {
            database.WatchEvents.Remove(item);
            await database.SaveChangesAsync(cancellationToken);
        }
    }

    public async Task ClearHistoryAsync(
        Guid userId,
        CancellationToken cancellationToken)
    {
        // Clearing removes the profile's whole history, also for titles it cannot see right now.
        var items = await database.WatchEvents.IgnoreQueryFilters()
            .Where(e => e.UserId == userId)
            .ToListAsync(cancellationToken);
        if (items.Count > 0)
        {
            database.WatchEvents.RemoveRange(items);
            await database.SaveChangesAsync(cancellationToken);
        }
    }

    public async Task<UserStatistics> GetStatisticsAsync(
        Guid userId,
        CancellationToken cancellationToken)
    {
        var events = await database.WatchEvents.AsNoTracking()
            .Where(e => e.UserId == userId)
            .Include(e => e.MediaItem)
                .ThenInclude(item => item.Metadata)
            .Include(e => e.MediaItem)
                .ThenInclude(item => item.Parent)
                    .ThenInclude(parent => parent!.Metadata)
            .OrderBy(e => e.Timestamp)
            .ToListAsync(cancellationToken);

        if (events.Count == 0)
        {
            return new UserStatistics(
                0,
                0,
                0,
                Array.Empty<PeriodHours>(),
                Array.Empty<PeriodHours>(),
                Array.Empty<NamedCount>(),
                Array.Empty<NamedCount>(),
                0,
                0,
                "Monday",
                "Evening",
                0,
                Array.Empty<int>());
        }

        var totalSeconds = events.Sum(e => e.SecondsWatched);
        var totalHours = Hours(totalSeconds);

        var now = clock.GetUtcNow();
        var sevenDaysAgo = now.AddDays(-7);
        var thirtyDaysAgo = now.AddDays(-30);

        var past7Seconds = events.Where(e => e.Timestamp >= sevenDaysAgo).Sum(e => e.SecondsWatched);
        var past30Seconds = events.Where(e => e.Timestamp >= thirtyDaysAgo).Sum(e => e.SecondsWatched);

        var hoursPast7Days = Hours(past7Seconds);
        var hoursPast30Days = Hours(past30Seconds);

        var yearsAvailable = events
            .Select(e => Local(e.Timestamp).Year)
            .Distinct()
            .OrderByDescending(y => y)
            .ToList();

        // Group by week (ISO 8601 week: yyyy-'W'ww)
        var hoursByWeek = events
            .GroupBy(e =>
            {
                var dt = Local(e.Timestamp).DateTime;
                var week = ISOWeek.GetWeekOfYear(dt);
                var year = ISOWeek.GetYear(dt);
                return $"{year}-W{week:D2}";
            })
            .OrderBy(g => g.Key)
            .Select(g => new PeriodHours(g.Key, Hours(g.Sum(e => e.SecondsWatched))))
            .TakeLast(12)
            .ToList();

        // Group by month (yyyy-MM)
        var hoursByMonth = events
            .GroupBy(e => Local(e.Timestamp).ToString("yyyy-MM", CultureInfo.InvariantCulture))
            .OrderBy(g => g.Key)
            .Select(g => new PeriodHours(g.Key, Hours(g.Sum(e => e.SecondsWatched))))
            .TakeLast(12)
            .ToList();

        // Top genres
        var genreCounts = new Dictionary<string, (int Count, long Seconds)>(StringComparer.OrdinalIgnoreCase);
        foreach (var ev in events)
        {
            var summary = MetadataPresentation.ToSummary(ev.MediaItem);
            foreach (var genre in summary.Genres)
            {
                if (string.IsNullOrWhiteSpace(genre)) continue;
                if (!genreCounts.TryGetValue(genre, out var current)) current = (0, 0);
                genreCounts[genre] = (current.Count + 1, current.Seconds + ev.SecondsWatched);
            }
        }

        var topGenres = genreCounts
            .OrderByDescending(kv => kv.Value.Seconds)
            .Take(10)
            .Select(kv => new NamedCount(kv.Key, kv.Value.Count, Hours(kv.Value.Seconds)))
            .ToList();

        // Top titles
        var topTitles = events
            .GroupBy(e => DisplayTitle(e.MediaItem))
            .OrderByDescending(g => g.Sum(e => e.SecondsWatched))
            .Take(10)
            .Select(g => new NamedCount(g.Key, g.Count(), Hours(g.Sum(e => e.SecondsWatched))))
            .ToList();

        // Streaks
        var distinctDays = events
            .Select(e => Local(e.Timestamp).Date)
            .Distinct()
            .OrderBy(d => d)
            .ToList();

        var (currentStreak, longestStreak) = CalculateStreaks(distinctDays, Local(now).Date);

        // Busiest weekday
        var busiestWeekday = events
            .GroupBy(e => Local(e.Timestamp).DayOfWeek)
            .OrderByDescending(g => g.Sum(e => e.SecondsWatched))
            .Select(g => g.Key.ToString())
            .FirstOrDefault() ?? "Sunday";

        // Busiest time of day
        var busiestHour = events
            .GroupBy(e => Local(e.Timestamp).Hour)
            .OrderByDescending(g => g.Sum(e => e.SecondsWatched))
            .Select(g => g.Key)
            .FirstOrDefault();

        var busiestTimeOfDay = busiestHour switch
        {
            >= 6 and < 12 => "Morning (06:00–12:00)",
            >= 12 and < 18 => "Afternoon (12:00–18:00)",
            >= 18 and < 23 => "Evening (18:00–23:00)",
            _ => "Night (23:00–06:00)"
        };

        var completedCount = events.Count(e => e.IsCompleted);
        var completionRate = events.Count > 0
            ? Math.Round((double)completedCount / events.Count * 100.0, 1)
            : 0;

        return new UserStatistics(
            totalHours,
            hoursPast7Days,
            hoursPast30Days,
            hoursByWeek,
            hoursByMonth,
            topGenres,
            topTitles,
            currentStreak,
            longestStreak,
            busiestWeekday,
            busiestTimeOfDay,
            completionRate,
            yearsAvailable);
    }

    public async Task<YearInReview> GetYearInReviewAsync(
        Guid userId,
        int year,
        CancellationToken cancellationToken)
    {
        if (year is < 2000 or > 9998)
            throw new MetadataException("invalid_year", "Choose a year between 2000 and 9998.", StatusCodes.Status400BadRequest);
        var zone = clock.LocalTimeZone;
        var start = new DateTimeOffset(new DateTime(year, 1, 1), zone.GetUtcOffset(new DateTime(year, 1, 1)));
        var end = new DateTimeOffset(new DateTime(year + 1, 1, 1), zone.GetUtcOffset(new DateTime(year + 1, 1, 1)));

        var events = await database.WatchEvents.AsNoTracking()
            .Where(e => e.UserId == userId && e.Timestamp >= start && e.Timestamp < end)
            .Include(e => e.MediaItem)
                .ThenInclude(item => item.Metadata)
            .Include(e => e.MediaItem)
                .ThenInclude(item => item.Parent)
                    .ThenInclude(parent => parent!.Metadata)
            .ToListAsync(cancellationToken);

        if (events.Count == 0)
        {
            return new YearInReview(year, 0, 0, 0, 0, null, null, null, null);
        }

        var totalHours = Hours(events.Sum(e => e.SecondsWatched));
        var distinctTitles = events.Select(e => e.MediaItemId).Distinct().Count();
        var moviesWatched = events.Where(e => e.MediaItem.Kind == MediaKind.Movie).Select(e => e.MediaItemId).Distinct().Count();
        var episodesWatched = events.Where(e => e.MediaItem.Kind == MediaKind.Episode).Count();

        // Top genre
        var genreCounts = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        foreach (var ev in events)
        {
            var summary = MetadataPresentation.ToSummary(ev.MediaItem);
            foreach (var genre in summary.Genres)
            {
                if (string.IsNullOrWhiteSpace(genre)) continue;
                genreCounts[genre] = genreCounts.GetValueOrDefault(genre) + ev.SecondsWatched;
            }
        }
        var topGenre = genreCounts.OrderByDescending(kv => kv.Value).Select(kv => kv.Key).FirstOrDefault();

        // Top title
        var topTitle = events
            .GroupBy(e => DisplayTitle(e.MediaItem))
            .OrderByDescending(g => g.Sum(e => e.SecondsWatched))
            .Select(g => g.Key)
            .FirstOrDefault();

        // Busiest day
        var busiestDayGroup = events
            .GroupBy(e => Local(e.Timestamp).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture))
            .OrderByDescending(g => g.Sum(e => e.SecondsWatched))
            .FirstOrDefault();

        var busiestDay = busiestDayGroup?.Key;
        var busiestDayHours = busiestDayGroup is not null
            ? Hours(busiestDayGroup.Sum(e => e.SecondsWatched))
            : (double?)null;

        return new YearInReview(
            year,
            totalHours,
            distinctTitles,
            moviesWatched,
            episodesWatched,
            topGenre,
            topTitle,
            busiestDay,
            busiestDayHours);
    }

    /// <summary>Hours to the second, so clients can show exact minutes; tenths of an hour hid them.</summary>
    private static double Hours(long seconds) => Math.Round(seconds / 3600.0, 4);

    /// <summary>Episodes count for their series, so a binge shows up as the show, not one episode.</summary>
    private static string DisplayTitle(MediaItem item) =>
        MetadataPresentation.ToSummary(item.Kind == MediaKind.Episode && item.Parent is { } series ? series : item).Title;

    private static (int CurrentStreak, int LongestStreak) CalculateStreaks(List<DateTime> distinctDays, DateTime today)
    {
        if (distinctDays.Count == 0) return (0, 0);

        var longest = 0;
        var current = 0;
        var temp = 1;

        for (var i = 1; i < distinctDays.Count; i++)
        {
            if (distinctDays[i] == distinctDays[i - 1].AddDays(1))
            {
                temp++;
            }
            else
            {
                longest = Math.Max(longest, temp);
                temp = 1;
            }
        }
        longest = Math.Max(longest, temp);

        var lastDay = distinctDays[^1];
        if (lastDay == today || lastDay == today.AddDays(-1))
        {
            current = 1;
            for (var i = distinctDays.Count - 2; i >= 0; i--)
            {
                if (distinctDays[i] == distinctDays[i + 1].AddDays(-1))
                {
                    current++;
                }
                else
                {
                    break;
                }
            }
        }
        else
        {
            current = 0;
        }

        return (current, longest);
    }
}
