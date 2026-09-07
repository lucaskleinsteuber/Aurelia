using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Home.Server.Services;

public sealed class PlaybackProgressService(AureliaHomeDbContext database)
{
    private static readonly SemaphoreSlim UpdateLock = new(1, 1);
    private const long MeaningfulProgressMilliseconds = 10_000;
    private const long CompletionWindowMilliseconds = 45_000;
    private const long MinimumCompletionThresholdMilliseconds = 30_000;

    public async Task<PlaybackProgressResponse> GetAsync(
        Guid userId,
        Guid mediaId,
        CancellationToken cancellationToken)
    {
        await RequirePlayableMediaAsync(mediaId, cancellationToken);
        return await GetSnapshotAsync(userId, mediaId, cancellationToken);
    }

    public async Task<PlaybackProgressResponse> UpdateAsync(
        Guid userId,
        Guid mediaId,
        UpdatePlaybackProgressRequest request,
        CancellationToken cancellationToken)
    {
        Validate(request);
        await UpdateLock.WaitAsync(cancellationToken);
        try
        {
            return await UpdateCoreAsync(userId, mediaId, request, cancellationToken);
        }
        finally
        {
            UpdateLock.Release();
        }
    }

    private async Task<PlaybackProgressResponse> UpdateCoreAsync(
        Guid userId,
        Guid mediaId,
        UpdatePlaybackProgressRequest request,
        CancellationToken cancellationToken)
    {
        var media = await RequirePlayableMediaAsync(mediaId, cancellationToken);

        var now = DateTimeOffset.UtcNow;
        var progress = await database.PlaybackProgress.SingleOrDefaultAsync(
            candidate => candidate.UserId == userId && candidate.MediaItemId == mediaId,
            cancellationToken);
        if (progress is null)
        {
            var user = await database.Users.SingleOrDefaultAsync(
                candidate => candidate.Id == userId,
                cancellationToken)
                ?? throw new PlaybackException(
                    "invalid_session",
                    "The authenticated user no longer exists.",
                    StatusCodes.Status401Unauthorized);
            progress = new PlaybackProgress
            {
                Id = Guid.NewGuid(),
                MediaItem = media,
                MediaItemId = media.Id,
                User = user,
                UserId = user.Id,
                LastPlayedAt = now,
                UpdatedAt = now,
            };
            database.PlaybackProgress.Add(progress);
        }

        var completionThreshold = Math.Max(
            request.DurationMilliseconds - CompletionWindowMilliseconds,
            MinimumCompletionThresholdMilliseconds);
        var completed = request.IsFinished
            || request.PositionMilliseconds >= completionThreshold;
        var reset = !completed
            && request.PositionMilliseconds <= MeaningfulProgressMilliseconds;

        progress.PositionMilliseconds = completed || reset
            ? 0
            : request.PositionMilliseconds;
        progress.DurationMilliseconds = request.DurationMilliseconds;
        progress.IsCompleted = completed;
        progress.LastPlayedAt = now;
        progress.UpdatedAt = now;
        await database.SaveChangesAsync(cancellationToken);

        return ToResponse(progress);
    }

    public async Task<PlaybackProgressResponse> GetSnapshotAsync(
        Guid userId,
        Guid mediaId,
        CancellationToken cancellationToken)
    {
        var progress = await database.PlaybackProgress
            .AsNoTracking()
            .SingleOrDefaultAsync(
                candidate => candidate.UserId == userId && candidate.MediaItemId == mediaId,
                cancellationToken);
        return progress is null
            ? Empty(mediaId)
            : ToResponse(progress);
    }

    private async Task<MediaItem> RequirePlayableMediaAsync(
        Guid mediaId,
        CancellationToken cancellationToken)
    {
        var media = await database.MediaItems.SingleOrDefaultAsync(
            candidate => candidate.Id == mediaId,
            cancellationToken)
            ?? throw new PlaybackException(
                "media_not_found",
                "The media item was not found.",
                StatusCodes.Status404NotFound);
        if (media.Kind == MediaKind.Series)
        {
            throw new PlaybackException(
                "media_not_playable",
                "This media item is a container and has no playback progress.",
                StatusCodes.Status409Conflict);
        }

        return media;
    }

    private static void Validate(UpdatePlaybackProgressRequest request)
    {
        if (request.PositionMilliseconds < 0
            || request.DurationMilliseconds <= 0
            || request.PositionMilliseconds > request.DurationMilliseconds)
        {
            throw new PlaybackException(
                "invalid_playback_progress",
                "Playback position and duration are invalid.",
                StatusCodes.Status400BadRequest);
        }
    }

    private static PlaybackProgressResponse Empty(Guid mediaId) => new(
        mediaId,
        0,
        0,
        false,
        null,
        null);

    private static PlaybackProgressResponse ToResponse(PlaybackProgress progress) => new(
        progress.MediaItemId,
        progress.PositionMilliseconds,
        progress.DurationMilliseconds,
        progress.IsCompleted,
        progress.LastPlayedAt,
        progress.UpdatedAt);
}
