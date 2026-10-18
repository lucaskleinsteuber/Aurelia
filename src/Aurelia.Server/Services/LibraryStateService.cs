using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

// Progress and library-state commands share one write boundary. Tokens are checked
// inside the transaction, and durable receipts make retries safe across restarts.
public sealed class LibraryStateService(AureliaDbContext database)
{
    public static readonly IReadOnlyList<string> Capabilities = Array.AsReadOnly(new[] { "library-state-v1" });
    internal static readonly SemaphoreSlim WriteGate = new(1, 1);
    internal sealed record PlaybackSelection(MediaItem? Target, Guid? SeriesId,
        IReadOnlyList<MediaItem> Queue, PlaybackPlanAction Action, bool ContinueWatchingEligible);

    internal async Task<PlaybackSelection> SelectAsync(Guid userId, Guid mediaId, CancellationToken cancellationToken)
    {
        var media = await RequireAsync(mediaId, cancellationToken);
        if (media.Kind != MediaKind.Series)
        {
            var progress = await database.PlaybackProgress.AsNoTracking().SingleOrDefaultAsync(
                value => value.UserId == userId && value.MediaItemId == mediaId, cancellationToken);
            var queue = media.Kind == MediaKind.Episode && media.SeasonNumber > 0 && media.ParentId.HasValue
                ? (await EpisodesAsync(userId, media.ParentId.Value, null, cancellationToken)).SkipWhile(item => item.Id != media.Id).Skip(1).ToList()
                : [];
            return new(media, media.Kind == MediaKind.Episode ? media.ParentId : null, queue,
                progress is { IsCompleted: true } ? PlaybackPlanAction.PlayAgain
                    : progress is { PositionMilliseconds: > 10_000 } ? PlaybackPlanAction.Resume : PlaybackPlanAction.Play,
                progress is { IsCompleted: false, PositionMilliseconds: > 10_000 });
        }
        var episodes = await EpisodesAsync(userId, media.Id, null, cancellationToken);
        var plan = await new SeriesResumeQuery(database).Plans(userId).SingleOrDefaultAsync(value => value.SeriesId == media.Id, cancellationToken);
        if (plan is null) return new(null, media.Id, [], PlaybackPlanAction.Play, false);
        var target = episodes.Single(value => value.Id == plan.TargetId);
        return new(target, media.Id, episodes.SkipWhile(value => value.Id != target.Id).Skip(1).ToList(),
            (PlaybackPlanAction)plan.ActionCode, plan.ContinueWatchingEligible);
    }

    internal async Task<List<MediaItem>> EpisodesAsync(Guid userId, Guid seriesId, int? season, CancellationToken cancellationToken) =>
        await database.MediaItems.AsNoTracking().Include(item => item.PlaybackProgress.Where(progress => progress.UserId == userId))
            .Where(item => item.ParentId == seriesId && item.Kind == MediaKind.Episode
                && (season.HasValue ? item.SeasonNumber == season : item.SeasonNumber > 0))
            .OrderBy(item => item.SeasonNumber).ThenBy(item => item.EpisodeNumber).ThenBy(item => item.DetectedTitle).ThenBy(item => item.Id)
            .ToListAsync(cancellationToken);

    public async Task<WatchStateResponse> GetAsync(Guid userId, Guid mediaId, WatchStateScope scope,
        int? season, CancellationToken cancellationToken)
    {
        var (media, affected) = await ResolveAsync(userId, mediaId, scope, season, cancellationToken);
        return await SnapshotAsync(userId, media, affected, scope, season, cancellationToken);
    }

    public Task<WatchStateResponse> SetAsync(Guid userId, Guid mediaId, SetWatchStateRequest request, CancellationToken cancellationToken) =>
        MutateAsync(userId, mediaId, request.Scope, request.SeasonNumber, request.StateToken, request.ClientMutationId,
            $"watch:{request.IsWatched}", request.IsWatched, null, cancellationToken);

    /// <summary>
    /// Continue Watching belongs to a movie or series. An episode or extra is accepted too and
    /// applies to its series, after checking the token the client read for that episode.
    /// </summary>
    public async Task<WatchStateResponse> SetHiddenAsync(Guid userId, Guid mediaId, SetContinueWatchingRequest request, CancellationToken cancellationToken)
    {
        var target = await database.MediaItems.AsNoTracking().Where(item => item.Id == mediaId)
            .Select(item => new { item.Kind, item.ParentId }).SingleOrDefaultAsync(cancellationToken);
        if (target is { Kind: not MediaKind.Movie and not MediaKind.Series, ParentId: { } parentId })
        {
            var own = await GetAsync(userId, mediaId, WatchStateScope.Title, null, cancellationToken);
            if (string.IsNullOrEmpty(request.StateToken)
                || !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(request.StateToken), Encoding.UTF8.GetBytes(own.StateToken)))
                throw new AccountException("library_state_conflict", "The library state changed. Reload before saving.", 409);
            var parent = await GetAsync(userId, parentId, WatchStateScope.Title, null, cancellationToken);
            return await MutateAsync(userId, parentId, WatchStateScope.Title, null, parent.StateToken, request.ClientMutationId,
                $"hidden:{request.IsHidden}", null, request.IsHidden, cancellationToken);
        }
        return await MutateAsync(userId, mediaId, WatchStateScope.Title, null, request.StateToken, request.ClientMutationId,
            $"hidden:{request.IsHidden}", null, request.IsHidden, cancellationToken);
    }

    private async Task<WatchStateResponse> MutateAsync(Guid userId, Guid mediaId, WatchStateScope scope, int? season,
        string token, Guid mutationId, string operation, bool? watched, bool? hidden, CancellationToken cancellationToken)
    {
        if (mutationId == Guid.Empty || string.IsNullOrWhiteSpace(token) || token.Length > 128)
            throw new AccountException("invalid_library_state", "A current state token and mutation ID are required.", 400);
        await WriteGate.WaitAsync(cancellationToken);
        try
        {
            await using var transaction = await database.Database.BeginTransactionAsync(cancellationToken);
            var (media, affected) = await ResolveAsync(userId, mediaId, scope, season, cancellationToken);
            if (hidden.HasValue && media.Kind is not MediaKind.Movie and not MediaKind.Series)
                throw new AccountException("invalid_continue_watching", "Continue Watching uses a movie or series.", 400);
            var user = await database.Users.SingleAsync(value => value.Id == userId, cancellationToken);
            var fingerprint = Hash($"{mediaId}:{scope}:{season}:{operation}:{token}");
            var receipt = await database.LibraryStateMutations.AsNoTracking().SingleOrDefaultAsync(
                value => value.UserId == userId && value.ClientMutationId == mutationId, cancellationToken);
            if (receipt is not null)
            {
                if (receipt.Fingerprint != fingerprint || receipt.AccessRevision != user.AccessRevision)
                    throw new AccountException("library_state_mutation_reused", "Reload before saving this library state.", 409);
                return JsonSerializer.Deserialize<WatchStateResponse>(receipt.ResponseJson)!;
            }
            var snapshot = await SnapshotAsync(userId, media, affected, scope, season, cancellationToken);
            if (!CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(token), Encoding.UTF8.GetBytes(snapshot.StateToken)))
                throw new AccountException("library_state_conflict", "The library state changed. Reload before saving.", 409);
            var affectedIds = affected.Select(item => item.Id).ToList();
            var existingProgress = await database.PlaybackProgress.Where(value => value.UserId == userId && affectedIds.Contains(value.MediaItemId))
                .ToDictionaryAsync(value => value.MediaItemId, cancellationToken);
            if (watched.HasValue)
            {
                var now = DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                foreach (var item in affected)
                {
                    var progress = existingProgress.GetValueOrDefault(item.Id);
                    if (progress is null)
                    {
                        progress = new PlaybackProgress { Id = Guid.NewGuid(), UserId = userId, User = user, MediaItemId = item.Id, MediaItem = null!, Revision = 0 };
                        database.PlaybackProgress.Add(progress);
                    }
                    progress.PositionMilliseconds = 0;
                    progress.IsCompleted = watched.Value;
                    progress.UpdatedAt = now;
                    progress.Revision = checked(progress.Revision + 1);
                    progress.LastMutationId = null;
                    progress.LastMutationFingerprint = null;
                }
            }
            else
            {
                // Invalidate pre-hide progress queued on any device, without changing
                // positions, completion, duration or the real last-played timestamp.
                foreach (var item in affected)
                {
                    var progress = existingProgress.GetValueOrDefault(item.Id);
                    if (progress is null)
                    {
                        progress = new PlaybackProgress { Id = Guid.NewGuid(), UserId = userId, User = user, MediaItemId = item.Id, MediaItem = null! };
                        database.PlaybackProgress.Add(progress);
                    }
                    progress.Revision = checked(progress.Revision + 1);
                    progress.LastMutationId = null;
                    progress.LastMutationFingerprint = null;
                }
                var state = await database.ContinueWatchingStates.SingleOrDefaultAsync(value => value.UserId == userId && value.MediaItemId == media.Id, cancellationToken);
                if (state is null)
                {
                    state = new ContinueWatchingState { UserId = userId, User = user, MediaItemId = media.Id, MediaItem = media };
                    database.ContinueWatchingStates.Add(state);
                }
                state.IsHidden = hidden!.Value;
                state.Revision = checked(state.Revision + 1);
            }
            await database.SaveChangesAsync(cancellationToken);
            // Read the committed transaction state instead of a pre-write projection.
            var result = await GetAsync(userId, mediaId, scope, season, cancellationToken);
            database.LibraryStateMutations.Add(new LibraryStateMutation
            {
                UserId = userId,
                User = user,
                ClientMutationId = mutationId,
                AccessRevision = user.AccessRevision,
                Fingerprint = fingerprint,
                ResponseJson = JsonSerializer.Serialize(result)
            });
            await database.SaveChangesAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);
            return result;
        }
        finally { WriteGate.Release(); }
    }

    private async Task<(MediaItem Media, List<MediaItem> Affected)> ResolveAsync(Guid userId, Guid id,
        WatchStateScope scope, int? season, CancellationToken cancellationToken)
    {
        if (!Enum.IsDefined(scope) || (scope == WatchStateScope.Season ? season is null or < 0 : season.HasValue))
            throw new AccountException("invalid_watch_scope", "Choose a valid title, season or series scope.", 400);
        var media = await RequireAsync(id, cancellationToken);
        if (scope != WatchStateScope.Title && media.Kind != MediaKind.Series)
            throw new AccountException("invalid_watch_scope", "Season and series actions require a series.", 400);
        if (media.Kind == MediaKind.Series)
        {
            var episodes = await EpisodesAsync(userId, media.Id, scope == WatchStateScope.Season ? season : null, cancellationToken);
            if (scope == WatchStateScope.Season && episodes.Count == 0)
                throw new AccountException("season_not_found", "The season was not found.", 404);
            return (media, episodes);
        }
        return (media, [media]);
    }

    private async Task<WatchStateResponse> SnapshotAsync(Guid userId, MediaItem media, List<MediaItem> affected,
        WatchStateScope scope, int? season, CancellationToken cancellationToken)
    {
        var ids = affected.Select(item => item.Id).ToList();
        var progress = await database.PlaybackProgress.AsNoTracking().Where(value => value.UserId == userId && ids.Contains(value.MediaItemId)).ToListAsync(cancellationToken);
        var progressById = progress.ToDictionary(value => value.MediaItemId);
        var logicalId = media.Kind == MediaKind.Episode && media.ParentId.HasValue ? media.ParentId.Value : media.Id;
        var hidden = await database.ContinueWatchingStates.AsNoTracking().SingleOrDefaultAsync(value => value.UserId == userId && value.MediaItemId == logicalId, cancellationToken);
        var user = await database.Users.AsNoTracking().SingleAsync(value => value.Id == userId, cancellationToken);
        var revisions = string.Join(';', affected.OrderBy(item => item.Id).Select(item => $"{item.Id}:{item.ParentId}:{item.LibraryRootId}:{item.UpdatedAt.ToUnixTimeMilliseconds()}:{item.Kind}:{item.SeasonNumber}:{item.EpisodeNumber}:{progressById.GetValueOrDefault(item.Id)?.Revision ?? 0}"));
        var token = Hash($"{userId}:{media.Id}:{scope}:{season}:{user.AccessRevision}:{user.ProfileRevision}:{user.AccessMode}:{user.Role}:{revisions}:{hidden?.Revision ?? 0}");
        return new(media.Id, scope, season, Aggregate(affected.Count, progress), affected.Count, token, hidden?.IsHidden ?? false);
    }

    internal static CatalogWatchState Aggregate(int count, IEnumerable<PlaybackProgress> progress)
    {
        var values = progress.ToList();
        if (count > 0 && values.Count(value => value.IsCompleted) == count) return CatalogWatchState.Completed;
        return values.Any(value => value.IsCompleted || value.PositionMilliseconds > 0) ? CatalogWatchState.InProgress : CatalogWatchState.Unplayed;
    }

    private async Task<MediaItem> RequireAsync(Guid id, CancellationToken cancellationToken) =>
        await database.MediaItems.SingleOrDefaultAsync(item => item.Id == id, cancellationToken)
            ?? throw new AccountException("media_not_found", "The media item was not found.", 404);
    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
