using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed partial class LibraryScanWorker(
    LibraryScanScheduler queue,
    MetadataJobScheduler metadataQueue,
    MetadataProviderSettingsStore metadataSettings,
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
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
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

        var scanRoot = ResolveScanRoot(library.Path, request.TargetRelativePath);
        EnsureReadableRoot(scanRoot);
        var allExistingEpisodes = await database.MediaItems
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
        var existingEpisodes = allExistingEpisodes.Where(item =>
            MediaPath.IsSameOrDescendant(
                MediaPath.Normalize(item.FilePath),
                MediaPath.Normalize(scanRoot))).ToList();
        var storedDecisions = await database.LibraryDiscoveries
            .AsNoTracking()
            .Where(discovery => discovery.LibraryRootId == library.Id
                && discovery.Decision != null)
            .Select(discovery => new
            {
                discovery.RelativePath,
                Decision = discovery.Decision!.Value,
            })
            .ToListAsync(cancellationToken);
        var classificationDecisions = storedDecisions.Select(decision =>
            new
            {
                FullPath = Path.GetFullPath(Path.Combine(library.Path, decision.RelativePath)),
                decision.Decision,
            })
            .Where(decision => MediaPath.IsSameOrDescendant(
                MediaPath.Normalize(decision.FullPath),
                MediaPath.Normalize(scanRoot)))
            .Select(decision => new ExistingClassificationDecision(
                Path.GetRelativePath(scanRoot, decision.FullPath) is "." ? string.Empty :
                    Path.GetRelativePath(scanRoot, decision.FullPath),
                decision.Decision))
            .ToList();

        var discoveredCount = 0;
        var discoveryTask = Task.Run(
            () => scanner.Scan(
                scanRoot,
                library.Kind,
                existingEpisodes,
                count => Volatile.Write(ref discoveredCount, count),
                cancellationToken,
                classificationDecisions),
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
        if (request.TargetRelativePath is not null)
        {
            discovery = PrefixClassifications(discovery, request.TargetRelativePath);
        }

        await ReconcileAsync(
            database,
            library,
            scan,
            discovery,
            scanRoot,
            request.TargetRelativePath,
            cancellationToken);
        await RebuildLocalCollectionsAsync(database, library, cancellationToken);
        await PruneOldScansAsync(database, library.Id, scan.Id, cancellationToken);
        if (metadataSettings.Load().Enabled
            && !await database.MetadataJobs.AnyAsync(
                job => job.State == MetadataJobState.Queued || job.State == MetadataJobState.Running,
                cancellationToken))
        {
            var metadataJob = new MetadataJob
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                State = MetadataJobState.Queued,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            database.MetadataJobs.Add(metadataJob);
            await database.SaveChangesAsync(cancellationToken);
            metadataQueue.Enqueue(metadataJob.Id);
        }
    }

    private static async Task RebuildLocalCollectionsAsync(
        AureliaDbContext database,
        LibraryRoot library,
        CancellationToken cancellationToken)
    {
        var root = MediaPath.Normalize(library.Path);
        var items = await database.MediaItems
            .Where(item => item.LibraryRootId == library.Id
                && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series))
            .ToListAsync(cancellationToken);
        var groups = items.Select(item => new
        {
            Item = item,
            Container = CollectionContainer(item, root),
        })
            .Where(value => value.Container is not null)
            .GroupBy(value => value.Container!, StringComparer.Ordinal)
            .Where(group => group.Count() >= 2)
            .ToDictionary(group => group.Key, group => group.Select(value => value.Item).ToList(), StringComparer.Ordinal);

        var existing = (await database.MediaCollections.Include(collection => collection.Members)
            .Where(collection => collection.Provider == "local" && collection.SourceKey != null)
            .ToListAsync(cancellationToken))
            .Where(collection => MediaPath.IsSameOrDescendant(collection.SourceKey!, root))
            .ToList();
        foreach (var collection in existing.Where(collection => !groups.ContainsKey(collection.SourceKey!)))
            database.MediaCollections.Remove(collection);

        foreach (var (sourceKey, members) in groups)
        {
            var collection = existing.SingleOrDefault(value => value.SourceKey == sourceKey);
            if (collection is null)
            {
                collection = new MediaCollectionRecord
                {
                    Id = Guid.NewGuid(),
                    Provider = "local",
                    SourceKey = sourceKey,
                    Name = Path.GetFileName(sourceKey),
                    CreatedAt = DateTimeOffset.UtcNow,
                };
                database.MediaCollections.Add(collection);
            }
            collection.UpdatedAt = DateTimeOffset.UtcNow;
            var desired = members.Select(item => item.Id).ToHashSet();
            foreach (var old in collection.Members.Where(member => !desired.Contains(member.MediaItemId)).ToList())
                database.MediaCollectionMembers.Remove(old);
            var order = 0;
            foreach (var item in members.OrderBy(item => item.OverrideTitle ?? item.DetectedTitle))
            {
                var member = collection.Members.SingleOrDefault(value => value.MediaItemId == item.Id);
                if (member is null)
                {
                    member = new MediaCollectionMember { CollectionId = collection.Id, MediaItemId = item.Id };
                    collection.Members.Add(member);
                }
                member.SortOrder = order++;
            }
        }
        await database.SaveChangesAsync(cancellationToken);
    }

    private static string? CollectionContainer(MediaItem item, string libraryRoot)
    {
        var source = MediaPath.Normalize(item.SourcePath);
        var anchor = Path.GetDirectoryName(source);
        if (string.IsNullOrWhiteSpace(anchor) || anchor == libraryRoot
            || !MediaPath.IsSameOrDescendant(anchor, libraryRoot)) return null;
        return anchor;
    }

    private static async Task ReconcileAsync(
        AureliaDbContext database,
        LibraryRoot library,
        LibraryScan scan,
        MediaScanDiscovery discovery,
        string scanRoot,
        string? targetRelativePath,
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

        await ReconcileDiscoveriesAsync(
            database,
            library,
            scan.Id,
            discovery.Classifications ?? [],
            targetRelativePath,
            now,
            cancellationToken);

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
                     && !seenIds.Contains(item.Id)
                     && MediaPath.IsSameOrDescendant(
                         item.NormalizedSourcePath,
                         MediaPath.Normalize(scanRoot))))
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

    private static async Task ReconcileDiscoveriesAsync(
        AureliaDbContext database,
        LibraryRoot library,
        Guid scanId,
        IReadOnlyList<DiscoveredClassification> classifications,
        string? targetRelativePath,
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        if (library.Kind != LibraryKind.Automatic)
        {
            return;
        }

        var stored = await database.LibraryDiscoveries
            .Where(discovery => discovery.LibraryRootId == library.Id)
            .ToListAsync(cancellationToken);
        var byPath = stored.ToDictionary(
            discovery => discovery.NormalizedRelativePath,
            StringComparer.Ordinal);
        var seen = new HashSet<Guid>();
        foreach (var classification in classifications)
        {
            var normalized = NormalizeRelativePath(classification.RelativePath);
            if (!byPath.TryGetValue(normalized, out var entry))
            {
                entry = new LibraryDiscovery
                {
                    Id = Guid.NewGuid(),
                    LibraryRoot = library,
                    LibraryRootId = library.Id,
                    NormalizedRelativePath = normalized,
                    CreatedAt = now,
                };
                database.LibraryDiscoveries.Add(entry);
                byPath[normalized] = entry;
            }

            entry.RelativePath = classification.RelativePath;
            entry.DetectedTitle = classification.DetectedTitle;
            entry.SuggestedKind = classification.SuggestedKind;
            entry.Reason = classification.Reason;
            entry.LastSeenScanId = scanId;
            entry.UpdatedAt = now;
            seen.Add(entry.Id);
        }

        var normalizedTarget = targetRelativePath is null
            ? null
            : NormalizeRelativePath(targetRelativePath);
        database.LibraryDiscoveries.RemoveRange(stored.Where(discovery =>
            discovery.Decision == null
            && !seen.Contains(discovery.Id)
            && (normalizedTarget is null
                || IsSameOrDescendantRelative(
                    discovery.NormalizedRelativePath,
                    normalizedTarget))));
    }

    private static string ResolveScanRoot(string libraryPath, string? targetRelativePath)
    {
        if (targetRelativePath is null)
        {
            return libraryPath;
        }

        var candidate = Path.GetFullPath(Path.Combine(libraryPath, targetRelativePath));
        if (!MediaPath.IsSameOrDescendant(
                MediaPath.Normalize(candidate),
                MediaPath.Normalize(libraryPath)))
        {
            throw new LibraryException(
                "invalid_scan_target",
                "The selected folder is outside the storage location.",
                StatusCodes.Status400BadRequest);
        }

        return candidate;
    }

    private static MediaScanDiscovery PrefixClassifications(
        MediaScanDiscovery discovery,
        string targetRelativePath)
    {
        return discovery with
        {
            Classifications = (discovery.Classifications ?? []).Select(item => item with
            {
                RelativePath = string.IsNullOrEmpty(item.RelativePath)
                    ? targetRelativePath
                    : Path.Combine(targetRelativePath, item.RelativePath),
            }).ToList(),
        };
    }

    private static bool IsSameOrDescendantRelative(string candidate, string parent)
    {
        return candidate == parent
            || candidate.StartsWith(parent + Path.DirectorySeparatorChar, StringComparison.Ordinal);
    }

    private static string NormalizeRelativePath(string path)
    {
        return path.Replace(Path.AltDirectorySeparatorChar, Path.DirectorySeparatorChar)
            .Trim(Path.DirectorySeparatorChar)
            .Normalize(System.Text.NormalizationForm.FormKC)
            .ToUpperInvariant();
    }

    private static MediaItem Upsert(
        AureliaDbContext database,
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
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        await database.LibraryScans
            .Where(scan => scan.Id == scanId && scan.State == LibraryScanState.Running)
            .ExecuteUpdateAsync(
                updates => updates
                    .SetProperty(scan => scan.FilesDiscovered, count)
                    .SetProperty(scan => scan.FilesProcessed, count),
                cancellationToken);
    }

    private static async Task PruneOldScansAsync(
        AureliaDbContext database,
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
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
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
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
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
