using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class LibraryMutationService(AureliaDbContext database, CatalogMutationGate mutations,
    LibraryScanScheduler scans, MetadataJobScheduler jobs, ActiveStreamRegistry streams, ServerRuntimeOptions runtime, EditorArtworkStore images)
{
    public async Task<ResetLibraryPreview> PreviewAsync(IReadOnlyList<Guid> ids, CancellationToken token)
    {
        var selected = ids.Distinct().Order().ToArray();
        if (selected.Length is 0 or > 128 || await database.LibraryRoots.CountAsync(root => selected.Contains(root.Id), token) != selected.Length)
            throw new AccountException("invalid_library_selection", "Select storage locations shared with your account.", 404);
        var items = await database.MediaItems.Where(item => selected.Contains(item.LibraryRootId))
            .Select(item => new { item.Id, item.UpdatedAt, Revision = item.Metadata == null ? 0 : item.Metadata.EditorRevision }).OrderBy(item => item.Id).ToArrayAsync(token);
        var revision = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { selected, items }))));
        return new(selected, revision, items.Length,
            await database.MediaItems.CountAsync(item => selected.Contains(item.LibraryRootId) && item.Kind != MediaKind.Series, token),
            await database.ArtworkAssets.CountAsync(asset => selected.Contains(asset.Metadata.MediaItem.LibraryRootId), token), selected.Length);
    }

    public async Task<LibraryMutationResult> ResetAsync(Guid userId, ResetLibraryRequest request, CancellationToken token)
    {
        using var lease = await mutations.EnterAsync(token);
        var preview = await PreviewAsync(request.LibraryIds, token);
        if (!string.Equals(preview.Revision, request.Revision, StringComparison.Ordinal))
            throw new AccountException("reset_conflict", "The library changed since your confirmation. Review a fresh preview before resetting.", 409);
        var items = await database.MediaItems.Where(item => request.LibraryIds.Contains(item.LibraryRootId)).ToListAsync(token);
        await CancelJobsAsync(request.LibraryIds, token);
        var receipt = await DeleteAsync(userId, items, request.LibraryIds, exclude: false, token);
        foreach (var id in request.LibraryIds) scans.Release(id);
        return await CleanupAsync(receipt.Id, token);
    }

    public async Task<LibraryMutationResult> RemoveAsync(Guid userId, Guid id, CancellationToken token)
    {
        using var lease = await mutations.EnterAsync(token);
        var target = await database.MediaItems.Include(item => item.LibraryRoot).SingleOrDefaultAsync(item => item.Id == id, token)
            ?? throw new AccountException("media_not_found", "The title is unavailable or was already removed.", 404);
        var items = await database.MediaItems.Include(item => item.LibraryRoot).Where(item => item.LibraryRootId == target.LibraryRootId).ToListAsync(token);
        var selected = new HashSet<Guid> { id };
        while (true)
        {
            var added = items.Where(item => item.ParentId is { } parent && selected.Contains(parent)).Select(item => item.Id).ToArray();
            var previous = selected.Count; selected.UnionWith(added);
            if (selected.Count == previous) break;
        }
        await CancelJobsAsync([target.LibraryRootId], token);
        var receipt = await DeleteAsync(userId, items.Where(item => selected.Contains(item.Id)).ToList(), [], exclude: true, token);
        return await CleanupAsync(receipt.Id, token);
    }

    private async Task CancelJobsAsync(IReadOnlyList<Guid> rootIds, CancellationToken token)
    {
        var activeScans = await database.LibraryScans.Where(scan => rootIds.Contains(scan.LibraryRootId)
            && (scan.State == LibraryScanState.Queued || scan.State == LibraryScanState.Running || scan.State == LibraryScanState.WaitingForStorage)).ToListAsync(token);
        foreach (var scan in activeScans) { scans.RequestCancellation(scan.Id); scan.CancelRequestedAt = DateTimeOffset.UtcNow; scan.State = LibraryScanState.Cancelled; scan.CompletedAt = DateTimeOffset.UtcNow; }
        var activeJobs = await database.MetadataJobs.IgnoreQueryFilters().Where(job => (job.LibraryRootId == null && job.MediaItemId == null
                || job.LibraryRootId != null && rootIds.Contains(job.LibraryRootId.Value)
                || job.MediaItemId != null && database.MediaItems.Any(item => item.Id == job.MediaItemId && rootIds.Contains(item.LibraryRootId)))
            && (job.State == MetadataJobState.Queued || job.State == MetadataJobState.Running)).ToListAsync(token);
        foreach (var job in activeJobs) { jobs.RequestCancellation(job.Id); job.CancelRequestedAt = DateTimeOffset.UtcNow; job.State = MetadataJobState.Cancelled; job.CompletedAt = DateTimeOffset.UtcNow; }
        await database.SaveChangesAsync(token);
    }

    private async Task<LibraryMutation> DeleteAsync(Guid userId, List<MediaItem> items, IReadOnlyList<Guid> roots, bool exclude, CancellationToken token)
    {
        var ids = items.Select(item => item.Id).ToArray();
        streams.RevokeMedia(ids);
        var assets = await database.ArtworkAssets.Where(asset => ids.Contains(asset.MediaItemId))
            .Select(asset => new { asset.RelativeFilePath, asset.OriginalFilePath }).ToArrayAsync(token);
        var files = assets.SelectMany(asset => new[] { asset.RelativeFilePath, asset.OriginalFilePath }).OfType<string>()
            .Concat(await images.MediaDraftFilesAsync(ids, token)).Distinct().ToArray();
        var receipt = new LibraryMutation { Id = Guid.NewGuid(), UserId = userId, RemovedItems = ids.Length, FilesJson = JsonSerializer.Serialize(files) };
        await using var transaction = await database.Database.BeginTransactionAsync(token);
        await database.MetadataJobs.IgnoreQueryFilters().Where(job => job.MediaItemId != null && ids.Contains(job.MediaItemId.Value)
            || roots.Count > 0 && job.LibraryRootId != null && roots.Contains(job.LibraryRootId.Value)).ExecuteDeleteAsync(token);
        foreach (var entry in database.ChangeTracker.Entries<MetadataJob>().Where(entry => entry.Entity.MediaItemId is { } media && ids.Contains(media)
            || entry.Entity.LibraryRootId is { } root && roots.Contains(root)).ToArray()) entry.State = EntityState.Detached;
        if (exclude)
        {
            foreach (var item in items)
            {
                if (!await database.MediaExclusions.AnyAsync(value => value.LibraryRootId == item.LibraryRootId && value.NormalizedSourcePath == item.NormalizedSourcePath, token))
                    database.MediaExclusions.Add(new MediaExclusion
                    {
                        Id = Guid.NewGuid(),
                        LibraryRootId = item.LibraryRootId,
                        RelativePath = Path.GetRelativePath(item.LibraryRoot.Path, item.SourcePath),
                        NormalizedSourcePath = item.NormalizedSourcePath,
                        IsDirectory = item.Kind == MediaKind.Series,
                        FileSystemIdentity = item.FileSystemIdentity
                    });
            }
        }
        // Explicitly delete leaves first; ParentId deliberately has a restrictive FK.
        var remaining = items.ToDictionary(item => item.Id);
        while (remaining.Count > 0)
        {
            var parents = remaining.Values.Where(item => item.ParentId is not null).Select(item => item.ParentId!.Value).ToHashSet();
            var leaves = remaining.Keys.Where(id => !parents.Contains(id)).ToArray();
            if (leaves.Length == 0) throw new InvalidDataException("The catalog contains a parent cycle.");
            await database.MediaItems.Where(item => leaves.Contains(item.Id)).ExecuteDeleteAsync(token);
            foreach (var id in leaves) remaining.Remove(id);
        }
        var affected = items.Select(item => item.LibraryRootId).Concat(roots).Distinct().ToArray();
        var users = await database.UserLibraryGrants.IgnoreQueryFilters().Where(grant => affected.Contains(grant.LibraryRootId)).Select(grant => grant.UserId).Distinct().ToListAsync(token);
        users.AddRange(await database.Users.Where(user => user.Role == UserRole.Owner).Select(user => user.Id).ToListAsync(token));
        foreach (var account in users.Distinct())
            foreach (var area in new[] { SyncChangeArea.Catalog, SyncChangeArea.Libraries })
                database.SyncChanges.Add(new SyncChange { Area = area, UserId = account, CreatedAt = DateTimeOffset.UtcNow });
        if (roots.Count > 0) await database.LibraryRoots.Where(root => roots.Contains(root.Id)).ExecuteDeleteAsync(token);
        await database.MediaCollections.IgnoreQueryFilters().Where(collection => !collection.Members.Any()).ExecuteDeleteAsync(token);
        database.LibraryMutations.Add(receipt);
        // ExecuteDelete leaves stale tracked entities. Do not subsequently save them.
        foreach (var entry in database.ChangeTracker.Entries<MediaItem>().ToArray()) entry.State = EntityState.Detached;
        foreach (var entry in database.ChangeTracker.Entries<LibraryRoot>().Where(entry => roots.Contains(entry.Entity.Id)).ToArray()) entry.State = EntityState.Detached;
        await database.SaveChangesAsync(token);
        await transaction.CommitAsync(token);
        return receipt;
    }

    public async Task<LibraryMutationResult> StatusAsync(Guid id, CancellationToken token)
    {
        var receipt = await database.LibraryMutations.AsNoTracking().SingleOrDefaultAsync(value => value.Id == id, token)
            ?? throw new AccountException("operation_not_found", "The library operation was not found.", 404);
        return new(receipt.Id, receipt.State, receipt.RemovedItems, receipt.Error);
    }

    internal Guid TrackArtworkCleanup(Guid userId, IReadOnlyList<string> files)
    {
        var receipt = new LibraryMutation { Id = Guid.NewGuid(), UserId = userId, FilesJson = JsonSerializer.Serialize(files) };
        database.LibraryMutations.Add(receipt);
        return receipt.Id;
    }

    internal async Task<LibraryMutationResult> CleanupAsync(Guid id, CancellationToken token)
    {
        var receipt = await database.LibraryMutations.SingleAsync(value => value.Id == id, token);
        if (receipt.State == "completed") return new(receipt.Id, receipt.State, receipt.RemovedItems, null);
        try
        {
            var referenced = await database.ArtworkAssets.IgnoreQueryFilters().Select(asset => new { asset.RelativeFilePath, asset.OriginalFilePath }).ToListAsync(token);
            var keep = referenced.SelectMany(asset => new[] { asset.RelativeFilePath, asset.OriginalFilePath }).ToHashSet(StringComparer.Ordinal);
            foreach (var name in JsonSerializer.Deserialize<string[]>(receipt.FilesJson) ?? [])
            {
                token.ThrowIfCancellationRequested();
                var draft = name.StartsWith("EditorUploads/", StringComparison.Ordinal);
                var file = draft ? name["EditorUploads/".Length..] : name;
                if (Path.GetFileName(file) != file || string.IsNullOrWhiteSpace(file) || file is "." or "..") throw new InvalidDataException("Invalid managed artwork path.");
                if (keep.Contains(name)) continue;
                var path = Path.Combine(runtime.DataDirectory, draft ? "EditorUploads" : "Artwork", file);
                // File.Exists hides permission/IO errors as "missing". Delete directly so
                // an unreadable managed file cannot be reported as successfully cleaned.
                try { File.Delete(path); }
                catch (DirectoryNotFoundException) { } // Already removed: cleanup is idempotent.
                catch (FileNotFoundException) { }
            }
            receipt.State = "completed"; receipt.Error = null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { receipt.Error = "Artwork cleanup is pending. Check disk permissions; the server will retry automatically."; }
        await database.SaveChangesAsync(token);
        return new(receipt.Id, receipt.State, receipt.RemovedItems, receipt.Error);
    }
}

public sealed partial class LibraryCleanupWorker(IServiceScopeFactory scopes, CatalogMutationGate mutations, EditorArtworkStore images,
    ILogger<LibraryCleanupWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var failureReported = false;
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
                using var lease = await mutations.EnterAsync(stoppingToken);
                await using var scope = scopes.CreateAsyncScope();
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var service = scope.ServiceProvider.GetRequiredService<LibraryMutationService>();
                foreach (var id in await database.LibraryMutations.Where(value => value.State != "completed").OrderBy(value => value.Id)
                    .Select(value => value.Id).Take(32).ToArrayAsync(stoppingToken))
                    await service.CleanupAsync(id, stoppingToken);
                await images.PruneDraftsAsync(stoppingToken);
                failureReported = false;
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { return; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or DbUpdateException or Microsoft.Data.Sqlite.SqliteException)
            {
                // A full disk or unavailable database must not stop the media server. The durable receipts remain pending.
                if (!failureReported) CleanupUnavailable(logger);
                failureReported = true;
            }
        }
    }

    [LoggerMessage(LogLevel.Warning, "Managed image cleanup could not finish and will be retried. Check storage availability and private file permissions.")]
    private static partial void CleanupUnavailable(ILogger logger);
}
