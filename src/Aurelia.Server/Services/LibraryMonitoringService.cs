using System.Collections.Concurrent;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed partial class LibraryMonitoringService(
    IServiceScopeFactory scopeFactory,
    ILogger<LibraryMonitoringService> logger,
    ServerConfigurationStore configuration) : BackgroundService
{
    private static readonly TimeSpan Debounce = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan StabilityDelay = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan RecentStartupScan = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan LibraryRefreshInterval = TimeSpan.FromSeconds(30);
    private readonly ConcurrentDictionary<Guid, PendingChanges> pending = new();
    private readonly Dictionary<Guid, WatchRegistration> watchers = [];
    private readonly HashSet<Guid> startupConsidered = [];
    private DateTimeOffset nextLibraryRefresh = DateTimeOffset.MinValue;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            var recovery = new StorageRecovery(logger, "library monitoring");
            while (!stoppingToken.IsCancellationRequested)
            {
                var now = DateTimeOffset.UtcNow;
                if (now >= nextLibraryRefresh)
                {
                    await recovery.RunAsync(() => RefreshLibrariesAsync(now, stoppingToken), stoppingToken);
                    nextLibraryRefresh = now.Add(LibraryRefreshInterval);
                }

                await recovery.RunAsync(() => FlushPendingAsync(now, stoppingToken), stoppingToken);
                await Task.Delay(TimeSpan.FromSeconds(1), stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // Expected during server shutdown.
        }
        finally
        {
            foreach (var registration in watchers.Values)
            {
                registration.Dispose();
            }

            watchers.Clear();
        }
    }

    private async Task RefreshLibrariesAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var service = scope.ServiceProvider.GetRequiredService<LibraryService>();
        var libraries = await database.LibraryRoots.AsNoTracking()
            .OrderBy(library => library.Id)
            .ToListAsync(cancellationToken);
        var latestFullScans = await database.LibraryScans.AsNoTracking()
            .Where(scan => scan.State == LibraryScanState.Completed
                && scan.TargetRelativePath == null
                && scan.CompletedAt != null)
            .GroupBy(scan => scan.LibraryRootId)
            .Select(group => new
            {
                LibraryId = group.Key,
                CompletedAt = group.Max(scan => scan.CompletedAt),
            })
            .ToDictionaryAsync(value => value.LibraryId, value => value.CompletedAt, cancellationToken);
        var currentIds = libraries.Select(library => library.Id).ToHashSet();
        foreach (var stale in watchers.Keys.Where(id => !currentIds.Contains(id)).ToList())
        {
            if (watchers.Remove(stale, out var registration))
            {
                registration.Dispose();
            }
            pending.TryRemove(stale, out _);
        }

        foreach (var library in libraries)
        {
            if (library.ImportPreviewRequired)
            {
                if (watchers.Remove(library.Id, out var unconfirmed)) unconfirmed.Dispose();
                pending.TryRemove(library.Id, out _);
                continue;
            }
            var reachable = IsReadableDirectory(library.Path);
            if (!configuration.Current.MonitoringEnabled || !library.MonitoringEnabled || !reachable)
            {
                if (watchers.Remove(library.Id, out var old))
                {
                    old.Dispose();
                }

                if (configuration.Current.MonitoringEnabled && library.MonitoringEnabled && !reachable)
                {
                    await EnsureWaitingScanAsync(service, library, cancellationToken);
                }

                continue;
            }

            if (!watchers.ContainsKey(library.Id))
            {
                try
                {
                    watchers[library.Id] = CreateWatcher(library);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    LogWatcherFailed(logger, library.Id, exception.GetType().Name);
                    await EnsureWaitingScanAsync(service, library, cancellationToken);
                    continue;
                }
            }

            if (library.Availability == LibraryAvailability.Unavailable
                && await service.ResumeWaitingForStorageAsync(library.Id, cancellationToken))
            {
                continue;
            }

            var latestFullScan = latestFullScans.GetValueOrDefault(library.Id);
            var reconciliationInterval = TimeSpan.FromMinutes(configuration.Current.ReconciliationMinutes);
            var needsStartup = !startupConsidered.Contains(library.Id)
                && (!latestFullScan.HasValue
                    || now - latestFullScan.Value > RecentStartupScan);
            var needsScheduled = latestFullScan.HasValue
                && now - latestFullScan.Value >= reconciliationInterval
                && (!library.LastScanStartedAt.HasValue
                    || now - library.LastScanStartedAt.Value >= reconciliationInterval);
            if ((needsStartup || needsScheduled) && configuration.IsMaintenanceWindow(now))
            {
                var started = await TryStartAsync(
                    service,
                    library.Id,
                    needsStartup ? LibraryScanTrigger.Startup : LibraryScanTrigger.Scheduled,
                    targetRelativePath: null,
                    cancellationToken);
                if (started) startupConsidered.Add(library.Id);
            }
            else if (!needsStartup && configuration.IsMaintenanceWindow(now)) startupConsidered.Add(library.Id);
        }

    }

    private WatchRegistration CreateWatcher(LibraryRoot library)
    {
        var watcher = new FileSystemWatcher(library.Path)
        {
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.FileName
                | NotifyFilters.DirectoryName
                | NotifyFilters.Size
                | NotifyFilters.LastWrite,
            InternalBufferSize = 64 * 1024,
        };
        FileSystemEventHandler changed = (_, eventArgs) => Record(library, eventArgs.FullPath, false);
        RenamedEventHandler renamed = (_, eventArgs) =>
        {
            Record(library, eventArgs.OldFullPath, false);
            Record(library, eventArgs.FullPath, false);
        };
        ErrorEventHandler error = (_, _) => Record(library, library.Path, true);
        watcher.Created += changed;
        watcher.Changed += changed;
        watcher.Deleted += changed;
        watcher.Renamed += renamed;
        watcher.Error += error;
        watcher.EnableRaisingEvents = true;
        return new WatchRegistration(watcher, changed, renamed, error);
    }

    private void Record(LibraryRoot library, string path, bool forceFull)
    {
        if (!forceFull && !IsRelevant(path))
        {
            return;
        }

        while (true)
        {
            var state = pending.GetOrAdd(library.Id, _ => new PendingChanges(library.Path));
            if (state.TryRecord(path, forceFull)) return;
            // A flush retired this state while the watcher callback held a
            // reference to it. Retry against the current dictionary entry.
        }
    }

    private async Task FlushPendingAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        if (!configuration.Current.MonitoringEnabled) { pending.Clear(); return; }
        if (!configuration.IsMaintenanceWindow(now)) return;
        foreach (var (libraryId, changes) in pending.ToArray())
        {
            if (!changes.Ready(now, Debounce, StabilityDelay, out var target, out var revision))
            {
                continue;
            }

            await using var scope = scopeFactory.CreateAsyncScope();
            var service = scope.ServiceProvider.GetRequiredService<LibraryService>();
            var started = await TryStartAsync(
                service,
                libraryId,
                LibraryScanTrigger.FileChange,
                target,
                cancellationToken);
            if (started)
            {
                changes.TryAcknowledge(revision, () => pending.TryRemove(new KeyValuePair<Guid, PendingChanges>(libraryId, changes)));
            }
            else
            {
                changes.Defer(now);
            }
        }
    }

    private static async Task EnsureWaitingScanAsync(
        LibraryService service,
        LibraryRoot library,
        CancellationToken cancellationToken)
    {
        try
        {
            _ = await service.StartScanAsync(
                library.Id,
                LibraryScanTrigger.Scheduled,
                targetRelativePath: null,
                cancellationToken);
        }
        catch (LibraryException exception) when (exception.Code == "library_scan_active")
        {
            // Existing queued, running, or waiting work already represents this library.
        }
    }

    private static async Task<bool> TryStartAsync(
        LibraryService service,
        Guid libraryId,
        LibraryScanTrigger trigger,
        string? targetRelativePath,
        CancellationToken cancellationToken)
    {
        try
        {
            _ = await service.StartScanAsync(libraryId, trigger, targetRelativePath, cancellationToken);
            return true;
        }
        catch (LibraryException exception) when (exception.Code == "library_scan_active")
        {
            return false;
        }
    }

    private static bool IsRelevant(string path)
    {
        var name = Path.GetFileName(path);
        if (name.StartsWith('.') || name.EndsWith('~') || name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return string.IsNullOrEmpty(Path.GetExtension(path))
            || MediaLibraryScanner.IsSupportedMediaPath(path);
    }

    private static bool IsReadableDirectory(string path)
    {
        try
        {
            var directory = new DirectoryInfo(path);
            return directory.Exists
                && directory.LinkTarget is null
                && directory.EnumerateFileSystemInfos().Take(1).ToArray() is not null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    [LoggerMessage(LogLevel.Warning, "Library watcher {LibraryId} could not start ({ErrorType}).")]
    private static partial void LogWatcherFailed(ILogger logger, Guid libraryId, string errorType);

    internal sealed class PendingChanges(string root)
    {
        private readonly Lock gate = new();
        private readonly HashSet<string> directories = new(StringComparer.Ordinal);
        private readonly HashSet<string> files = new(StringComparer.Ordinal);
        private readonly Dictionary<string, FileSnapshot> snapshots = new(StringComparer.Ordinal);
        private DateTimeOffset lastEvent = DateTimeOffset.UtcNow;
        private DateTimeOffset? lastStabilityCheck;
        private bool forceFull;
        private long revision;
        private bool retired;

        public bool TryRecord(string path, bool full, DateTimeOffset? eventTime = null)
        {
            lock (gate)
            {
                if (retired) return false;
                revision++;
                forceFull |= full;
                lastEvent = eventTime ?? DateTimeOffset.UtcNow;
                var fullPath = Path.GetFullPath(path);
                if (MediaLibraryScanner.IsSupportedMediaPath(fullPath))
                {
                    files.Add(fullPath);
                    directories.Add(Path.GetDirectoryName(fullPath) ?? root);
                }
                else
                {
                    directories.Add(Directory.Exists(fullPath)
                        ? fullPath
                        : Path.GetDirectoryName(fullPath) ?? root);
                }
                return true;
            }
        }

        public bool TryAcknowledge(long expectedRevision, Func<bool> removeCurrent)
        {
            lock (gate)
            {
                if (retired || revision != expectedRevision || !removeCurrent()) return false;
                retired = true;
                return true;
            }
        }

        public bool Ready(
            DateTimeOffset now,
            TimeSpan debounce,
            TimeSpan stabilityDelay,
            out string? targetRelativePath,
            out long currentRevision)
        {
            lock (gate)
            {
                targetRelativePath = null;
                currentRevision = revision;
                if (retired) return false;
                if (now - lastEvent < debounce)
                {
                    return false;
                }

                if (files.Any(File.Exists))
                {
                    if (!lastStabilityCheck.HasValue || now - lastStabilityCheck.Value < stabilityDelay)
                    {
                        if (!lastStabilityCheck.HasValue)
                        {
                            CaptureSnapshots();
                            lastStabilityCheck = now;
                        }

                        return false;
                    }

                    if (!AreFilesStable())
                    {
                        CaptureSnapshots();
                        lastStabilityCheck = now;
                        return false;
                    }
                }

                if (forceFull || directories.Count == 0)
                {
                    return true;
                }

                var common = CommonDirectory(directories);
                var relative = Path.GetRelativePath(root, common);
                targetRelativePath = relative == "." ? null : relative;
                return true;
            }
        }

        public void Defer(DateTimeOffset now)
        {
            lock (gate)
            {
                if (now > lastEvent) lastEvent = now;
            }
        }

        private void CaptureSnapshots()
        {
            foreach (var path in files.Where(File.Exists))
            {
                var info = new FileInfo(path);
                snapshots[path] = new FileSnapshot(info.Length, info.LastWriteTimeUtc);
            }
        }

        private bool AreFilesStable()
        {
            foreach (var path in files.Where(File.Exists))
            {
                var info = new FileInfo(path);
                if (!snapshots.TryGetValue(path, out var old)
                    || old.Length != info.Length
                    || old.ModifiedAt != info.LastWriteTimeUtc)
                {
                    return false;
                }
            }

            return true;
        }

        private static string CommonDirectory(IEnumerable<string> values)
        {
            var paths = values.Select(Path.GetFullPath).ToList();
            var common = paths[0];
            foreach (var path in paths.Skip(1))
            {
                while (!MediaPath.IsSameOrDescendant(
                           MediaPath.Normalize(path),
                           MediaPath.Normalize(common)))
                {
                    common = Path.GetDirectoryName(common) ?? common;
                }
            }

            return common;
        }
    }

    private sealed record FileSnapshot(long Length, DateTime ModifiedAt);

    private sealed class WatchRegistration(
        FileSystemWatcher watcher,
        FileSystemEventHandler changed,
        RenamedEventHandler renamed,
        ErrorEventHandler error) : IDisposable
    {
        public void Dispose()
        {
            watcher.EnableRaisingEvents = false;
            watcher.Created -= changed;
            watcher.Changed -= changed;
            watcher.Deleted -= changed;
            watcher.Renamed -= renamed;
            watcher.Error -= error;
            watcher.Dispose();
        }
    }
}
