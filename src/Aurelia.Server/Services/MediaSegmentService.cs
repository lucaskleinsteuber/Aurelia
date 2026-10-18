using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Stores intro and credits timestamps. Analysis happens on an administrator's client; the server
/// only keeps the resulting times and never reads, copies or fingerprints media itself.
/// </summary>
public sealed class MediaSegmentService(AureliaDbContext database, CatalogMutationGate mutations, TimeProvider clock)
{
    public const long MaximumTimestamp = 48L * 60 * 60 * 1000;
    public const long MaximumIntroLength = 15L * 60 * 1000;

    public async Task<MediaSegmentsResponse> GetAsync(Guid mediaId, CancellationToken token)
    {
        await RequirePlayableAsync(mediaId, token);
        var segment = await database.MediaSegments.AsNoTracking().SingleOrDefaultAsync(item => item.MediaItemId == mediaId, token);
        return Response(mediaId, segment);
    }

    public async Task<MediaSegmentsResponse> SetAsync(Guid mediaId, SetMediaSegmentsRequest request, CancellationToken token)
    {
        Validate(request);
        using var lease = await mutations.EnterAsync(token);
        await RequirePlayableAsync(mediaId, token);
        var segment = await database.MediaSegments.SingleOrDefaultAsync(item => item.MediaItemId == mediaId, token);
        // A correction made by hand always wins over later automatic results.
        if (segment is { Source: MediaSegmentSource.Manual } && request.Source != MediaSegmentSource.Manual)
            return Response(mediaId, segment);
        if (segment is null)
        {
            segment = new MediaSegment { MediaItemId = mediaId };
            database.MediaSegments.Add(segment);
        }
        segment.IntroStartMilliseconds = request.IntroStartMilliseconds;
        segment.IntroEndMilliseconds = request.IntroEndMilliseconds;
        segment.CreditsStartMilliseconds = request.CreditsStartMilliseconds;
        segment.Source = request.Source;
        segment.AnalysisVersion = request.AnalysisVersion;
        segment.UpdatedAt = clock.GetUtcNow();
        await database.SaveChangesAsync(token);
        return Response(mediaId, segment);
    }

    public async Task ClearAsync(Guid mediaId, CancellationToken token)
    {
        using var lease = await mutations.EnterAsync(token);
        await RequirePlayableAsync(mediaId, token);
        await database.MediaSegments.Where(item => item.MediaItemId == mediaId).ExecuteDeleteAsync(token);
    }

    /// <summary>
    /// Seasons and movies that still need analysis at <paramref name="analysisVersion"/>. Every
    /// available episode of such a season is listed, because episodes are compared with each other.
    /// </summary>
    public async Task<MediaSegmentAnalysisQueueResponse> QueueAsync(int analysisVersion, int limit, CancellationToken token)
    {
        limit = Math.Clamp(limit, 1, 50);
        var playable = await database.MediaItems.AsNoTracking()
            .Where(item => (item.Kind == MediaKind.Episode || item.Kind == MediaKind.Movie) && item.Availability == MediaAvailability.Available)
            .Select(item => new { item.Id, item.Kind, item.ParentId, item.SeasonNumber, item.EpisodeNumber })
            .ToListAsync(token);
        var segments = await database.MediaSegments.AsNoTracking()
            .Select(item => new { item.MediaItemId, item.Source, item.AnalysisVersion })
            .ToDictionaryAsync(item => item.MediaItemId, token);
        bool Needs(Guid id) => !segments.TryGetValue(id, out var segment)
            || (segment.Source != MediaSegmentSource.Manual && segment.AnalysisVersion < analysisVersion);

        var seasons = playable.Where(item => item.Kind == MediaKind.Episode && item.ParentId != null)
            .GroupBy(item => (Series: item.ParentId!.Value, Season: item.SeasonNumber ?? 0))
            .OrderBy(group => group.Key.Series).ThenBy(group => group.Key.Season)
            .Select(group => new MediaSegmentAnalysisGroup(group.Key.Series, group.Key.Season,
                group.OrderBy(item => item.EpisodeNumber ?? int.MaxValue).ThenBy(item => item.Id)
                    .Select(item => new MediaSegmentAnalysisItem(item.Id, item.EpisodeNumber, Needs(item.Id))).ToList()));
        var movies = playable.Where(item => item.Kind == MediaKind.Movie).OrderBy(item => item.Id)
            .Select(item => new MediaSegmentAnalysisGroup(null, null, [new MediaSegmentAnalysisItem(item.Id, null, Needs(item.Id))]));
        return new(seasons.Concat(movies).Where(group => group.Items.Any(item => item.NeedsAnalysis)).Take(limit).ToList());
    }

    private static void Validate(SetMediaSegmentsRequest request)
    {
        static bool InRange(long? value) => value is null or >= 0 and <= MaximumTimestamp;
        var introComplete = request.IntroStartMilliseconds.HasValue == request.IntroEndMilliseconds.HasValue;
        var introOrdered = request.IntroStartMilliseconds is not { } start || request.IntroEndMilliseconds is not { } end
            || (end > start && end - start <= MaximumIntroLength);
        var noneIsEmpty = request.Source != MediaSegmentSource.None
            || (request.IntroStartMilliseconds is null && request.CreditsStartMilliseconds is null);
        if (!Enum.IsDefined(request.Source) || request.AnalysisVersion is < 0 or > 1000
            || !InRange(request.IntroStartMilliseconds) || !InRange(request.IntroEndMilliseconds)
            || !InRange(request.CreditsStartMilliseconds) || !introComplete || !introOrdered || !noneIsEmpty)
            throw new AccountException("invalid_media_segments", "Enter an intro that ends after it starts and lasts at most 15 minutes, and valid times.", 400);
    }

    private async Task RequirePlayableAsync(Guid id, CancellationToken token)
    {
        if (!await database.MediaItems.AnyAsync(item => item.Id == id && item.Kind != MediaKind.Series, token))
            throw new AccountException("media_not_found", "The playable media was not found.", 404);
    }

    private static MediaSegmentsResponse Response(Guid mediaId, MediaSegment? segment) => segment is null
        ? new(mediaId, false, null, null, null, MediaSegmentSource.None, 0)
        : new(mediaId, true, segment.IntroStartMilliseconds, segment.IntroEndMilliseconds, segment.CreditsStartMilliseconds,
            segment.Source, segment.AnalysisVersion);
}
