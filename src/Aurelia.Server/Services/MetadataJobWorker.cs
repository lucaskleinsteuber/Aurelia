using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed partial class MetadataJobWorker(
    MetadataJobScheduler scheduler,
    IServiceScopeFactory scopeFactory,
    ILogger<MetadataJobWorker> logger) : BackgroundService
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private static readonly TimeSpan LeaseDuration = TimeSpan.FromSeconds(30);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var recovery = new StorageRecovery(logger, "metadata worker");
        await recovery.RunAsync(() => RecoverAsync(stoppingToken), stoppingToken);
        while (!stoppingToken.IsCancellationRequested)
        {
            var jobId = await recovery.RunAsync(() => ClaimNextAsync(stoppingToken), stoppingToken);
            if (!jobId.HasValue)
            {
                using var wait = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                wait.CancelAfter(TimeSpan.FromSeconds(1));
                try
                {
                    await scheduler.WaitAsync(wait.Token);
                }
                catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
                {
                    // SQLite is authoritative, so periodically check even if a wake signal was lost.
                }

                continue;
            }

            var jobToken = scheduler.Register(jobId.Value, stoppingToken);
            try
            {
                await ProcessAsync(jobId.Value, jobToken);
            }
            catch (OperationCanceledException)
            {
                await recovery.RunAsync(() => FinishCancellationAsync(jobId.Value, stoppingToken.IsCancellationRequested), stoppingToken);
            }
            catch (Exception exception) when (StorageRecovery.IsRecoverableDatabase(exception))
            {
                await recovery.RunAsync(() => RetryOrFailAsync(jobId.Value, "The metadata job is waiting for writable storage.", storageFailure: true), stoppingToken);
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
            catch (Exception exception) when (!StorageRecovery.IsCorruptDatabase(exception))
            {
                LogJobFailed(logger, jobId.Value, exception.GetType().Name);
                await recovery.RunAsync(() => RetryOrFailAsync(jobId.Value, "Metadata enrichment failed."), stoppingToken);
            }
            finally
            {
                scheduler.Unregister(jobId.Value);
            }
        }
    }

    private async Task RecoverAsync(CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var jobs = await database.MetadataJobs
            .Where(job => job.State == MetadataJobState.Running)
            .ToListAsync(cancellationToken);
        foreach (var job in jobs)
        {
            job.State = job.Attempt < 3 ? MetadataJobState.Queued : MetadataJobState.Interrupted;
            job.CompletedAt = job.Attempt < 3 ? null : DateTimeOffset.UtcNow;
            job.Error = job.Attempt < 3
                ? "The interrupted metadata job will resume automatically."
                : "The metadata job was interrupted too many times.";
            job.LeaseExpiresAt = null;
            job.HeartbeatAt = null;
        }

        await database.SaveChangesAsync(cancellationToken);
        scheduler.Pulse();
    }

    private async Task<Guid?> ClaimNextAsync(CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        while (true)
        {
            var job = await database.MetadataJobs
                .Where(candidate => candidate.State == MetadataJobState.Queued)
                .OrderBy(candidate => candidate.CreatedAt)
                .ThenBy(candidate => candidate.Id)
                .FirstOrDefaultAsync(cancellationToken);
            if (job is null)
            {
                return null;
            }

            if (job.CancelRequestedAt.HasValue)
            {
                job.State = MetadataJobState.Cancelled;
                job.CompletedAt = DateTimeOffset.UtcNow;
                await database.SaveChangesAsync(cancellationToken);
                continue;
            }

            var now = DateTimeOffset.UtcNow;
            job.State = MetadataJobState.Running;
            job.Attempt += 1;
            job.StartedAt ??= now;
            job.HeartbeatAt = now;
            job.LeaseExpiresAt = now.Add(LeaseDuration);
            job.Error = null;
            await database.SaveChangesAsync(cancellationToken);
            return job.Id;
        }
    }

    private async Task ProcessAsync(Guid jobId, CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var service = scope.ServiceProvider.GetRequiredService<MetadataService>();
        var settings = scope.ServiceProvider.GetRequiredService<MetadataProviderSettingsStore>().Load();
        var tmdb = scope.ServiceProvider.GetRequiredService<ITmdbClient>();
        var job = await database.MetadataJobs.SingleAsync(value => value.Id == jobId, cancellationToken);
        if (!settings.Enabled || settings.Token is null)
        {
            job.State = MetadataJobState.Failed;
            job.Error = "TMDB is not enabled.";
            job.CompletedAt = DateTimeOffset.UtcNow;
            await database.SaveChangesAsync(cancellationToken);
            return;
        }

        var query = database.MediaItems
            .Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Credits)
            .Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
            .Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series);
        if (job.LibraryRootId.HasValue) query = query.Where(item => item.LibraryRootId == job.LibraryRootId);
        if (job.MediaItemId.HasValue) query = query.Where(item => item.Id == job.MediaItemId);
        query = job.Mode switch
        {
            MetadataJobMode.Incremental => query.Where(item =>
                item.Metadata == null
                || item.Metadata.ProviderMediaId == null
                || item.Metadata.ReviewState == MetadataReviewState.NeedsReview),
            MetadataJobMode.RetryFailed => query.Where(item =>
                item.MetadataReviews.Any(review => review.State == MetadataReviewState.NeedsReview)),
            MetadataJobMode.SingleItem => query.Where(item => job.MediaItemId.HasValue
                && item.Id == job.MediaItemId.Value),
            _ => query,
        };
        var items = await query.OrderBy(item => item.DetectedTitle).ToListAsync(cancellationToken);
        job.ItemsTotal = items.Count;
        await database.SaveChangesAsync(cancellationToken);

        foreach (var item in items)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var title = item.OverrideTitle ?? item.DetectedTitle;
                var candidates = await tmdb.SearchAsync(settings.Token, settings.Language, item.Kind, title, item.Year, cancellationToken);
                var match = MetadataMatcher.SelectAutomaticMatch(candidates, title, item.Year);
                if (match is not null)
                {
                    var details = await tmdb.GetAsync(settings.Token, settings.Language, match.MediaType, match.ProviderMediaId, cancellationToken);
                    await service.ApplyAsync(item, details, match.Confidence, cancellationToken);
                    await service.ApplyEpisodesAsync(item, details, settings, cancellationToken);
                    job.ItemsMatched++;
                }
                else
                {
                    await StoreReviewAsync(database, item, candidates, cancellationToken);
                    job.ItemsNeedingReview++;
                }
            }
            catch (MetadataException exception)
            {
                job.ItemsFailed++;
                job.Error = exception.Message;
                await StoreReviewAsync(
                    database,
                    item,
                    [],
                    $"Metadata refresh failed: {exception.Message}",
                    cancellationToken);
            }
            job.ItemsProcessed++;
            job.HeartbeatAt = DateTimeOffset.UtcNow;
            job.LeaseExpiresAt = job.HeartbeatAt.Value.Add(LeaseDuration);
            await database.SaveChangesAsync(cancellationToken);
        }

        job.State = MetadataJobState.Completed;
        job.CompletedAt = DateTimeOffset.UtcNow;
        job.LeaseExpiresAt = null;
        await database.SaveChangesAsync(cancellationToken);
        await PruneJobsAsync(database, job.Id, cancellationToken);
    }

    private static async Task StoreReviewAsync(AureliaDbContext database, MediaItem item, IReadOnlyList<MetadataCandidateSummary> candidates, CancellationToken cancellationToken)
        => await StoreReviewAsync(database, item, candidates, null, cancellationToken);

    private static async Task StoreReviewAsync(
        AureliaDbContext database,
        MediaItem item,
        IReadOnlyList<MetadataCandidateSummary> candidates,
        string? failureReason,
        CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow;
        var review = await database.MetadataReviews.SingleOrDefaultAsync(value => value.MediaItemId == item.Id, cancellationToken);
        if (review is null)
        {
            review = new MetadataReview { Id = Guid.NewGuid(), MediaItemId = item.Id, CreatedAt = now };
            database.MetadataReviews.Add(review);
        }
        review.Reason = failureReason
            ?? MetadataMatcher.ReviewReason(
                item.OverrideTitle ?? item.DetectedTitle,
                item.Year,
                candidates);
        review.CandidatesJson = JsonSerializer.Serialize(candidates.Take(8), JsonOptions);
        review.State = MetadataReviewState.NeedsReview;
        review.UpdatedAt = now;
    }

    private async Task RetryOrFailAsync(Guid id, string error, bool storageFailure = false)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var job = await database.MetadataJobs.SingleOrDefaultAsync(value => value.Id == id);
        if (job is null || job.State is MetadataJobState.Completed or MetadataJobState.Cancelled or MetadataJobState.Interrupted or MetadataJobState.Failed)
        {
            return;
        }

        if (storageFailure) job.Attempt = Math.Max(0, job.Attempt - 1);
        job.State = storageFailure || job.Attempt < 3 ? MetadataJobState.Queued : MetadataJobState.Failed;
        job.Error = error;
        job.CompletedAt = job.State == MetadataJobState.Failed ? DateTimeOffset.UtcNow : null;
        job.LeaseExpiresAt = null;
        job.HeartbeatAt = null;
        await database.SaveChangesAsync();
        if (job.State == MetadataJobState.Queued)
        {
            scheduler.Pulse();
        }
    }

    private async Task FinishCancellationAsync(Guid id, bool serverStopping)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var job = await database.MetadataJobs.SingleOrDefaultAsync(value => value.Id == id);
        if (job is null)
        {
            return;
        }

        if (job.State is MetadataJobState.Completed
            or MetadataJobState.Failed
            or MetadataJobState.Interrupted
            or MetadataJobState.Cancelled)
        {
            return;
        }

        job.State = serverStopping && !job.CancelRequestedAt.HasValue
            ? MetadataJobState.Queued
            : MetadataJobState.Cancelled;
        job.CompletedAt = job.State == MetadataJobState.Cancelled ? DateTimeOffset.UtcNow : null;
        job.Error = job.State == MetadataJobState.Cancelled ? "The metadata job was cancelled." : null;
        job.LeaseExpiresAt = null;
        job.HeartbeatAt = null;
        await database.SaveChangesAsync();
        if (job.State == MetadataJobState.Queued)
        {
            scheduler.Pulse();
        }
    }

    private static async Task PruneJobsAsync(AureliaDbContext database, Guid current, CancellationToken cancellationToken)
    {
        var old = await database.MetadataJobs.Where(job => job.Id != current && job.State != MetadataJobState.Running && job.State != MetadataJobState.Queued)
            .OrderByDescending(job => job.CreatedAt).Skip(24).ToListAsync(cancellationToken);
        database.MetadataJobs.RemoveRange(old);
        await database.SaveChangesAsync(cancellationToken);
    }

    [LoggerMessage(LogLevel.Error, "Metadata job {JobId} failed with {ErrorType}.")]
    private static partial void LogJobFailed(ILogger logger, Guid jobId, string errorType);
}
