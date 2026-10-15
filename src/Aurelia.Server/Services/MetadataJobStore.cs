using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>Creates immutable, bounded worklists and derives counters from durable item results.</summary>
public sealed class MetadataJobStore(
    AureliaDbContext database,
    MetadataJobScheduler scheduler,
    ServerConfigurationStore configuration,
    TimeProvider clock)
{
    private const int BatchSize = 256;
    private static readonly SemaphoreSlim CreationGate = new(1, 1);

    public async Task<MetadataJobSummary> StartAsync(StartMetadataJobRequest request, CancellationToken token, Guid? retryOf = null)
    {
        await CreationGate.WaitAsync(token);
        try { return await CreateAsync(request, token, retryOf); }
        finally { CreationGate.Release(); }
    }

    private async Task<MetadataJobSummary> CreateAsync(StartMetadataJobRequest request, CancellationToken token, Guid? retryOf = null)
    {
        if (database.AccessUserId != null && !database.AccessIsOwner && database.AccessMode == ProfileAccessMode.SelectedTitles && !request.MediaId.HasValue)
            throw new MetadataException("full_library_access_required", "Select one shared title. Library-wide jobs require full library access.", 403);
        if (database.AccessUserId != null && !database.AccessIsOwner && request.LibraryId == null && request.MediaId == null)
            throw new MetadataException("owner_required", "Select one of your shared libraries. Only an owner may refresh the entire server.", 403);
        if (request.LibraryId.HasValue && !await database.LibraryRoots.AnyAsync(root => root.Id == request.LibraryId, token))
            throw new MetadataException("library_not_found", "The storage location was not found.", 404);
        if (request.MediaId.HasValue && !await database.MediaItems.AnyAsync(item => item.Id == request.MediaId, token))
            throw new MetadataException("media_not_found", "The media item was not found.", 404);
        if (request.Mode == MetadataJobMode.SingleItem && !request.MediaId.HasValue)
            throw new MetadataException("metadata_item_required", "Single-item metadata refresh requires a media ID.", 400);

        var requester = database.AccessUserId ?? await database.Users.Where(user => user.IsEnabled && user.Role == UserRole.Owner)
            .OrderBy(user => user.CreatedAt).Select(user => (Guid?)user.Id).FirstOrDefaultAsync(token);
        await using var transaction = await database.Database.BeginTransactionAsync(token);
        var duplicate = await database.MetadataJobs.AsNoTracking().FirstOrDefaultAsync(job =>
            (job.State == MetadataJobState.Queued || job.State == MetadataJobState.Running)
            && job.LibraryRootId == request.LibraryId && job.MediaItemId == request.MediaId && job.Mode == request.Mode
            && job.RequestedByUserId == requester, token);
        if (duplicate is not null) return MetadataService.ToSummary(duplicate);
        if (await database.MetadataJobs.IgnoreQueryFilters().CountAsync(job => job.State == MetadataJobState.Queued || job.State == MetadataJobState.Running, token)
            >= configuration.Current.JobQueueLimit)
            throw new MetadataException("job_queue_full", "The metadata queue is full. Wait for existing jobs to finish.", 409);

        var cooldown = await database.MetadataProviderCooldowns.AsNoTracking().SingleOrDefaultAsync(value => value.Provider == "tmdb", token);
        var job = new MetadataJob
        {
            Id = Guid.NewGuid(),
            RequestedByUserId = requester,
            WorklistInitialized = true,
            LibraryRootId = request.LibraryId,
            MediaItemId = request.MediaId,
            Mode = request.Mode,
            State = MetadataJobState.Queued,
            CreatedAt = clock.GetUtcNow(),
            NextAttemptAt = cooldown?.NotBefore > clock.GetUtcNow() ? cooldown.NotBefore : null,
            WaitReason = cooldown?.NotBefore > clock.GetUtcNow() ? cooldown.WaitReason : null,
        };
        database.MetadataJobs.Add(job);
        await database.SaveChangesAsync(token);
        var query = database.MediaItems.AsNoTracking().Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series);
        if (request.LibraryId.HasValue) query = query.Where(item => item.LibraryRootId == request.LibraryId);
        if (request.MediaId.HasValue) query = query.Where(item => item.Id == request.MediaId);
        if (retryOf.HasValue)
            query = query.Where(item => database.MetadataJobItems.Any(work => work.JobId == retryOf && work.MediaItemId == item.Id
                && (work.State == MetadataWorkState.Pending || work.State == MetadataWorkState.Processing || work.State == MetadataWorkState.Failed)));
        else
            query = request.Mode switch
            {
                MetadataJobMode.Incremental => query.Where(item => item.Metadata == null || item.Metadata.ProviderMediaId == null || item.Metadata.ReviewState == MetadataReviewState.NeedsReview),
                MetadataJobMode.RetryFailed => query.Where(item => item.MetadataReviews.Any(review => review.State == MetadataReviewState.NeedsReview)),
                _ => query,
            };
        while (true)
        {
            var ids = await query.OrderBy(item => item.Id).Skip(job.ItemsTotal).Take(BatchSize).Select(item => item.Id).ToListAsync(token);
            if (ids.Count == 0) break;
            foreach (var id in ids)
                database.MetadataJobItems.Add(new MetadataJobItem { JobId = job.Id, MediaItemId = id, Ordinal = job.ItemsTotal++, State = MetadataWorkState.Pending });
            await database.SaveChangesAsync(token);
            foreach (var entry in database.ChangeTracker.Entries<MetadataJobItem>().ToArray()) entry.State = EntityState.Detached;
        }
        if (job.ItemsTotal == 0)
        {
            job.State = MetadataJobState.Completed;
            job.CompletedAt = clock.GetUtcNow();
            job.NextAttemptAt = null;
            job.WaitReason = null;
            await database.SaveChangesAsync(token);
        }
        await transaction.CommitAsync(token);
        scheduler.Pulse();
        return MetadataService.ToSummary(job);
    }

    public async Task<MetadataJobSummary> RetryAsync(Guid id, CancellationToken token)
    {
        var job = await database.MetadataJobs.AsNoTracking().SingleOrDefaultAsync(value => value.Id == id, token)
            ?? throw new MetadataException("metadata_job_not_found", "The metadata job was not found.", 404);
        if (job.State is not MetadataJobState.Failed and not MetadataJobState.Interrupted and not MetadataJobState.Cancelled)
            throw new MetadataException("job_not_retryable", "Only a failed, interrupted or cancelled job can be retried.", 409);
        return await StartAsync(new StartMetadataJobRequest(job.Mode, job.LibraryRootId, job.MediaItemId), token, job.WorklistInitialized ? job.Id : null);
    }

    internal static async Task RecountAsync(AureliaDbContext database, MetadataJob job, CancellationToken token)
    {
        var counts = await database.MetadataJobItems.Where(item => item.JobId == job.Id)
            .GroupBy(item => item.State).Select(group => new { State = group.Key, Count = group.Count() }).ToListAsync(token);
        int Count(MetadataWorkState state) => counts.FirstOrDefault(value => value.State == state)?.Count ?? 0;
        job.ItemsMatched = Count(MetadataWorkState.Matched);
        job.ItemsNeedingReview = Count(MetadataWorkState.NeedsReview);
        job.ItemsSkipped = Count(MetadataWorkState.Skipped);
        job.ItemsFailed = Count(MetadataWorkState.Failed);
        job.ItemsProcessed = job.ItemsMatched + job.ItemsNeedingReview + job.ItemsSkipped + job.ItemsFailed;
    }

    internal static async Task<bool> RefreshAccessAsync(AureliaDbContext database, MetadataJob job, CancellationToken token)
    {
        var user = await database.Users.AsNoTracking().SingleOrDefaultAsync(value => value.Id == job.RequestedByUserId, token);
        if (user is null || !user.IsEnabled || user.Role is not UserRole.Owner and not UserRole.Admin) return false;
        database.AccessUserId = user.Id;
        database.AccessIsOwner = user.Role == UserRole.Owner;
        database.AccessMode = user.AccessMode;
        return true;
    }
}
