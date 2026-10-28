using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class ServerHealthService(
    ServerRuntimeOptions runtime,
    AureliaDbContext database,
    ScrubPreviewService scrubPreviews,
    LiveConversionService liveConversions,
    ActiveStreamRegistry streams,
    LibraryScanScheduler scanScheduler,
    MetadataJobScheduler metadataScheduler,
    ServerDiagnosticsStore diagnostics,
    DatabaseBackupService backupService,
    ServerConfigurationStore? configuration = null,
    TimeProvider? timeProvider = null)
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async Task<ServerHealthResponse> GetHealthAsync(CancellationToken token)
    {
        var uptimeSeconds = (DateTimeOffset.UtcNow - System.Diagnostics.Process.GetCurrentProcess().StartTime.ToUniversalTime()).TotalSeconds;
        long? freeBytes = null;
        try { freeBytes = new DriveInfo(runtime.DataDirectory).AvailableFreeSpace; } catch { }
        long dbBytes = 0;
        try { if (File.Exists(runtime.DatabasePath)) dbBytes = new FileInfo(runtime.DatabasePath).Length; } catch { }

        var scrubSettings = await scrubPreviews.ReadSettingsAsync();

        var activeConversions = liveConversions.Running;
        var activeStreams = streams.PlaybackCount;

        var offlineCount = await database.MediaItems.AsNoTracking()
            .CountAsync(item => item.Availability == MediaAvailability.Missing, token);

        var lastScanEntity = await database.LibraryScans.AsNoTracking()
            .OrderByDescending(scan => scan.CompletedAt ?? scan.StartedAt ?? scan.CreatedAt)
            .FirstOrDefaultAsync(token);

        ServerHealthScanSummary? lastScan = null;
        if (lastScanEntity != null)
        {
            var started = lastScanEntity.StartedAt ?? lastScanEntity.CreatedAt;
            var duration = lastScanEntity.CompletedAt.HasValue
                ? (lastScanEntity.CompletedAt.Value - started).TotalSeconds
                : (double?)null;
            lastScan = new ServerHealthScanSummary(
                lastScanEntity.Id,
                lastScanEntity.State.ToString(),
                started,
                lastScanEntity.CompletedAt,
                duration,
                lastScanEntity.AddedFiles,
                lastScanEntity.UpdatedFiles,
                lastScanEntity.MissingFiles,
                lastScanEntity.FailedFiles);
        }

        var backgroundJobs = new ServerHealthBackgroundJobs(
            scanScheduler.ActiveCount,
            metadataScheduler.ActiveCount,
            scrubSettings.PendingCount + scrubSettings.ActiveCount);

        var recentDiagnostics = diagnostics.Read()
            .Where(e => e.Severity is "warning" or "error")
            .Take(20)
            .Select(e => new ServerHealthEvent(e.At, SanitizeCode(e.Code), e.Severity, e.Status))
            .ToList();

        ServerHealthBackupSummary? backupSummary = null;
        try
        {
            var backups = backupService.ListBackups();
            var backupHealth = backupService.Health;
            long totalBackupBytes = 0;
            foreach (var b in backups)
            {
                try { totalBackupBytes += new FileInfo(b.Path).Length; } catch { }
            }
            var daily = backups.Where(b => b.Kind == DatabaseBackupKind.Daily).MaxBy(b => b.CreatedAt);
            var weekly = backups.Where(b => b.Kind == DatabaseBackupKind.Weekly).MaxBy(b => b.CreatedAt);
            backupSummary = new ServerHealthBackupSummary(
                configuration?.Current.AutomaticBackupsEnabled ?? true,
                backupHealth.LastAttemptFailed,
                backupHealth.LastSucceededAt,
                backups.Count,
                totalBackupBytes,
                daily?.CreatedAt,
                weekly?.CreatedAt);
        }
        catch
        {
            // Database backup inspection should not block health reporting
        }

        return new ServerHealthResponse(
            uptimeSeconds,
            freeBytes,
            dbBytes,
            scrubSettings.StoredTitleCount,
            scrubSettings.StoredBytes,
            scrubSettings.PendingCount,
            activeConversions,
            activeStreams,
            offlineCount,
            lastScan,
            backgroundJobs,
            recentDiagnostics,
            backupSummary);
    }

    internal static string SanitizeCode(string code)
    {
        var cleaned = new string(code.Select(c => char.IsAsciiLetterOrDigit(c) ? c : '_').ToArray());
        while (cleaned.Contains("__")) cleaned = cleaned.Replace("__", "_");
        cleaned = cleaned.Trim('_');
        return !string.IsNullOrEmpty(cleaned) ? cleaned : "diagnostic_event";
    }
}
