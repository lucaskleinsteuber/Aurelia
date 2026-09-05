using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Home.Server.Services;

public sealed partial class LibraryScanWorker(
    LibraryScanScheduler queue,
    IServiceScopeFactory scopeFactory,
    IMediaLibraryScanner scanner,
    ILogger<LibraryScanWorker> logger) : BackgroundService
{
    private const int MaximumStoredIssues = 500;
    private const int RetainedScansPerLibrary = 25;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await foreach (var request in queue.ReadAllAsync(stoppingToken))
        {
            try
            {
                await ProcessAsync(request, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                await MarkInterruptedAsync(request.ScanId);
            }
            catch (LibraryException exception)
            {
                await MarkFailedAsync(request.ScanId, request.LibraryId, exception);
            }
            catch (Exception exception)
            {
                LogScanFailed(logger, request.ScanId, exception);
                await MarkFailedAsync(request.ScanId, request.LibraryId, exception);
            }
            finally
            {
                queue.Release(request.LibraryId);
            }
        }
    }

    private async Task ProcessAsync(QueuedLibraryScan request, CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
        var scan = await database.LibraryScans.SingleAsync(
            candidate => candidate.Id == request.ScanId,
            cancellationToken);
        var library = await database.LibraryRoots.SingleAsync(
            candidate => candidate.Id == request.LibraryId,
            cancellationToken);

        var startedAt = DateTimeOffset.UtcNow;
        scan.State = LibraryScanState.Running;
        scan.StartedAt = startedAt;
        library.LastScanStartedAt = startedAt;
        library.LastError = null;
        await database.SaveChangesAsync(cancellationToken);

        EnsureReadableRoot(library.Path);
        var existingEpisodes = await database.MediaItems
            .AsNoTracking()
            .Where(item => item.LibraryRootId == library.Id
                && item.Kind == MediaKind.Episode
                && item.ParentId != null
                && item.SeasonNumber != null
                && item.EpisodeNumber != null)
            .Select(item => new ExistingEpisodeBinding(
                item.Parent!.SourcePath,
                item.SeasonNumber!.Value,
                item.EpisodeNumber!.Value,
                item.SourcePath))
            .ToListAsync(cancellationToken);

        var discoveredCount = 0;
        var discoveryTask = Task.Run(
            () => scanner.Scan(
                library.Path,
                library.Kind,
                existingEpisodes,
                count => Volatile.Write(ref discoveredCount, count),
                cancellationToken),
            cancellationToken);
        var lastReportedCount = -1;
        while (!discoveryTask.IsCompleted)
        {
            await Task.WhenAny(discoveryTask, Task.Delay(500, cancellationToken));
            var currentCount = Volatile.Read(ref discoveredCount);
            if (currentCount != lastReportedCount)
            {
                await UpdateProgressAsync(request.ScanId, currentCount, cancellationToken);
                lastReportedCount = currentCount;
            }
        }

        var discovery = await discoveryTask;
        await ReconcileAsync(database, library, scan, discovery, cancellationToken);
        await PruneOldScansAsync(database, library.Id, scan.Id, cancellationToken);
    }

    private static async Task ReconcileAsync(
        AureliaHomeDbContext database,
        LibraryRoot library,
        LibraryScan scan,
        MediaScanDiscovery discovery,
        CancellationToken cancellationToken)
    {
        await using var transaction = await database.Database.BeginTransactionAsync(cancellationToken);
        var now = DateTimeOffset.UtcNow;
        var allItems = await database.MediaItems
            .Where(item => item.LibraryRootId == library.Id)
            .ToListAsync(cancellationToken);
        var itemsByPath = allItems.ToDictionary(
            item => item.NormalizedSourcePath,
            StringComparer.Ordinal);
        var seenIds = new HashSet<Guid>();
        var parentsByPath = new Dictionary<string, MediaItem>(StringComparer.Ordinal);
        var addedFiles = 0;
        var updatedFiles = 0;

        foreach (var candidate in discovery.Items.Where(item =>
                     item.Kind is MediaKind.Movie or MediaKind.Series))
        {
            var item = Upsert(
                database,
                candidate,
                parentId: null,
                library,
                scan.Id,
                now,
                allItems,
                itemsByPath,
                seenIds,
                out var wasAdded,
                out var wasUpdated);
            parentsByPath[MediaPath.Normalize(candidate.SourcePath)] = item;
            if (candidate.IsFile && wasAdded)
            {
                addedFiles += 1;
            }
            else if (candidate.IsFile && wasUpdated)
            {
                updatedFiles += 1;
            }
        }

        foreach (var candidate in discovery.Items.Where(item =>
                     item.Kind is not (MediaKind.Movie or MediaKind.Series)))
        {
            var normalizedParentPath = MediaPath.Normalize(candidate.ParentSourcePath!);
            if (!parentsByPath.TryGetValue(normalizedParentPath, out var parent))
            {
                continue;
            }

            var item = Upsert(
                database,
                candidate,
                parent.Id,
                library,
                scan.Id,
                now,
                allItems,
                itemsByPath,
                seenIds,
                out var wasAdded,
                out var wasUpdated);
            if (wasAdded)
            {
                addedFiles += 1;
            }
            else if (wasUpdated)
            {
                updatedFiles += 1;
            }
        }

        var missingFiles = 0;
        foreach (var item in allItems.Where(item => item.Kind != MediaKind.Series
                     && !seenIds.Contains(item.Id)))
        {
            if (item.Availability == MediaAvailability.Available)
            {
                missingFiles += 1;
                item.Availability = MediaAvailability.Missing;
                item.UpdatedAt = now;
            }
        }

        foreach (var series in allItems.Where(item => item.Kind == MediaKind.Series))
        {
            series.Availability = allItems.Any(item =>
                item.ParentId == series.Id && item.Availability == MediaAvailability.Available)
                ? MediaAvailability.Available
                : MediaAvailability.Missing;
            series.UpdatedAt = now;
        }

        foreach (var issue in discovery.Issues.Take(MaximumStoredIssues))
        {
            scan.Issues.Add(new LibraryScanIssue
            {
                Code = issue.Code,
                Message = issue.Message,
                Path = issue.Path,
            });
        }

        scan.State = LibraryScanState.Completed;
        scan.CompletedAt = now;
        scan.FilesDiscovered = discovery.FilesDiscovered;
        scan.FilesProcessed = discovery.FilesDiscovered;
        scan.AddedFiles = addedFiles;
        scan.UpdatedFiles = updatedFiles;
        scan.MissingFiles = missingFiles;
        scan.SkippedFiles = discovery.SkippedFiles;
        library.Availability = LibraryAvailability.Available;
        library.LastScanCompletedAt = now;
        library.LastError = null;
        try
        {
            await database.SaveChangesAsync(cancellationToken);
        }
        catch (DbUpdateConcurrencyException exception)
        {
            var entries = string.Join(
                ", ",
                exception.Entries.Select(entry => entry.Metadata.ClrType.Name));
            throw new InvalidOperationException(
                $"The scan database update lost these records: {entries}.",
                exception);
        }

        await transaction.CommitAsync(cancellationToken);
    }

    private static MediaItem Upsert(
        AureliaHomeDbContext database,
        DiscoveredMediaItem candidate,
        Guid? parentId,
        LibraryRoot library,
        Guid scanId,
        DateTimeOffset now,
        List<MediaItem> allItems,
        Dictionary<string, MediaItem> itemsByPath,
        HashSet<Guid> seenIds,
        out bool wasAdded,
        out bool wasUpdated)
    {
        var normalizedPath = MediaPath.Normalize(candidate.SourcePath);
        itemsByPath.TryGetValue(normalizedPath, out var item);
        if (item is null
            && candidate.Kind == MediaKind.Episode
            && parentId.HasValue)
        {
            item = allItems.FirstOrDefault(existing =>
                existing.Kind == MediaKind.Episode
                && existing.ParentId == parentId
                && existing.SeasonNumber == candidate.SeasonNumber
                && existing.EpisodeNumber == candidate.EpisodeNumber
                && !seenIds.Contains(existing.Id));
            if (item is not null)
            {
                itemsByPath.Remove(item.NormalizedSourcePath);
                itemsByPath[normalizedPath] = item;
            }
        }

        wasAdded = item is null;
        if (item is null)
        {
            item = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRoot = library,
                LibraryRootId = library.Id,
                CreatedAt = now,
                OverrideTitle = null,
            };
            allItems.Add(item);
            itemsByPath[normalizedPath] = item;
            database.MediaItems.Add(item);
        }

        wasUpdated = !wasAdded && (
            item.Kind != candidate.Kind
            || item.ParentId != parentId
            || item.SourcePath != candidate.SourcePath
            || item.DetectedTitle != candidate.DetectedTitle
            || item.Year != candidate.Year
            || item.SeasonNumber != candidate.SeasonNumber
            || item.EpisodeNumber != candidate.EpisodeNumber
            || item.Category != candidate.Category
            || item.Extension != candidate.Extension
            || item.FileSize != candidate.FileSize
            || item.FileModifiedAt != candidate.FileModifiedAt
            || item.Availability != MediaAvailability.Available);
        item.ParentId = parentId;
        item.Kind = candidate.Kind;
        item.SourcePath = candidate.SourcePath;
        item.NormalizedSourcePath = normalizedPath;
        item.DetectedTitle = candidate.DetectedTitle;
        item.Year = candidate.Year;
        item.SeasonNumber = candidate.SeasonNumber;
        item.EpisodeNumber = candidate.EpisodeNumber;
        item.Category = candidate.Category;
        item.Extension = candidate.Extension;
        item.FileSize = candidate.FileSize;
        item.FileModifiedAt = candidate.FileModifiedAt;
        item.Availability = MediaAvailability.Available;
        item.LastSeenScanId = scanId;
        item.UpdatedAt = now;
        seenIds.Add(item.Id);
        return item;
    }

    private async Task UpdateProgressAsync(
        Guid scanId,
        int count,
        CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
        await database.LibraryScans
            .Where(scan => scan.Id == scanId && scan.State == LibraryScanState.Running)
            .ExecuteUpdateAsync(
                updates => updates
                    .SetProperty(scan => scan.FilesDiscovered, count)
                    .SetProperty(scan => scan.FilesProcessed, count),
                cancellationToken);
    }

    private static async Task PruneOldScansAsync(
        AureliaHomeDbContext database,
        Guid libraryId,
        Guid currentScanId,
        CancellationToken cancellationToken)
    {
        var oldScanIds = await database.LibraryScans
            .AsNoTracking()
            .Where(scan => scan.LibraryRootId == libraryId && scan.Id != currentScanId)
            .OrderByDescending(scan => scan.CreatedAt)
            .Skip(RetainedScansPerLibrary - 1)
            .Select(scan => scan.Id)
            .ToListAsync(cancellationToken);
        if (oldScanIds.Count > 0)
        {
            await database.LibraryScans
                .Where(scan => oldScanIds.Contains(scan.Id))
                .ExecuteDeleteAsync(cancellationToken);
        }
    }

    private static void EnsureReadableRoot(string path)
    {
        var directory = new DirectoryInfo(path);
        if (!directory.Exists || directory.LinkTarget is not null)
        {
            throw new LibraryException(
                "library_unavailable",
                "The library directory is unavailable.",
                StatusCodes.Status409Conflict);
        }

        try
        {
            _ = directory.EnumerateFileSystemInfos().Take(1).ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new LibraryException(
                "library_unavailable",
                "The library directory is unavailable.",
                StatusCodes.Status409Conflict);
        }
    }

    private async Task MarkFailedAsync(Guid scanId, Guid libraryId, Exception exception)
    {
        try
        {
            await using var scope = scopeFactory.CreateAsyncScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
            var scan = await database.LibraryScans.SingleOrDefaultAsync(candidate => candidate.Id == scanId);
            var library = await database.LibraryRoots.SingleOrDefaultAsync(candidate => candidate.Id == libraryId);
            var message = exception is LibraryException libraryException
                ? libraryException.Message
                : "The library scan failed.";
            if (scan is not null)
            {
                scan.State = LibraryScanState.Failed;
                scan.CompletedAt = DateTimeOffset.UtcNow;
                scan.Error = message;
            }

            if (library is not null)
            {
                library.Availability = exception is LibraryException { Code: "library_unavailable" }
                    ? LibraryAvailability.Unavailable
                    : LibraryAvailability.Error;
                library.LastScanCompletedAt = DateTimeOffset.UtcNow;
                library.LastError = message;
            }

            await database.SaveChangesAsync();
        }
        catch (Exception persistenceException)
        {
            LogFailurePersistenceFailed(logger, scanId, persistenceException);
        }
    }

    private async Task MarkInterruptedAsync(Guid scanId)
    {
        try
        {
            await using var scope = scopeFactory.CreateAsyncScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
            await database.LibraryScans
                .Where(scan => scan.Id == scanId
                    && (scan.State == LibraryScanState.Queued
                        || scan.State == LibraryScanState.Running))
                .ExecuteUpdateAsync(updates => updates
                    .SetProperty(scan => scan.State, LibraryScanState.Interrupted)
                    .SetProperty(scan => scan.CompletedAt, DateTimeOffset.UtcNow)
                    .SetProperty(scan => scan.Error, "The server stopped before the scan completed."));
        }
        catch (Exception exception)
        {
            LogInterruptedPersistenceFailed(logger, scanId, exception);
        }
    }

    [LoggerMessage(1, LogLevel.Error, "Library scan {ScanId} failed.")]
    private static partial void LogScanFailed(ILogger logger, Guid scanId, Exception exception);

    [LoggerMessage(2, LogLevel.Error, "Failed to persist scan failure {ScanId}.")]
    private static partial void LogFailurePersistenceFailed(
        ILogger logger,
        Guid scanId,
        Exception exception);

    [LoggerMessage(3, LogLevel.Error, "Failed to mark scan {ScanId} as interrupted.")]
    private static partial void LogInterruptedPersistenceFailed(
        ILogger logger,
        Guid scanId,
        Exception exception);
}
