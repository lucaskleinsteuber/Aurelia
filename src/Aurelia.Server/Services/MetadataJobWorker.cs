using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed partial class MetadataJobWorker(
    MetadataJobScheduler scheduler,
    IServiceScopeFactory scopeFactory,
    ILogger<MetadataJobWorker> logger,
    TimeProvider clock) : BackgroundService
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private static readonly TimeSpan LeaseDuration = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan IdleFallback = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan[] RetryDelays = [TimeSpan.FromSeconds(30), TimeSpan.FromMinutes(2), TimeSpan.FromMinutes(10)];

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
                // New jobs pulse the scheduler; otherwise sleep until the next delayed attempt.
                wait.CancelAfter(await recovery.RunAsync(() => IdleDelayAsync(stoppingToken), stoppingToken));
                try { await scheduler.WaitAsync(wait.Token); }
                catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested) { }
                continue;
            }
            var jobToken = scheduler.Register(jobId.Value, stoppingToken);
            using var heartbeat = CancellationTokenSource.CreateLinkedTokenSource(jobToken);
            var heartbeatTask = HeartbeatAsync(jobId.Value, heartbeat.Token);
            try
            {
                await ProcessAsync(jobId.Value, jobToken);
            }
            catch (OperationCanceledException) when (jobToken.IsCancellationRequested)
            {
                if (stoppingToken.IsCancellationRequested)
                {
                    try { await ReleaseAsync(jobId.Value, serverStopping: true); }
                    catch (Exception exception) when (StorageRecovery.IsRecoverable(exception))
                    { /* The durable processing marker is recovered on the next host start. */ }
                }
                else await recovery.RunAsync(() => ReleaseAsync(jobId.Value), stoppingToken);
            }
            catch (Exception exception) when (StorageRecovery.IsRecoverable(exception))
            {
                await recovery.RunAsync(() => ReleaseAsync(jobId.Value, storageFailure: true), stoppingToken);
            }
            catch (Exception exception) when (!StorageRecovery.IsCorruptDatabase(exception))
            {
                LogJobFailed(logger, jobId.Value, exception.GetType().Name,
                    string.Join(" <- ", new System.Diagnostics.StackTrace(exception, false).GetFrames().Take(12)
                        .Select(frame => frame.GetMethod()?.DeclaringType?.Name + "." + frame.GetMethod()?.Name)));
                await recovery.RunAsync(() => ReleaseAsync(jobId.Value, failure: "Metadata enrichment failed. Retry to resume unfinished titles."), stoppingToken);
            }
            finally
            {
                await heartbeat.CancelAsync();
                await heartbeatTask;
                scheduler.Unregister(jobId.Value);
            }
        }
    }

    private async Task RecoverAsync(CancellationToken token)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var jobs = await database.MetadataJobs.IgnoreQueryFilters().Where(job => job.State == MetadataJobState.Running).ToListAsync(token);
        foreach (var job in jobs)
        {
            job.State = job.WorklistInitialized ? MetadataJobState.Queued : MetadataJobState.Interrupted;
            job.CompletedAt = job.WorklistInitialized ? null : clock.GetUtcNow();
            job.Error = job.WorklistInitialized ? null : "The legacy metadata job was interrupted. Retry to create a worklist.";
            job.LeaseExpiresAt = job.HeartbeatAt = null;
            await ResetProcessingAsync(database, job.Id, token);
        }
        await database.SaveChangesAsync(token);
        scheduler.Pulse();
    }

    private async Task<TimeSpan> IdleDelayAsync(CancellationToken token)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var next = await database.MetadataJobs.IgnoreQueryFilters()
            .Where(job => job.State == MetadataJobState.Queued && job.NextAttemptAt != null)
            .OrderBy(job => job.NextAttemptAt).Select(job => job.NextAttemptAt).FirstOrDefaultAsync(token);
        var cooldown = await database.MetadataProviderCooldowns.AsNoTracking()
            .Where(value => value.Provider == "tmdb").Select(value => value.NotBefore).SingleOrDefaultAsync(token);
        var now = clock.GetUtcNow();
        var due = new[] { next, cooldown }.Where(value => value > now).Min();
        if (due is null) return IdleFallback;
        var delay = due.Value - now + TimeSpan.FromMilliseconds(50);
        return delay < IdleFallback ? delay : IdleFallback;
    }

    private async Task<Guid?> ClaimNextAsync(CancellationToken token)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = clock.GetUtcNow();
        var cooldown = await database.MetadataProviderCooldowns.AsNoTracking().SingleOrDefaultAsync(value => value.Provider == "tmdb", token);
        if (cooldown?.NotBefore > now)
        {
            await database.MetadataJobs.IgnoreQueryFilters().Where(job => job.State == MetadataJobState.Queued
                && (job.NextAttemptAt == null || job.NextAttemptAt < cooldown.NotBefore))
                .ExecuteUpdateAsync(set => set.SetProperty(job => job.NextAttemptAt, cooldown.NotBefore)
                    .SetProperty(job => job.WaitReason, cooldown.WaitReason), token);
            return null;
        }
        while (true)
        {
            var job = await database.MetadataJobs.IgnoreQueryFilters()
                .Where(candidate => candidate.State == MetadataJobState.Queued && (candidate.NextAttemptAt == null || candidate.NextAttemptAt <= now))
                .OrderBy(candidate => candidate.CreatedAt).ThenBy(candidate => candidate.Id).FirstOrDefaultAsync(token);
            if (job is null) return null;
            if (job.CancelRequestedAt.HasValue || !job.WorklistInitialized)
            {
                job.State = job.CancelRequestedAt.HasValue ? MetadataJobState.Cancelled : MetadataJobState.Interrupted;
                job.CompletedAt = now;
                await database.SaveChangesAsync(token);
                continue;
            }
            job.State = MetadataJobState.Running;
            job.Attempt++;
            job.StartedAt ??= now;
            job.HeartbeatAt = now;
            job.LeaseExpiresAt = now.Add(LeaseDuration);
            job.NextAttemptAt = null;
            job.WaitReason = job.Error = null;
            await database.SaveChangesAsync(token);
            return job.Id;
        }
    }

    private async Task ProcessAsync(Guid jobId, CancellationToken token)
    {
        while (true)
        {
            token.ThrowIfCancellationRequested();
            await using var scope = scopeFactory.CreateAsyncScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var ids = await database.MetadataJobItems.AsNoTracking().Where(item => item.JobId == jobId && item.State == MetadataWorkState.Pending)
                .OrderBy(item => item.Ordinal).Take(32).Select(item => item.MediaItemId).ToListAsync(token);
            if (ids.Count == 0)
            {
                var job = await database.MetadataJobs.IgnoreQueryFilters().SingleAsync(value => value.Id == jobId, token);
                await MetadataJobStore.RecountAsync(database, job, token);
                job.State = job.ItemsFailed == 0 ? MetadataJobState.Completed : MetadataJobState.Failed;
                job.CompletedAt = clock.GetUtcNow();
                job.LeaseExpiresAt = job.HeartbeatAt = null;
                await database.SaveChangesAsync(token);
                return;
            }
            foreach (var id in ids)
                if (!await ProcessItemAsync(jobId, id, token)) return;
        }
    }

    private async Task<bool> ProcessItemAsync(Guid jobId, Guid mediaId, CancellationToken token)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var service = scope.ServiceProvider.GetRequiredService<MetadataService>();
        var settings = scope.ServiceProvider.GetRequiredService<MetadataProviderSettingsStore>().Load();
        var tmdb = scope.ServiceProvider.GetRequiredService<ITmdbClient>();
        var job = await database.MetadataJobs.IgnoreQueryFilters().SingleAsync(value => value.Id == jobId, token);
        var work = await database.MetadataJobItems.SingleAsync(value => value.JobId == jobId && value.MediaItemId == mediaId, token);
        if (job.CancelRequestedAt.HasValue) { scheduler.RequestCancellation(jobId); throw new OperationCanceledException(token); }
        if (!settings.Enabled || settings.Token is null)
        {
            await FailAsync("TMDB is not enabled.");
            return false;
        }
        if (!await MetadataJobStore.RefreshAccessAsync(database, job, token))
        {
            await FailAsync("The requesting profile no longer has metadata management access.");
            return false;
        }
        var item = await database.MediaItems.Include(value => value.Metadata)!.ThenInclude(value => value!.Credits)
            .Include(value => value.Metadata)!.ThenInclude(value => value!.Artwork)
            .SingleOrDefaultAsync(value => value.Id == mediaId && (value.Kind == MediaKind.Movie || value.Kind == MediaKind.Series), token);
        if (item is null)
        {
            await CompleteAsync(MetadataWorkState.Skipped);
            return true;
        }
        var initialRevision = item.Metadata?.EditorRevision ?? 0;
        var applying = false;
        work.State = MetadataWorkState.Processing;
        work.Attempt++;
        await database.SaveChangesAsync(token);
        try
        {
            // Looking for missing info on a series that is already matched only fills in its
            // episodes from the known match; it never searches again or replaces that match.
            if (job.Mode == MetadataJobMode.Incremental && item.Kind == MediaKind.Series
                && item.Metadata is { ProviderMediaId: { } known, ReviewState: MetadataReviewState.Matched })
            {
                var existing = await tmdb.GetAsync(settings.Token, settings.Language, item.Metadata.ProviderMediaType ?? "tv", known, token);
                if (!await CanApplyAsync(token)) { await CompleteAsync(MetadataWorkState.Skipped); return true; }
                applying = true;
                await service.ApplyEpisodesAsync(item, existing, settings, token, CanApplyAsync);
                await CompleteAsync(await CanApplyAsync(token) ? MetadataWorkState.Matched : MetadataWorkState.Skipped);
                return true;
            }
            var title = item.Metadata?.ManualTitle ?? item.OverrideTitle ?? item.DetectedTitle;
            var candidates = await tmdb.SearchAsync(settings.Token, settings.Language, item.Kind, title, item.Year, token);
            // TMDB filters strictly by year, and some titles are only found by their main part. Each
            // further search runs only when the previous one found nothing; the year still counts
            // when the results are scored.
            if (candidates.Count == 0 && item.Year is not null)
            {
                candidates = Rescore(await tmdb.SearchAsync(settings.Token, settings.Language, item.Kind, title, null, token), title, item.Year);
            }
            foreach (var fallback in MetadataMatcher.FallbackQueries(title))
            {
                if (candidates.Count > 0) break;
                candidates = Rescore(await tmdb.SearchAsync(settings.Token, settings.Language, item.Kind, fallback, null, token), fallback, item.Year);
                if (candidates.Count > 0) title = fallback;
            }
            if (!await CanApplyAsync(token))
            {
                await CompleteAsync(MetadataWorkState.Skipped);
                return true;
            }
            var match = MetadataMatcher.SelectAutomaticMatch(candidates, title, item.Year)
                ?? await SelectBySignalsAsync(database, tmdb, settings.Token, item, candidates, title, token);
            if (match is not null)
            {
                var details = await tmdb.GetAsync(settings.Token, settings.Language, match.MediaType, match.ProviderMediaId, token);
                if (!await CanApplyAsync(token)) { await CompleteAsync(MetadataWorkState.Skipped); return true; }
                applying = true;
                await service.ApplyAsync(item, details, match.Confidence, token, CanApplyAsync);
                await service.ApplyEpisodesAsync(item, details, settings, token, CanApplyAsync);
                await CompleteAsync(await CanApplyAsync(token) ? MetadataWorkState.Matched : MetadataWorkState.Skipped);
            }
            else
            {
                using var lease = await scope.ServiceProvider.GetRequiredService<CatalogMutationGate>().EnterAsync(token);
                if (!await CanApplyAsync(token)) { await CompleteAsync(MetadataWorkState.Skipped); return true; }
                await StoreReviewAsync(database, item, candidates, token);
                await CompleteAsync(MetadataWorkState.NeedsReview);
            }
            return true;
        }
        catch (MetadataProviderException error) when (error.Transient)
        {
            await WaitOrFailAsync(error.Message, error.RetryAfter);
            return false;
        }
        catch (HttpRequestException)
        {
            await WaitOrFailAsync("TMDB could not be reached.", null);
            return false;
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            await WaitOrFailAsync("TMDB did not respond in time.", null);
            return false;
        }
        catch (JsonException)
        {
            await WaitOrFailAsync("TMDB returned an incomplete response.", null);
            return false;
        }
        catch (MetadataException error)
        {
            // Provider/transport failures are not evidence that a title needs manual matching.
            job.Error = error.Message;
            await CompleteAsync(MetadataWorkState.Failed);
            if (error.Code == "metadata_authentication_failed") { await FailAsync(error.Message); return false; }
            return true;
        }

        async Task<bool> CanApplyAsync(CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested();
            var cancelled = await database.MetadataJobs.IgnoreQueryFilters().AsNoTracking()
                .AnyAsync(value => value.Id == job.Id && value.CancelRequestedAt != null, cancellation);
            if (cancelled) { scheduler.RequestCancellation(jobId); throw new OperationCanceledException(token); }
            return await MetadataJobStore.RefreshAccessAsync(database, job, cancellation)
                && await database.MediaItems.AsNoTracking().AnyAsync(value => value.Id == mediaId, cancellation)
                && (applying || !await database.MediaMetadata.AsNoTracking().AnyAsync(value => value.MediaItemId == mediaId && value.EditorRevision != initialRevision, cancellation));
        }
        async Task CompleteAsync(MetadataWorkState state)
        {
            if (state == MetadataWorkState.Skipped)
                foreach (var entry in database.ChangeTracker.Entries().Where(entry => entry.Entity is
                    MediaItem or MediaMetadata or MediaCredit or ArtworkAsset or MetadataReview
                    or MediaCollectionRecord or MediaCollectionMember).ToArray()) entry.State = EntityState.Detached;
            work.State = state;
            work.CompletedAt = clock.GetUtcNow();
            await using var transaction = await database.Database.BeginTransactionAsync(token);
            await database.SaveChangesAsync(token);
            await MetadataJobStore.RecountAsync(database, job, token);
            await database.SaveChangesAsync(token);
            await transaction.CommitAsync(token);
        }
        async Task FailAsync(string error)
        {
            job.State = MetadataJobState.Failed;
            job.Error = error;
            job.CompletedAt = clock.GetUtcNow();
            job.LeaseExpiresAt = job.HeartbeatAt = null;
            job.NextAttemptAt = null;
            job.WaitReason = null;
            await database.SaveChangesAsync(token);
        }
        async Task WaitOrFailAsync(string error, TimeSpan? retryAfter)
        {
            if (work.Attempt >= 4)
            {
                await CompleteAsync(MetadataWorkState.Failed);
                await FailAsync(error);
                return;
            }
            var delay = RetryDelays[work.Attempt - 1];
            if (retryAfter > delay) delay = retryAfter.Value;
            var next = clock.GetUtcNow().Add(delay);
            work.State = MetadataWorkState.Pending;
            job.State = MetadataJobState.Queued;
            job.NextAttemptAt = next;
            job.WaitReason = "tmdb";
            job.Error = null;
            job.LeaseExpiresAt = job.HeartbeatAt = null;
            var cooldown = await database.MetadataProviderCooldowns.SingleOrDefaultAsync(value => value.Provider == "tmdb", token);
            if (cooldown is null) { cooldown = new MetadataProviderCooldown(); database.MetadataProviderCooldowns.Add(cooldown); }
            if (cooldown.NotBefore is null || cooldown.NotBefore < next) cooldown.NotBefore = next;
            cooldown.WaitReason = "tmdb";
            await database.SaveChangesAsync(token);
        }
    }

    private async Task ReleaseAsync(Guid id, bool serverStopping = false, bool storageFailure = false, string? failure = null)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var job = await database.MetadataJobs.IgnoreQueryFilters().SingleOrDefaultAsync(value => value.Id == id);
        if (job is null || job.State is MetadataJobState.Completed or MetadataJobState.Cancelled or MetadataJobState.Failed) return;
        if (failure is null) await ResetProcessingAsync(database, id, CancellationToken.None);
        else
        {
            var now = clock.GetUtcNow();
            await database.MetadataJobItems.Where(item => item.JobId == id && item.State == MetadataWorkState.Processing)
                .ExecuteUpdateAsync(set => set.SetProperty(item => item.State, MetadataWorkState.Failed)
                    .SetProperty(item => item.CompletedAt, now));
            await MetadataJobStore.RecountAsync(database, job, CancellationToken.None);
        }
        job.State = failure is not null ? MetadataJobState.Failed
            : job.CancelRequestedAt.HasValue || !serverStopping && !storageFailure ? MetadataJobState.Cancelled : MetadataJobState.Queued;
        job.CompletedAt = job.State == MetadataJobState.Queued ? null : clock.GetUtcNow();
        job.Error = failure;
        job.LeaseExpiresAt = job.HeartbeatAt = null;
        job.NextAttemptAt = storageFailure ? clock.GetUtcNow().AddSeconds(5) : null;
        job.WaitReason = storageFailure ? "storage" : null;
        await database.SaveChangesAsync();
        scheduler.Pulse();
    }

    private static async Task ResetProcessingAsync(AureliaDbContext database, Guid id, CancellationToken token)
    {
        await database.MetadataJobItems.Where(item => item.JobId == id && item.State == MetadataWorkState.Processing)
            .ExecuteUpdateAsync(set => set.SetProperty(item => item.State, MetadataWorkState.Pending)
                .SetProperty(item => item.Attempt, item => Math.Max(0, item.Attempt - 1)), token);
    }

    private async Task HeartbeatAsync(Guid id, CancellationToken token)
    {
        try
        {
            while (true)
            {
                await Task.Delay(TimeSpan.FromSeconds(10), token);
                await using var scope = scopeFactory.CreateAsyncScope();
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var now = clock.GetUtcNow();
                await database.MetadataJobs.IgnoreQueryFilters().Where(job => job.Id == id && job.State == MetadataJobState.Running)
                    .ExecuteUpdateAsync(set => set.SetProperty(job => job.HeartbeatAt, now).SetProperty(job => job.LeaseExpiresAt, now.Add(LeaseDuration)), token);
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) when (StorageRecovery.IsRecoverable(error)) { }
    }

    private static List<MetadataCandidateSummary> Rescore(IReadOnlyList<MetadataCandidateSummary> candidates, string title, int? year) =>
        candidates.Select(candidate => candidate with
        {
            Confidence = MetadataMatcher.Score(title, year, candidate.Title, candidate.OriginalTitle, candidate.Year),
        }).OrderByDescending(candidate => candidate.Confidence).ToList();

    /// <summary>
    /// Several titles with the same name: compares a series' seasons and episodes here with what TMDB
    /// lists (at most four lookups), then how well known each title is.
    /// </summary>
    private static async Task<MetadataCandidateSummary?> SelectBySignalsAsync(
        AureliaDbContext database, ITmdbClient tmdb, string providerToken, MediaItem item,
        IReadOnlyList<MetadataCandidateSummary> candidates, string title, CancellationToken token)
    {
        MetadataMatcher.LocalShape? local = null;
        Dictionary<string, TmdbShowShape>? shapes = null;
        var normalized = FilenameMetadataParser.NormalizeMatchTitle(title);
        var sameName = candidates.Where(candidate => candidate.MediaType == "tv"
            && (FilenameMetadataParser.NormalizeMatchTitle(candidate.Title) == normalized
                || FilenameMetadataParser.NormalizeMatchTitle(candidate.OriginalTitle ?? "") == normalized)).Take(4).ToList();
        if (item.Kind == MediaKind.Series && item.Year is null && sameName.Count > 1)
        {
            var episodes = await database.MediaItems.AsNoTracking()
                .Where(value => value.ParentId == item.Id && value.Kind == MediaKind.Episode)
                .Select(value => value.SeasonNumber).ToListAsync(token);
            local = new MetadataMatcher.LocalShape(episodes.Max(), episodes.Count);
            shapes = [];
            foreach (var candidate in sameName)
            {
                shapes[candidate.ProviderMediaId] = await tmdb.GetShowShapeAsync(providerToken, candidate.ProviderMediaId, token);
            }
        }

        return MetadataMatcher.SelectBySignals(candidates, title, item.Year, local, shapes);
    }

    private static async Task StoreReviewAsync(AureliaDbContext database, MediaItem item, IReadOnlyList<MetadataCandidateSummary> candidates, CancellationToken token)
    {
        var now = DateTimeOffset.UtcNow;
        var review = await database.MetadataReviews.SingleOrDefaultAsync(value => value.MediaItemId == item.Id, token);
        if (review is null)
        {
            review = new MetadataReview { Id = Guid.NewGuid(), MediaItemId = item.Id, CreatedAt = now };
            database.MetadataReviews.Add(review);
        }
        review.Reason = MetadataMatcher.ReviewReason(item.OverrideTitle ?? item.DetectedTitle, item.Year, candidates);
        review.CandidatesJson = JsonSerializer.Serialize(candidates.Take(8), JsonOptions);
        review.State = MetadataReviewState.NeedsReview;
        review.UpdatedAt = now;
    }

    [LoggerMessage(LogLevel.Error, "Metadata job {JobId} failed with {ErrorType} at {FailureLocation}.")]
    private static partial void LogJobFailed(ILogger logger, Guid jobId, string errorType, string failureLocation);
}
