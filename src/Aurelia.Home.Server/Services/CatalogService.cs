using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Home.Server.Services;

public sealed class CatalogService(AureliaHomeDbContext database)
{
    public async Task<PagedResponse<MovieSummary>> ListMoviesAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken)
    {
        ValidatePage(offset, limit);
        var query = database.MediaItems.AsNoTracking().Where(item => item.Kind == MediaKind.Movie);
        var total = await query.CountAsync(cancellationToken);
        var items = await query
            .OrderBy(item => item.OverrideTitle ?? item.DetectedTitle)
            .ThenBy(item => item.Id)
            .Skip(offset)
            .Take(limit)
            .Select(item => new MovieSummary(
                item.Id,
                item.OverrideTitle ?? item.DetectedTitle,
                item.Year,
                item.Availability))
            .ToListAsync(cancellationToken);
        return new PagedResponse<MovieSummary>(items, offset, limit, total);
    }

    public async Task<MovieDetail> GetMovieAsync(Guid id, CancellationToken cancellationToken)
    {
        var movie = await database.MediaItems
            .AsNoTracking()
            .SingleOrDefaultAsync(item => item.Id == id && item.Kind == MediaKind.Movie, cancellationToken)
            ?? throw NotFound("movie_not_found", "The movie was not found.");
        var supplementItems = await database.MediaItems
            .AsNoTracking()
            .Where(item => item.ParentId == id
                && (item.Kind == MediaKind.Extra || item.Kind == MediaKind.Trailer))
            .OrderBy(item => item.Kind)
            .ThenBy(item => item.OverrideTitle ?? item.DetectedTitle)
            .ToListAsync(cancellationToken);
        return new MovieDetail(
            movie.Id,
            movie.OverrideTitle ?? movie.DetectedTitle,
            movie.Year,
            movie.Availability,
            supplementItems.Select(ToSupplement).ToList());
    }

    public async Task<PagedResponse<SeriesSummary>> ListSeriesAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken)
    {
        ValidatePage(offset, limit);
        var query = database.MediaItems.AsNoTracking().Where(item => item.Kind == MediaKind.Series);
        var total = await query.CountAsync(cancellationToken);
        var series = await query
            .OrderBy(item => item.OverrideTitle ?? item.DetectedTitle)
            .ThenBy(item => item.Id)
            .Skip(offset)
            .Take(limit)
            .ToListAsync(cancellationToken);
        var ids = series.Select(item => item.Id).ToList();
        var episodes = await database.MediaItems
            .AsNoTracking()
            .Where(item => item.ParentId.HasValue
                && ids.Contains(item.ParentId.Value)
                && item.Kind == MediaKind.Episode)
            .Select(item => new { item.ParentId, item.SeasonNumber })
            .ToListAsync(cancellationToken);
        var items = series.Select(item =>
        {
            var children = episodes.Where(episode => episode.ParentId == item.Id).ToList();
            return new SeriesSummary(
                item.Id,
                item.OverrideTitle ?? item.DetectedTitle,
                item.Availability,
                children.Where(episode => episode.SeasonNumber.HasValue)
                    .Select(episode => episode.SeasonNumber!.Value)
                    .Distinct()
                    .Count(),
                children.Count);
        }).ToList();
        return new PagedResponse<SeriesSummary>(items, offset, limit, total);
    }

    public async Task<SeriesDetail> GetSeriesAsync(Guid id, CancellationToken cancellationToken)
    {
        var series = await database.MediaItems
            .AsNoTracking()
            .SingleOrDefaultAsync(item => item.Id == id && item.Kind == MediaKind.Series, cancellationToken)
            ?? throw NotFound("series_not_found", "The series was not found.");
        var children = await database.MediaItems
            .AsNoTracking()
            .Where(item => item.ParentId == id)
            .OrderBy(item => item.SeasonNumber)
            .ThenBy(item => item.EpisodeNumber)
            .ThenBy(item => item.OverrideTitle ?? item.DetectedTitle)
            .ToListAsync(cancellationToken);

        var seasons = children
            .Where(item => item.SeasonNumber.HasValue)
            .GroupBy(item => item.SeasonNumber!.Value)
            .OrderBy(group => group.Key)
            .Select(group => new SeasonSummary(
                group.Key,
                group.Where(item => item.Kind == MediaKind.Episode)
                    .Select(item => new EpisodeSummary(
                        item.Id,
                        item.OverrideTitle ?? item.DetectedTitle,
                        item.SeasonNumber!.Value,
                        item.EpisodeNumber!.Value,
                        item.Availability))
                    .ToList(),
                group.Where(item => item.Kind is MediaKind.Extra or MediaKind.Trailer)
                    .Select(ToSupplement)
                    .ToList()))
            .ToList();
        var seriesSupplements = children
            .Where(item => !item.SeasonNumber.HasValue
                && item.Kind is MediaKind.Extra or MediaKind.Trailer)
            .Select(ToSupplement)
            .ToList();
        return new SeriesDetail(
            series.Id,
            series.OverrideTitle ?? series.DetectedTitle,
            series.Availability,
            seasons,
            seriesSupplements);
    }

    private static SupplementSummary ToSupplement(MediaItem item)
    {
        return new SupplementSummary(
            item.Id,
            item.OverrideTitle ?? item.DetectedTitle,
            item.Kind,
            item.Category,
            item.SeasonNumber,
            item.Availability);
    }

    private static void ValidatePage(int offset, int limit)
    {
        if (offset < 0 || limit is < 1 or > 200)
        {
            throw new LibraryException(
                "invalid_page",
                "Offset must be zero or greater and limit must be between 1 and 200.",
                StatusCodes.Status400BadRequest);
        }
    }

    private static LibraryException NotFound(string code, string message)
    {
        return new LibraryException(code, message, StatusCodes.Status404NotFound);
    }
}
