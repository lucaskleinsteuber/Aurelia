using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;
using System.Security.Cryptography;
using System.Text;

namespace Aurelia.Server.Services;

public sealed class PlaybackProgressService(AureliaDbContext database)
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

        // Match the persisted timestamp precision so the initial response and a
        // replay after a new request/server restart are exactly the same snapshot.
        var now = DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        var progress = await database.PlaybackProgress.SingleOrDefaultAsync(
            candidate => candidate.UserId == userId && candidate.MediaItemId == mediaId,
            cancellationToken);
        var fingerprint = request.ClientMutationId.HasValue ? Fingerprint(request) : null;
        // The response may have been lost after a committed write. Replaying the
        // same mutation is read-only, including the change feed and timestamps.
        if (request.ClientMutationId.HasValue && progress?.LastMutationId == request.ClientMutationId)
        {
            if (progress.LastMutationFingerprint != fingerprint)
                throw new PlaybackException("playback_mutation_reused",
                    "The playback mutation was reused with different values.", StatusCodes.Status409Conflict);
            return ToResponse(progress);
        }
        if (request.EnforceRevision && request.ExpectedRevision != (progress?.Revision ?? 0))
            throw new PlaybackException("playback_progress_conflict",
                "Playback progress changed on another device. Reload before saving.", StatusCodes.Status409Conflict);
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
        progress.Revision = checked(progress.Revision + 1);
        progress.LastMutationId = request.ClientMutationId;
        progress.LastMutationFingerprint = fingerprint;
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
            || request.PositionMilliseconds > request.DurationMilliseconds
            || request.ClientMutationId == Guid.Empty
            || request.ExpectedRevision < 0
            || (request.EnforceRevision && (request.ExpectedRevision is null || request.ClientMutationId is null)))
        {
            throw new PlaybackException(
                "invalid_playback_progress",
                "Playback position and duration are invalid.",
                StatusCodes.Status400BadRequest);
        }
    }

    private static string Fingerprint(UpdatePlaybackProgressRequest request) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(FormattableString.Invariant(
            $"{request.PositionMilliseconds}:{request.DurationMilliseconds}:{request.IsFinished}"))));

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
        progress.UpdatedAt,
        progress.Revision,
        progress.LastMutationId);
}
