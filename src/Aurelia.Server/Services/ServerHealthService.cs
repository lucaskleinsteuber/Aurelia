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
            recentDiagnostics);
    }

    internal static string SanitizeCode(string code)
    {
        var cleaned = new string(code.Select(c => char.IsAsciiLetterOrDigit(c) ? c : '_').ToArray());
        while (cleaned.Contains("__")) cleaned = cleaned.Replace("__", "_");
        cleaned = cleaned.Trim('_');
        return !string.IsNullOrEmpty(cleaned) ? cleaned : "diagnostic_event";
    }
}
