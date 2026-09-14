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

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await foreach (var jobId in scheduler.ReadAllAsync(stoppingToken))
        {
            try { await ProcessAsync(jobId, stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                await FinishAsync(jobId, MetadataJobState.Interrupted, "The server stopped before metadata enrichment completed.");
            }
            catch (Exception exception)
            {
                LogJobFailed(logger, jobId, exception.GetType().Name);
                await FinishAsync(jobId, MetadataJobState.Failed, "Metadata enrichment failed.");
            }
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

        job.State = MetadataJobState.Running;
        job.StartedAt = DateTimeOffset.UtcNow;
        var query = database.MediaItems
            .Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Credits)
            .Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
            .Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series);
        if (job.LibraryRootId.HasValue) query = query.Where(item => item.LibraryRootId == job.LibraryRootId);
        if (job.MediaItemId.HasValue) query = query.Where(item => item.Id == job.MediaItemId);
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
                if (MetadataMatcher.IsUnambiguous(candidates))
                {
                    var match = candidates[0];
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
            }
            job.ItemsProcessed++;
            await database.SaveChangesAsync(cancellationToken);
        }

        job.State = MetadataJobState.Completed;
        job.CompletedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
        await PruneJobsAsync(database, job.Id, cancellationToken);
    }

    private static async Task StoreReviewAsync(AureliaDbContext database, MediaItem item, IReadOnlyList<MetadataCandidateSummary> candidates, CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow;
        var review = await database.MetadataReviews.SingleOrDefaultAsync(value => value.MediaItemId == item.Id, cancellationToken);
        if (review is null)
        {
            review = new MetadataReview { Id = Guid.NewGuid(), MediaItemId = item.Id, CreatedAt = now };
            database.MetadataReviews.Add(review);
        }
        review.Reason = candidates.Count == 0 ? "No confident TMDB result was found." : "Multiple or uncertain TMDB results need confirmation.";
        review.CandidatesJson = JsonSerializer.Serialize(candidates.Take(8), JsonOptions);
        review.State = MetadataReviewState.NeedsReview;
        review.UpdatedAt = now;
    }

    private async Task FinishAsync(Guid id, MetadataJobState state, string error)
    {
        try
        {
            await using var scope = scopeFactory.CreateAsyncScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var job = await database.MetadataJobs.SingleOrDefaultAsync(value => value.Id == id);
            if (job is null) return;
            job.State = state; job.Error = error; job.CompletedAt = DateTimeOffset.UtcNow;
            await database.SaveChangesAsync();
        }
        catch (Exception exception) { LogStateFailed(logger, id, exception.GetType().Name); }
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
    [LoggerMessage(LogLevel.Error, "Metadata job {JobId} state update failed with {ErrorType}.")]
    private static partial void LogStateFailed(ILogger logger, Guid jobId, string errorType);
}
