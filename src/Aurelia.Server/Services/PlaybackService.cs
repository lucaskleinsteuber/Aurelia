using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed record PlaybackStreamSource(
    FileStream Stream,
    string ContentType,
    long ContentLength,
    DateTimeOffset LastModified,
    Guid MediaId,
    string SourcePath = "");

public sealed class PlaybackService(
    AureliaDbContext database,
    TokenService tokenService,
    PlaybackProgressService progressService,
    PlaybackTicketPolicy? ticketPolicy = null,
    ProfileSessionStore? profiles = null,
    MediaSegmentService? segments = null)
{
    private const int CleanupBatchSize = 100;

    public async Task<PlaybackSourceResponse> CreateAsync(
        Guid userId,
        Guid deviceSessionId,
        Guid mediaId,
        CancellationToken cancellationToken,
        Guid? profileSessionId = null)
    {
        var now = DateTimeOffset.UtcNow;
        await PruneExpiredAsync(now, cancellationToken);

        var session = await database.DeviceSessions
            .Include(candidate => candidate.User)
            .SingleOrDefaultAsync(
                candidate => candidate.Id == deviceSessionId
                    && (profileSessionId != null || candidate.UserId == userId)
                    && candidate.RevokedAt == null
                    && candidate.ExpiresAt > now,
                cancellationToken)
            ?? throw new PlaybackException(
                "invalid_session",
                "The device session is no longer valid.",
                StatusCodes.Status401Unauthorized);
        if (profileSessionId is { } profileId && profiles?.IsActive(profileId, deviceSessionId, userId) != true)
            throw new PlaybackException("invalid_profile_session", "Unlock your profile again.", 401);
        var activeUser = await database.Users.SingleAsync(user => user.Id == userId && user.IsEnabled, cancellationToken);

        var media = await database.MediaItems
            .Include(candidate => candidate.LibraryRoot)
            .SingleOrDefaultAsync(candidate => candidate.Id == mediaId, cancellationToken)
            ?? throw new PlaybackException(
                "media_not_found",
                "The media item was not found.",
                StatusCodes.Status404NotFound);

        if (media.Kind == MediaKind.Series)
        {
            throw new PlaybackException(
                "media_not_playable",
                "This media item is a container and cannot be played directly.",
                StatusCodes.Status409Conflict);
        }

        // Scanner availability is a catalog hint, not a live I/O guarantee. A
        // reconnected drive must be playable before the next monitoring pass.
        // The access-filtered lookup above still precedes this secure handle open.
        var file = MediaFileAccess.OpenRead(media);
        using var fileStream = file.Stream;
        var rawToken = tokenService.CreatePlaybackToken();
        var expiresAt = now.Add(ticketPolicy?.Lifetime ?? PlaybackTicketPolicy.ProductionLifetime);
        var ticket = new PlaybackTicket
        {
            Id = Guid.NewGuid(),
            MediaItem = media,
            MediaItemId = media.Id,
            User = activeUser,
            UserId = userId,
            DeviceSession = session,
            DeviceSessionId = session.Id,
            ProfileSessionId = profileSessionId,
            TokenHash = tokenService.Hash(rawToken),
            CreatedAt = now,
            ExpiresAt = expiresAt,
        };
        database.PlaybackTickets.Add(ticket);
        await database.SaveChangesAsync(cancellationToken);

        return new PlaybackSourceResponse(
            ticket.Id,
            media.Id,
            $"/api/v1/streams/{rawToken}",
            file.ContentType,
            file.Length,
            expiresAt,
            await progressService.GetSnapshotAsync(
                userId,
                media.Id,
                cancellationToken),
            segments is null ? null : await segments.ForPlaybackAsync(media.Id, cancellationToken));
    }

    public async Task RevokeAsync(
        Guid userId,
        Guid playbackId,
        CancellationToken cancellationToken)
    {
        var ticket = await database.PlaybackTickets.SingleOrDefaultAsync(
            candidate => candidate.Id == playbackId && candidate.UserId == userId,
            cancellationToken)
            ?? throw new PlaybackException(
                "playback_not_found",
                "The playback ticket was not found.",
                StatusCodes.Status404NotFound);

        ticket.RevokedAt ??= DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
    }

    public async Task<PlaybackStreamSource?> OpenStreamAsync(
        string rawToken,
        Guid userId,
        Guid deviceSessionId,
        CancellationToken cancellationToken,
        Guid? profileSessionId = null)
    {
        if (!IsValidToken(rawToken))
        {
            return null;
        }

        var now = DateTimeOffset.UtcNow;
        if (profileSessionId is { } profileId && profiles?.IsActive(profileId, deviceSessionId, userId) != true) return null;
        var tokenHash = tokenService.Hash(rawToken);
        var ticket = await database.PlaybackTickets
            .AsNoTracking()
            .Include(candidate => candidate.DeviceSession)
            .Include(candidate => candidate.MediaItem)
            .ThenInclude(media => media.LibraryRoot)
            .SingleOrDefaultAsync(
                candidate => candidate.TokenHash == tokenHash
                    && candidate.UserId == userId
                    && candidate.DeviceSessionId == deviceSessionId
                    && candidate.ProfileSessionId == profileSessionId
                    && candidate.RevokedAt == null
                    && candidate.ExpiresAt > now
                    && candidate.DeviceSession.RevokedAt == null
                    && candidate.DeviceSession.ExpiresAt > now
                    && candidate.DeviceSession.User.IsEnabled
                    && candidate.User.IsEnabled
                    && database.MediaItems.Any(item => item.Id == candidate.MediaItemId),
                cancellationToken);
        if (ticket is null || ticket.MediaItem.Kind == MediaKind.Series)
        {
            return null;
        }

        // Only an authorized, valid ticket may distinguish transient storage
        // loss from an invalid ticket. Do not collapse that failure into 404.
        var file = MediaFileAccess.OpenRead(ticket.MediaItem);
        return new PlaybackStreamSource(
            file.Stream,
            file.ContentType,
            file.Length,
            file.LastModified,
            ticket.MediaItemId,
            Path.GetFullPath(ticket.MediaItem.SourcePath));
    }

    public async Task PruneExpiredAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        var expiredIds = await database.PlaybackTickets
            .Where(ticket => ticket.ExpiresAt <= now || ticket.RevokedAt != null)
            .OrderBy(ticket => ticket.ExpiresAt)
            .Select(ticket => ticket.Id)
            .Take(CleanupBatchSize)
            .ToListAsync(cancellationToken);
        if (expiredIds.Count > 0)
        {
            await database.PlaybackTickets
                .Where(ticket => expiredIds.Contains(ticket.Id))
                .ExecuteDeleteAsync(cancellationToken);
        }
    }

    private static bool IsValidToken(string value)
    {
        return value.Length == 43
            && value.All(character => char.IsAsciiLetterOrDigit(character)
                || character is '-' or '_');
    }
}
