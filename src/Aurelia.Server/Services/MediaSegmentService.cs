using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Reads and corrects one title's intro and credits timestamps. Detection itself runs in
/// <see cref="SegmentDetectionService"/>; a time set here by hand is never replaced by it.
/// </summary>
public sealed class MediaSegmentService(
    AureliaDbContext database,
    CatalogMutationGate mutations,
    SegmentDetectionService detection,
    LiveConversionService live,
    TimeProvider clock)
{
    public const long MaximumTimestamp = 48L * 60 * 60 * 1000;
    public const long MaximumIntroLength = 15L * 60 * 1000;

    public async Task<MediaSegmentsResponse> GetAsync(Guid mediaId, CancellationToken cancellationToken)
    {
        var media = await RequirePlayableAsync(mediaId, cancellationToken);
        var row = await database.MediaSegments.AsNoTracking().SingleOrDefaultAsync(segment => segment.MediaItemId == mediaId, cancellationToken);
        return Response(media, row);
    }

    /// <summary>The times for the playback ticket, or null when there is nothing to skip.</summary>
    public async Task<MediaSegmentsDto?> ForPlaybackAsync(Guid mediaId, CancellationToken cancellationToken)
    {
        var row = await database.MediaSegments.AsNoTracking().SingleOrDefaultAsync(segment => segment.MediaItemId == mediaId, cancellationToken);
        if (row is null) return null;
        // With detection turned off only times set by hand are handed out.
        var enabled = detection.IsEnabled;
        var intro = enabled || row.IntroSource == MediaSegmentSource.Manual;
        var credits = enabled || row.CreditsSource == MediaSegmentSource.Manual;
        var result = new MediaSegmentsDto(
            intro && row.IntroEndMilliseconds is not null ? row.IntroStartMilliseconds : null,
            intro && row.IntroStartMilliseconds is not null ? row.IntroEndMilliseconds : null,
            credits ? row.CreditsStartMilliseconds : null);
        return result is { IntroEndMilliseconds: null, CreditsStartMilliseconds: null } ? null : result;
    }

    public async Task<MediaSegmentsResponse> SetAsync(Guid mediaId, SetMediaSegmentsRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var media = await RequirePlayableAsync(mediaId, cancellationToken);
        Validate(request, await DurationMillisecondsAsync(media, cancellationToken));
        using var lease = await mutations.EnterAsync(cancellationToken);
        var row = await database.MediaSegments.SingleOrDefaultAsync(segment => segment.MediaItemId == mediaId, cancellationToken);
        if (row is null)
        {
            row = new MediaSegment { MediaItemId = mediaId };
            database.MediaSegments.Add(row);
        }
        // Only the part that was changed becomes a correction; the other keeps following detection.
        if (row.IntroStartMilliseconds != request.IntroStartMilliseconds || row.IntroEndMilliseconds != request.IntroEndMilliseconds)
        {
            row.IntroStartMilliseconds = request.IntroStartMilliseconds;
            row.IntroEndMilliseconds = request.IntroEndMilliseconds;
            row.IntroSource = MediaSegmentSource.Manual;
            row.IntroConfidence = 1;
        }
        if (row.CreditsStartMilliseconds != request.CreditsStartMilliseconds)
        {
            row.CreditsStartMilliseconds = request.CreditsStartMilliseconds;
            row.CreditsSource = MediaSegmentSource.Manual;
            row.CreditsConfidence = 1;
        }
        row.UpdatedAt = clock.GetUtcNow();
        await database.SaveChangesAsync(cancellationToken);
        RequestAnalysisIfNeeded(media, row);
        return Response(media, row);
    }

    /// <summary>Removes the corrections; the title is examined again and gets its automatic times back.</summary>
    public async Task<MediaSegmentsResponse> ClearManualAsync(Guid mediaId, CancellationToken cancellationToken)
    {
        var media = await RequirePlayableAsync(mediaId, cancellationToken);
        using var lease = await mutations.EnterAsync(cancellationToken);
        var row = await database.MediaSegments.SingleOrDefaultAsync(segment => segment.MediaItemId == mediaId, cancellationToken);
        if (row is null) return Response(media, null);
        var changed = false;
        if (row.IntroSource == MediaSegmentSource.Manual)
        {
            (row.IntroStartMilliseconds, row.IntroEndMilliseconds, row.IntroSource, row.IntroConfidence) = (null, null, MediaSegmentSource.None, 0);
            changed = true;
        }
        if (row.CreditsSource == MediaSegmentSource.Manual)
        {
            (row.CreditsStartMilliseconds, row.CreditsSource, row.CreditsConfidence) = (null, MediaSegmentSource.None, 0);
            changed = true;
        }
        if (changed)
        {
            row.AnalysisVersion = 0;
            row.UpdatedAt = clock.GetUtcNow();
            await database.SaveChangesAsync(cancellationToken);
        }
        RequestAnalysisIfNeeded(media, row);
        return Response(media, row);
    }

    /// <summary>Examines the season of an episode, or every season of a series, again.</summary>
    public async Task<MediaSegmentSettingsResponse> ReanalyzeAsync(Guid mediaId, CancellationToken cancellationToken)
    {
        var media = await database.MediaItems.AsNoTracking().SingleOrDefaultAsync(item => item.Id == mediaId, cancellationToken)
            ?? throw new AccountException("media_not_found", "The media item was not found.", 404);
        return media switch
        {
            { Kind: MediaKind.Series } => await detection.ReanalyzeAsync(media.Id, null, cancellationToken),
            { Kind: MediaKind.Episode, ParentId: { } series } => await detection.ReanalyzeAsync(series, media.SeasonNumber ?? 0, cancellationToken),
            _ => throw new AccountException("media_segments_unavailable", "Intros and credits are only detected for episodes of a series.", 409),
        };
    }

    private void RequestAnalysisIfNeeded(MediaItem media, MediaSegment row)
    {
        if (media is { Kind: MediaKind.Episode, ParentId: { } series } && !SegmentDetectionService.IsCurrent(row, media.FileSize, media.FileModifiedAt))
            detection.RequestSeason(series, media.SeasonNumber ?? 0);
    }

    private static void Validate(SetMediaSegmentsRequest request, long? duration)
    {
        var limit = duration ?? MaximumTimestamp;
        bool InRange(long? value) => value is null || (value >= 0 && value <= limit);
        var introComplete = request.IntroStartMilliseconds.HasValue == request.IntroEndMilliseconds.HasValue;
        var introOrdered = request.IntroStartMilliseconds is not { } start || request.IntroEndMilliseconds is not { } end
            || (end > start && end - start <= MaximumIntroLength);
        var creditsAfterIntro = request.CreditsStartMilliseconds is not { } credits || request.IntroEndMilliseconds is not { } introEnd || credits > introEnd;
        if (!InRange(request.IntroStartMilliseconds) || !InRange(request.IntroEndMilliseconds) || !InRange(request.CreditsStartMilliseconds)
            || !introComplete || !introOrdered || !creditsAfterIntro)
            throw new AccountException("invalid_media_segments",
                "Enter an intro that ends after it starts and lasts at most 15 minutes, credits that begin after it, and times inside the title.", 400);
    }

    /// <summary>The title's length when the server can read it now; otherwise only the general limit applies.</summary>
    private async Task<long?> DurationMillisecondsAsync(MediaItem media, CancellationToken cancellationToken)
    {
        if (await live.ToolsAsync() is not { } tools) return null;
        try
        {
            var file = MediaFileAccess.OpenRead(media);
            await using var stream = file.Stream;
            var probe = await live.ProbeAsync(tools, file, Path.GetFullPath(media.SourcePath), media.Id, cancellationToken);
            return probe.DurationSeconds is { } seconds ? (long)Math.Ceiling(seconds * 1000) : null;
        }
        catch (Exception exception) when (exception is PlaybackException or IOException)
        {
            return null;
        }
    }

    private async Task<MediaItem> RequirePlayableAsync(Guid id, CancellationToken cancellationToken) =>
        await database.MediaItems.AsNoTracking().Include(item => item.LibraryRoot)
            .SingleOrDefaultAsync(item => item.Id == id && item.Kind != MediaKind.Series, cancellationToken)
        ?? throw new AccountException("media_not_found", "The playable media was not found.", 404);

    private static MediaSegmentsResponse Response(MediaItem media, MediaSegment? row)
    {
        var canAnalyze = media is { Kind: MediaKind.Episode, ParentId: not null };
        return row is null
            ? new(media.Id, false, canAnalyze, null, null, MediaSegmentSource.None, 0, null, MediaSegmentSource.None, 0)
            : new(media.Id, SegmentDetectionService.IsCurrent(row, media.FileSize, media.FileModifiedAt), canAnalyze,
                row.IntroStartMilliseconds, row.IntroEndMilliseconds, row.IntroSource, row.IntroConfidence,
                row.CreditsStartMilliseconds, row.CreditsSource, row.CreditsConfidence);
    }
}
