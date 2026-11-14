using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;
using System.Security.Cryptography;
using System.Text;

namespace Aurelia.Server.Services;

public sealed class PlaybackProgressService(
    AureliaDbContext database,
    ScreenTimeService? screenTime = null,
    Automation.PlaybackActivityTracker? activity = null)
{
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
        await LibraryStateService.WriteGate.WaitAsync(cancellationToken);
        try
        {
            return await UpdateCoreAsync(userId, mediaId, request, cancellationToken);
        }
        finally
        {
            LibraryStateService.WriteGate.Release();
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

        if (screenTime is not null) await screenTime.RecordProgressAsync(userId, media.Id, request.PositionMilliseconds, cancellationToken);
        if (completed) activity?.Finished(userId, media.Id);

        var newPosition = completed || reset ? 0 : request.PositionMilliseconds;
        var changed = progress.PositionMilliseconds != newPosition || progress.IsCompleted != completed;
        progress.PositionMilliseconds = newPosition;
        progress.DurationMilliseconds = request.DurationMilliseconds;
        progress.IsCompleted = completed;
        if (changed && (request.PositionMilliseconds > 0 || request.IsFinished))
        {
            progress.LastPlayedAt = now;
            var logicalId = media.Kind == MediaKind.Episode && media.SeasonNumber > 0 && media.ParentId.HasValue ? media.ParentId.Value : media.Id;
            var hidden = await database.ContinueWatchingStates.SingleOrDefaultAsync(state => state.UserId == userId && state.MediaItemId == logicalId, cancellationToken);
            if (hidden is { IsHidden: true }) { hidden.IsHidden = false; hidden.Revision = checked(hidden.Revision + 1); }
            await RecordWatchEventAsync(userId, media.Id, request.PositionMilliseconds, request.DurationMilliseconds, completed, now, cancellationToken);
        }
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

    private async Task RecordWatchEventAsync(
        Guid userId,
        Guid mediaId,
        long positionMs,
        long durationMs,
        bool isCompleted,
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        var windowStart = now.AddMinutes(-30);
        var recentEvent = await database.WatchEvents
            .Where(e => e.UserId == userId && e.MediaItemId == mediaId && e.Timestamp >= windowStart)
            .OrderByDescending(e => e.Timestamp)
            .FirstOrDefaultAsync(cancellationToken);

        if (recentEvent is not null)
        {
            // Count the time that actually played: the elapsed time, but never more than the
            // position advanced (a long pause or rewinding adds nothing; faster playback adds the
            // real time spent).
            var elapsedSeconds = Math.Clamp((long)(now - recentEvent.Timestamp).TotalSeconds, 0, 1800);
            var playedSeconds = (positionMs - recentEvent.PositionMilliseconds) / 1000;
            recentEvent.SecondsWatched += playedSeconds > 0 ? Math.Min(elapsedSeconds, playedSeconds + 5) : 0;
            recentEvent.PositionMilliseconds = positionMs;
            recentEvent.DurationMilliseconds = durationMs;
            recentEvent.IsCompleted = recentEvent.IsCompleted || isCompleted;
            recentEvent.Timestamp = now;
        }
        else
        {
            var initialSeconds = Math.Clamp(positionMs / 1000, 10, 60);
            database.WatchEvents.Add(new WatchEvent
            {
                Id = Guid.NewGuid(),
                UserId = userId,
                MediaItemId = mediaId,
                Timestamp = now,
                PositionMilliseconds = positionMs,
                DurationMilliseconds = durationMs,
                SecondsWatched = initialSeconds,
                IsCompleted = isCompleted
            });
        }

        if (Random.Shared.Next(0, 50) == 0)
        {
            var retentionCutoff = now.AddYears(-3);
            // Retention covers every profile's history, not only the one saving progress now.
            var staleEvents = await database.WatchEvents.IgnoreQueryFilters()
                .Where(e => e.Timestamp < retentionCutoff)
                .Take(100)
                .ToListAsync(cancellationToken);
            if (staleEvents.Count > 0)
            {
                database.WatchEvents.RemoveRange(staleEvents);
            }
        }
    }
}
