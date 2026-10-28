using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Extracts small timeline preview JPEG stills with ffmpeg and, when enabled by the server owner,
/// keeps one compact strip file per title in the server's data folder (`ScrubPreviews`).
/// Converted video is never stored: ffmpeg writes only single JPEG stills to standard output.
/// Background strip preparation runs one frame at a time at low priority and pauses whenever
/// anyone is streaming or converting live.
/// </summary>
public sealed class ScrubPreviewService : BackgroundService
{
    public const string SettingsFileName = "scrub-preview-settings.json";
    public const string DirectoryName = "ScrubPreviews";
    public const int DefaultIntervalSeconds = 15;
    public const int MinimumIntervalSeconds = 5;
    public const int MaximumIntervalSeconds = 120;
    public const int DefaultStorageCapMegabytes = 500;
    public const int MinimumStorageCapMegabytes = 50;
    public const int MaximumStorageCapMegabytes = 10_240;
    public const int MaximumStripFrames = 720;
    public const int MaximumFrameBytes = 256 * 1024;
    public const int MemoryFrameLimit = 240;
    public const int MaximumMemoryBytes = 16 * 1024 * 1024;
    public static readonly IReadOnlyList<string> Modes = ["off", "onOpenOrPlay", "afterImport"];

    private static readonly ReadOnlyMemory<byte> StripMagic = "AUSTPV01"u8.ToArray();
    private static readonly TimeSpan FrameTimeout = TimeSpan.FromSeconds(15);
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private readonly ServerRuntimeOptions runtime;
    private readonly IServiceScopeFactory scopes;
    private readonly LiveConversionService live;
    private readonly ActiveStreamRegistry streams;
    private readonly TimeProvider clock;
    private readonly string settingsPath;
    private readonly string stripsDirectory;
    private readonly object settingsGate = new();
    private readonly object cacheGate = new();
    private readonly SemaphoreSlim extractionGate = new(1, 1);
    private readonly SemaphoreSlim workSignal = new(0, int.MaxValue);
    private readonly ConcurrentQueue<Guid> priorityQueue = new();
    private readonly ConcurrentQueue<Guid> importQueue = new();
    private readonly ConcurrentDictionary<Guid, byte> queuedIds = new();

    private StoredSettings settings;
    private int modeCode; // 0 = off, 1 = onOpenOrPlay, 2 = afterImport
    private int generationEpoch;
    private int activeGenerating;
    private int pausedForPlayback;
    private int completedCount;
    private int totalScheduledCount;

    // Bounded in-memory LRU for on-demand and recently generated frames.
    private readonly Dictionary<string, LinkedListNode<MemoryEntry>> memoryNodes = new(StringComparer.Ordinal);
    private readonly LinkedList<MemoryEntry> memoryOrder = new();
    private readonly Dictionary<Guid, (long Length, long ModifiedTicks)> mediaStamps = [];
    private int memoryBytes;

    private sealed record StoredSettings(string Mode, int IntervalSeconds, int StorageCapMegabytes);
    private sealed record MemoryEntry(string Key, Guid MediaId, long FileSize, long ModifiedTicks, int IntervalSeconds, int BucketSeconds, byte[] Data);
    internal sealed record StripHeader(Guid MediaId, long FileSize, long ModifiedTicks, int IntervalSeconds, int DurationSeconds, IReadOnlyList<(int Seconds, int Offset, int Length)> Index);
    public sealed record FrameResult(byte[] Data, DateTimeOffset LastModified, string EntityTag);

    public ScrubPreviewService(
        ServerRuntimeOptions runtime,
        IServiceScopeFactory scopes,
        LiveConversionService live,
        ActiveStreamRegistry streams,
        TimeProvider? clock = null)
    {
        this.runtime = runtime;
        this.scopes = scopes;
        this.live = live;
        this.streams = streams;
        this.clock = clock ?? TimeProvider.System;
        settingsPath = Path.Combine(runtime.DataDirectory, SettingsFileName);
        stripsDirectory = Path.Combine(runtime.DataDirectory, DirectoryName);
        settings = LoadSettings();
        Volatile.Write(ref modeCode, ModeToCode(settings.Mode));
    }

    public override void Dispose()
    {
        base.Dispose();
        extractionGate.Dispose();
        workSignal.Dispose();
    }

    public bool IsPersistingMode => Volatile.Read(ref modeCode) != 0;

    /// <summary>Fast-path hook when a title page is opened or playback starts.</summary>
    public void NotifyTitleOpened(Guid mediaId)
    {
        if (Volatile.Read(ref modeCode) == 0) return;
        EnqueuePriority(mediaId);
    }

    /// <summary>Hook after a library scan finishes; only queues work in "afterImport" mode.</summary>
    public void NotifyScanCompleted()
    {
        if (Volatile.Read(ref modeCode) != 2) return;
        SignalWork();
    }

    public void EnqueuePriority(Guid mediaId)
    {
        if (Volatile.Read(ref modeCode) == 0) return;
        if (queuedIds.TryAdd(mediaId, 1))
        {
            Interlocked.Increment(ref totalScheduledCount);
            priorityQueue.Enqueue(mediaId);
            SignalWork();
        }
    }

    public async Task<ScrubPreviewSettingsResponse> ReadSettingsAsync()
    {
        StoredSettings current;
        lock (settingsGate) current = settings;
        var (usedBytes, stripCount) = MeasureDiskUsage();
        var available = await live.IsAvailableAsync();
        var active = Math.Max(0, Volatile.Read(ref activeGenerating));
        var pending = queuedIds.Count;
        var completed = Math.Max(0, Volatile.Read(ref completedCount));
        var total = Math.Max(completed + pending + active, Volatile.Read(ref totalScheduledCount));
        return new ScrubPreviewSettingsResponse(
            available,
            current.Mode,
            current.IntervalSeconds,
            current.StorageCapMegabytes,
            stripCount,
            usedBytes,
            active,
            pending,
            completed,
            total,
            Volatile.Read(ref pausedForPlayback) > 0 || ((pending > 0 || active > 0) && IsBusyWithPlayback()));
    }

    public async Task<ScrubPreviewSettingsResponse> UpdateSettingsAsync(UpdateScrubPreviewSettingsRequest request, CancellationToken token = default)
    {
        if (!Modes.Contains(request.Mode))
            throw new AccountException("invalid_scrub_preview_mode", "Choose off, onOpenOrPlay or afterImport.", 400);
        if (request.IntervalSeconds is < MinimumIntervalSeconds or > MaximumIntervalSeconds)
            throw new AccountException("invalid_scrub_preview_interval", $"Choose an interval between {MinimumIntervalSeconds} and {MaximumIntervalSeconds} seconds.", 400);
        if (request.StorageCapMegabytes is < MinimumStorageCapMegabytes or > MaximumStorageCapMegabytes)
            throw new AccountException("invalid_scrub_preview_cap", $"Choose a storage cap between {MinimumStorageCapMegabytes} and {MaximumStorageCapMegabytes} MB.", 400);

        var updated = new StoredSettings(request.Mode, request.IntervalSeconds, request.StorageCapMegabytes);
        lock (settingsGate)
        {
            PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
            var temporary = settingsPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporary))
                {
                    JsonSerializer.Serialize(file, updated, Json);
                    file.Flush(flushToDisk: true);
                }
                File.Move(temporary, settingsPath, overwrite: true);
                PrivateFilePermissions.ProtectFile(settingsPath);
                settings = updated;
                Volatile.Write(ref modeCode, ModeToCode(updated.Mode));
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }

        PruneDiskToCap((long)updated.StorageCapMegabytes * 1024 * 1024, requiredBytes: 0);
        if (updated.Mode == "off")
        {
            ClearQueues();
        }
        else if (updated.Mode == "afterImport")
        {
            await QueueUncachedLibraryTitlesAsync(token);
        }
        return await ReadSettingsAsync();
    }

    public async Task<ScrubPreviewSettingsResponse> DeleteAllPreviewsAsync()
    {
        Interlocked.Increment(ref generationEpoch);
        ClearQueues();
        lock (cacheGate)
        {
            memoryNodes.Clear();
            memoryOrder.Clear();
            mediaStamps.Clear();
            memoryBytes = 0;
        }
        if (Directory.Exists(stripsDirectory) && new DirectoryInfo(stripsDirectory).LinkTarget is null)
        {
            foreach (var path in Directory.EnumerateFiles(stripsDirectory))
            {
                try { File.Delete(path); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            }
        }
        return await ReadSettingsAsync();
    }

    /// <summary>
    /// Describes the scrub preview interval and any ready buckets for a playable title, and
    /// triggers background strip generation when configured.
    /// </summary>
    public async Task<ScrubPreviewManifestResponse> GetManifestAsync(
        MediaItem media,
        CancellationToken cancellationToken)
    {
        StoredSettings current;
        lock (settingsGate) current = settings;
        var tools = await live.ToolsAsync();
        if (tools is null)
        {
            return new ScrubPreviewManifestResponse(false, current.Mode, current.IntervalSeconds, 0, [], "unavailable");
        }

        OpenMediaFile file;
        try
        {
            file = MediaFileAccess.OpenRead(media);
        }
        catch (PlaybackException)
        {
            InvalidateMedia(media.Id);
            throw;
        }

        await using var stream = file.Stream;
        var modifiedTicks = file.LastModified.UtcTicks;
        EnsureFreshStamp(media.Id, file.Length, modifiedTicks, current.IntervalSeconds);

        if (ReadStripHeader(media.Id, file.Length, modifiedTicks, current.IntervalSeconds) is { } strip)
        {
            var revision = $"{file.Length:x}-{modifiedTicks:x}-i{current.IntervalSeconds}-r{strip.Index.Count}";
            return new ScrubPreviewManifestResponse(
                true,
                current.Mode,
                current.IntervalSeconds,
                strip.DurationSeconds,
                strip.Index.Select(entry => entry.Seconds).ToArray(),
                revision);
        }

        var probe = await live.ProbeAsync(tools, file, Path.GetFullPath(media.SourcePath), media.Id, cancellationToken);
        var durationSeconds = Math.Max(0, (int)Math.Round(probe.DurationSeconds ?? 0));
        var interval = EffectiveInterval(durationSeconds, current.IntervalSeconds);
        var ready = GetMemoryReadySeconds(media.Id, file.Length, modifiedTicks, interval);
        if (current.Mode != "off" && durationSeconds > 0)
            EnqueuePriority(media.Id);
        var liveRevision = $"{file.Length:x}-{modifiedTicks:x}-i{interval}-r{ready.Length}";
        return new ScrubPreviewManifestResponse(true, current.Mode, interval, durationSeconds, ready, liveRevision);
    }

    /// <summary>
    /// Returns one JPEG scrub preview frame for <paramref name="media"/> at <paramref name="requestedSeconds"/>,
    /// serving from memory or the stored strip when available and extracting on demand with ffmpeg otherwise.
    /// </summary>
    public async Task<FrameResult?> GetFrameAsync(
        MediaItem media,
        int requestedSeconds,
        CancellationToken cancellationToken)
    {
        if (await live.ToolsAsync() is not { } tools)
            throw new PlaybackException("conversion_unavailable", "This server can’t extract timeline previews.", StatusCodes.Status409Conflict);

        OpenMediaFile file;
        try
        {
            file = MediaFileAccess.OpenRead(media);
        }
        catch (PlaybackException)
        {
            InvalidateMedia(media.Id);
            throw;
        }

        await using var stream = file.Stream;
        var modifiedTicks = file.LastModified.UtcTicks;
        int configuredInterval;
        string mode;
        lock (settingsGate)
        {
            configuredInterval = settings.IntervalSeconds;
            mode = settings.Mode;
        }

        EnsureFreshStamp(media.Id, file.Length, modifiedTicks, configuredInterval);

        // 1. Check if a stored strip on disk already has this frame.
        if (ReadStripHeader(media.Id, file.Length, modifiedTicks, configuredInterval) is { } strip && strip.Index.Count > 0)
        {
            var bucket = NormalizeBucket(requestedSeconds, strip.IntervalSeconds, strip.DurationSeconds);
            var match = strip.Index.FirstOrDefault(entry => entry.Seconds == bucket);
            if (match.Length == 0)
                match = strip.Index.OrderBy(entry => Math.Abs(entry.Seconds - bucket)).First();
            if (ReadStripFrameBytes(media.Id, file.Length, modifiedTicks, configuredInterval, match.Offset, match.Length) is { } stripBytes)
            {
                CacheInMemory(media.Id, file.Length, modifiedTicks, strip.IntervalSeconds, match.Seconds, stripBytes);
                return new FrameResult(
                    stripBytes,
                    file.LastModified,
                    FrameEntityTag(media.Id, file.Length, modifiedTicks, strip.IntervalSeconds, match.Seconds));
            }
        }

        var probe = await live.ProbeAsync(tools, file, Path.GetFullPath(media.SourcePath), media.Id, cancellationToken);
        if (probe.Video is not { } video) return null;
        var durationSeconds = Math.Max(1, (int)Math.Round(probe.DurationSeconds ?? 1));
        var interval = EffectiveInterval(durationSeconds, configuredInterval);
        var normalizedBucket = NormalizeBucket(requestedSeconds, interval, durationSeconds);

        // 2. Check the bounded in-memory LRU cache.
        if (TryGetFromMemory(media.Id, file.Length, modifiedTicks, interval, normalizedBucket, out var cachedBytes))
        {
            if (mode != "off") EnqueuePriority(media.Id);
            return new FrameResult(
                cachedBytes,
                file.LastModified,
                FrameEntityTag(media.Id, file.Length, modifiedTicks, interval, normalizedBucket));
        }

        // 3. Extract the single requested frame on demand (1 at a time, low priority, stdout only).
        var seekSeconds = SnapshotSecond(normalizedBucket, interval, durationSeconds);
        var checkedPath = Path.GetFullPath(media.SourcePath);
        var extracted = await ExtractSingleFrameAsync(tools, file.Stream, checkedPath, seekSeconds, video.Index, cancellationToken);
        if (extracted is null) return null;

        CacheInMemory(media.Id, file.Length, modifiedTicks, interval, normalizedBucket, extracted);
        if (mode != "off") EnqueuePriority(media.Id);
        return new FrameResult(
            extracted,
            file.LastModified,
            FrameEntityTag(media.Id, file.Length, modifiedTicks, interval, normalizedBucket));
    }

    public static string FrameEntityTag(Guid mediaId, long fileSize, long modifiedTicks, int intervalSeconds, int bucketSeconds) =>
        $"\"sp-{mediaId:N}-{fileSize:x}-{modifiedTicks:x}-i{intervalSeconds}-b{bucketSeconds}-v1\"";

    public static int EffectiveInterval(int durationSeconds, int configuredIntervalSeconds)
    {
        var baseInterval = Math.Clamp(configuredIntervalSeconds, MinimumIntervalSeconds, MaximumIntervalSeconds);
        if (durationSeconds <= 0) return baseInterval;
        var minimumForCap = (durationSeconds + MaximumStripFrames - 1) / MaximumStripFrames;
        return Math.Max(baseInterval, minimumForCap);
    }

    public static int NormalizeBucket(int requestedSeconds, int intervalSeconds, int durationSeconds)
    {
        var step = Math.Max(1, intervalSeconds);
        var clamped = durationSeconds > 0 ? Math.Clamp(requestedSeconds, 0, Math.Max(0, durationSeconds - 1)) : Math.Max(0, requestedSeconds);
        return (clamped / step) * step;
    }

    public static double SnapshotSecond(int bucketSeconds, int intervalSeconds, int durationSeconds)
    {
        if (durationSeconds <= 1) return 0;
        var middle = bucketSeconds + intervalSeconds / 2.0;
        var endMargin = Math.Min(2.0, durationSeconds * 0.1);
        return Math.Max(0, Math.Min(middle, durationSeconds - endMargin));
    }

    /// <summary>
    /// ffmpeg arguments for extracting one low-resolution JPEG frame to stdout without writing
    /// anything to disk. Uses single-threaded keyframe seeking before input for minimum CPU cost.
    /// </summary>
    public static IReadOnlyList<string> FrameArguments(string input, double seconds, int videoStreamIndex = 0, bool fastSeek = true)
    {
        var arguments = new List<string>
        {
            "-hide_banner", "-nostdin", "-loglevel", "error", "-protocol_whitelist", "file",
            "-threads", "1",
        };
        if (seconds > 0)
        {
            arguments.AddRange(["-ss", seconds.ToString("0.###", CultureInfo.InvariantCulture)]);
            if (fastSeek) arguments.Add("-noaccurate_seek");
        }
        arguments.AddRange([
            "-i", "file:" + input,
            "-map", $"0:{videoStreamIndex}",
            "-frames:v", "1",
            "-vf", "scale=320:-2:flags=fast_bilinear",
            "-c:v", "mjpeg",
            "-q:v", "6",
            "-f", "image2",
            "pipe:1",
        ]);
        return arguments;
    }

    /// <summary>
    /// Generates and stores the full scrub-preview strip for <paramref name="mediaId"/> when a
    /// persisting mode ("onOpenOrPlay" or "afterImport") is active. Pauses while playback or live
    /// conversion is active.
    /// </summary>
    public async Task<bool> GenerateTitleStripAsync(Guid mediaId, TimeSpan framePause, CancellationToken cancellationToken)
    {
        StoredSettings current;
        lock (settingsGate) current = settings;
        if (current.Mode == "off") return false;
        if (await live.ToolsAsync() is not { } tools) return false;

        var epoch = Volatile.Read(ref generationEpoch);
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var media = await database.MediaItems
            .IgnoreQueryFilters()
            .AsNoTracking()
            .Include(item => item.LibraryRoot)
            .SingleOrDefaultAsync(item => item.Id == mediaId, cancellationToken);
        if (media is null || media.Kind == MediaKind.Series)
        {
            InvalidateMedia(mediaId);
            return false;
        }

        OpenMediaFile file;
        try
        {
            file = MediaFileAccess.OpenRead(media);
        }
        catch (PlaybackException)
        {
            InvalidateMedia(mediaId);
            return false;
        }

        await using var stream = file.Stream;
        var modifiedTicks = file.LastModified.UtcTicks;
        EnsureFreshStamp(media.Id, file.Length, modifiedTicks, current.IntervalSeconds);

        if (HasStripOnDisk(media.Id, file.Length, modifiedTicks, current.IntervalSeconds))
            return true;

        var checkedPath = Path.GetFullPath(media.SourcePath);
        MediaProbeResult probe;
        try
        {
            probe = await live.ProbeAsync(tools, file, checkedPath, media.Id, cancellationToken);
        }
        catch (PlaybackException)
        {
            return false;
        }

        if (probe.Video is not { } video) return false;
        var durationSeconds = Math.Max(1, (int)Math.Round(probe.DurationSeconds ?? 1));
        var interval = EffectiveInterval(durationSeconds, current.IntervalSeconds);
        var buckets = new List<int>();
        for (var second = 0; second < durationSeconds && buckets.Count < MaximumStripFrames; second += interval)
            buckets.Add(second);
        if (buckets.Count == 0) buckets.Add(0);

        var frames = new List<(int Seconds, byte[] Data)>(buckets.Count);
        Interlocked.Increment(ref activeGenerating);
        try
        {
            foreach (var bucket in buckets)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (Volatile.Read(ref generationEpoch) != epoch || Volatile.Read(ref modeCode) == 0)
                    return false;

                await WaitWhilePlaybackBusyAsync(cancellationToken);

                if (TryGetFromMemory(media.Id, file.Length, modifiedTicks, interval, bucket, out var existing))
                {
                    frames.Add((bucket, existing));
                    continue;
                }

                var seekSeconds = SnapshotSecond(bucket, interval, durationSeconds);
                var data = await ExtractSingleFrameAsync(tools, stream, checkedPath, seekSeconds, video.Index, cancellationToken, idlePriority: true);
                if (data is not null)
                {
                    CacheInMemory(media.Id, file.Length, modifiedTicks, interval, bucket, data);
                    frames.Add((bucket, data));
                }

                if (framePause > TimeSpan.Zero)
                    await Task.Delay(framePause, cancellationToken);
            }

            if (frames.Count == 0 || Volatile.Read(ref generationEpoch) != epoch || Volatile.Read(ref modeCode) == 0)
                return false;

            // Verify the source file was not modified or removed while frames were being extracted.
            var latestInfo = new FileInfo(checkedPath);
            if (!latestInfo.Exists || latestInfo.Length != file.Length || latestInfo.LastWriteTimeUtc.Ticks != modifiedTicks)
            {
                InvalidateMedia(media.Id);
                return false;
            }

            await WriteStripFileAsync(
                media.Id,
                file.Length,
                modifiedTicks,
                 current.IntervalSeconds,
                interval,
                durationSeconds,
                frames,
                (long)current.StorageCapMegabytes * 1024 * 1024,
                cancellationToken);
            return true;
        }
        finally
        {
            Interlocked.Decrement(ref activeGenerating);
        }
    }

    /// <summary>Processes all currently queued titles; used by tests and background loop.</summary>
    public async Task<int> ProcessPendingQueueAsync(TimeSpan framePause, CancellationToken cancellationToken)
    {
        var processed = 0;
        while (TryDequeueNext(out var mediaId))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (Volatile.Read(ref modeCode) == 0) break;
            if (await GenerateTitleStripAsync(mediaId, framePause, cancellationToken))
            {
                Interlocked.Increment(ref completedCount);
                processed++;
            }
        }
        return processed;
    }

    public async Task<int> QueueUncachedLibraryTitlesAsync(CancellationToken cancellationToken)
    {
        StoredSettings current;
        lock (settingsGate) current = settings;
        if (current.Mode != "afterImport") return 0;

        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        // Slowest / largest files first when idle, as specified in Part B.
        var candidates = await database.MediaItems
            .IgnoreQueryFilters()
            .AsNoTracking()
            .Where(item => item.Kind != MediaKind.Series && item.Availability == MediaAvailability.Available)
            .OrderByDescending(item => item.FileSize)
            .ThenBy(item => item.Id)
            .Select(item => new { item.Id, item.FileSize, item.FileModifiedAt })
            .Take(2_000)
            .ToListAsync(cancellationToken);

        var added = 0;
        foreach (var candidate in candidates)
        {
            if (candidate.FileSize is not > 0 || candidate.FileModifiedAt is not { } modifiedAt)
                continue;
            if (HasStripOnDisk(candidate.Id, candidate.FileSize.Value, modifiedAt.UtcTicks, current.IntervalSeconds))
                continue;
            if (queuedIds.TryAdd(candidate.Id, 1))
            {
                Interlocked.Increment(ref totalScheduledCount);
                importQueue.Enqueue(candidate.Id);
                added++;
            }
        }
        if (added > 0) SignalWork();
        return added;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            if (Volatile.Read(ref modeCode) == 2)
                await QueueUncachedLibraryTitlesAsync(stoppingToken);

            while (!stoppingToken.IsCancellationRequested)
            {
                await workSignal.WaitAsync(stoppingToken);
                if (Volatile.Read(ref modeCode) == 2 && priorityQueue.IsEmpty && importQueue.IsEmpty)
                    await QueueUncachedLibraryTitlesAsync(stoppingToken);
                await ProcessPendingQueueAsync(TimeSpan.FromMilliseconds(25), stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    private bool IsBusyWithPlayback() => streams.PlaybackCount > 0 || live.Running > 0;

    private async Task WaitWhilePlaybackBusyAsync(CancellationToken cancellationToken)
    {
        if (!IsBusyWithPlayback()) return;
        Interlocked.Increment(ref pausedForPlayback);
        try
        {
            while (IsBusyWithPlayback())
            {
                cancellationToken.ThrowIfCancellationRequested();
                await Task.Delay(TimeSpan.FromMilliseconds(250), cancellationToken);
            }
        }
        finally
        {
            Interlocked.Decrement(ref pausedForPlayback);
        }
    }

    private async Task<byte[]?> ExtractSingleFrameAsync(
        FfmpegTools tools,
        FileStream sourceStream,
        string checkedPath,
        double seconds,
        int videoStreamIndex,
        CancellationToken cancellationToken,
        bool idlePriority = false)
    {
        await extractionGate.WaitAsync(cancellationToken);
        try
        {
            var input = LiveConversionService.InputPath(sourceStream, checkedPath);
            var frame = await RunFfmpegFrameAsync(tools.Ffmpeg, FrameArguments(input, seconds, videoStreamIndex, fastSeek: true), idlePriority, cancellationToken);
            if (frame is null && seconds > 0)
            {
                // Near the end of a short container without a trailing keyframe, fall back to 0s.
                frame = await RunFfmpegFrameAsync(tools.Ffmpeg, FrameArguments(input, 0, videoStreamIndex, fastSeek: false), idlePriority, cancellationToken);
            }
            if (frame is not null)
            {
                LiveConversionService.EnsureInputMatchesHandle(sourceStream.SafeFileHandle, checkedPath);
            }
            return frame;
        }
        finally
        {
            extractionGate.Release();
        }
    }

    private async Task<byte[]?> RunFfmpegFrameAsync(
        string ffmpeg,
        IReadOnlyList<string> arguments,
        bool idlePriority,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(FrameTimeout);
        using var process = live.Start(ffmpeg, arguments, lowPriority: true);
        if (idlePriority)
        {
            try { process.PriorityClass = ProcessPriorityClass.Idle; }
            catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
        var errors = LiveConversionService.ReadTailAsync(process.StandardError);
        using var stopOnAbort = timeout.Token.Register(() => LiveConversionService.Kill(process));
        try
        {
            var output = await LiveConversionService.ReadLimitedAsync(process.StandardOutput.BaseStream, MaximumFrameBytes, timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            _ = await errors;
            if (process.ExitCode == 0 && IsJpegStill(output))
                return output;
            return null;
        }
        catch (InvalidDataException)
        {
            return null;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        finally
        {
            LiveConversionService.Stop(process);
        }
    }

    public static bool IsJpegStill(ReadOnlySpan<byte> bytes) =>
        bytes.Length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8;

    private void EnsureFreshStamp(Guid mediaId, long fileSize, long modifiedTicks, int configuredInterval)
    {
        var expectedStem = StripStem(mediaId, fileSize, modifiedTicks, configuredInterval);
        DeleteStaleStripFiles(mediaId, keepStem: expectedStem);
        lock (cacheGate)
        {
            if (mediaStamps.TryGetValue(mediaId, out var previous) && (previous.Length != fileSize || previous.ModifiedTicks != modifiedTicks))
            {
                EvictMemoryForMediaLocked(mediaId);
            }
            mediaStamps[mediaId] = (fileSize, modifiedTicks);
        }
    }

    public void InvalidateMedia(Guid mediaId)
    {
        DeleteStaleStripFiles(mediaId, keepStem: null);
        lock (cacheGate)
        {
            mediaStamps.Remove(mediaId);
            EvictMemoryForMediaLocked(mediaId);
        }
    }

    private void EvictMemoryForMediaLocked(Guid mediaId)
    {
        var node = memoryOrder.First;
        while (node is not null)
        {
            var next = node.Next;
            if (node.Value.MediaId == mediaId)
            {
                memoryNodes.Remove(node.Value.Key);
                memoryOrder.Remove(node);
                memoryBytes -= node.Value.Data.Length;
            }
            node = next;
        }
    }

    private void CacheInMemory(Guid mediaId, long fileSize, long modifiedTicks, int intervalSeconds, int bucketSeconds, byte[] data)
    {
        if (data.Length is <= 0 or > MaximumMemoryBytes) return;
        var key = MemoryKey(mediaId, fileSize, modifiedTicks, intervalSeconds, bucketSeconds);
        lock (cacheGate)
        {
            if (memoryNodes.TryGetValue(key, out var existing))
            {
                memoryBytes -= existing.Value.Data.Length;
                memoryOrder.Remove(existing);
                memoryNodes.Remove(key);
            }
            while ((memoryNodes.Count >= MemoryFrameLimit || memoryBytes + data.Length > MaximumMemoryBytes) && memoryOrder.Last is { } oldest)
            {
                memoryNodes.Remove(oldest.Value.Key);
                memoryOrder.RemoveLast();
                memoryBytes -= oldest.Value.Data.Length;
            }
            var entry = new MemoryEntry(key, mediaId, fileSize, modifiedTicks, intervalSeconds, bucketSeconds, data);
            var node = new LinkedListNode<MemoryEntry>(entry);
            memoryOrder.AddFirst(node);
            memoryNodes[key] = node;
            memoryBytes += data.Length;
        }
    }

    private bool TryGetFromMemory(Guid mediaId, long fileSize, long modifiedTicks, int intervalSeconds, int bucketSeconds, out byte[] data)
    {
        var key = MemoryKey(mediaId, fileSize, modifiedTicks, intervalSeconds, bucketSeconds);
        lock (cacheGate)
        {
            if (memoryNodes.TryGetValue(key, out var node))
            {
                memoryOrder.Remove(node);
                memoryOrder.AddFirst(node);
                data = node.Value.Data;
                return true;
            }
        }
        data = [];
        return false;
    }

    private int[] GetMemoryReadySeconds(Guid mediaId, long fileSize, long modifiedTicks, int intervalSeconds)
    {
        lock (cacheGate)
        {
            return memoryOrder
                .Where(entry => entry.MediaId == mediaId && entry.FileSize == fileSize && entry.ModifiedTicks == modifiedTicks && entry.IntervalSeconds == intervalSeconds)
                .Select(entry => entry.BucketSeconds)
                .OrderBy(seconds => seconds)
                .ToArray();
        }
    }

    private static string MemoryKey(Guid mediaId, long fileSize, long modifiedTicks, int intervalSeconds, int bucketSeconds) =>
        $"{mediaId:N}:{fileSize:x}:{modifiedTicks:x}:{intervalSeconds}:{bucketSeconds}";

    private static string StripStem(Guid mediaId, long fileSize, long modifiedTicks, int configuredInterval) =>
        $"{mediaId:N}-s{fileSize:x}-m{modifiedTicks:x}-i{configuredInterval}-v1";

    private string StripPath(string stem) => Path.Combine(stripsDirectory, stem + ".strip");

    private bool HasStripOnDisk(Guid mediaId, long fileSize, long modifiedTicks, int configuredInterval)
    {
        if (!Directory.Exists(stripsDirectory)) return false;
        var info = new FileInfo(StripPath(StripStem(mediaId, fileSize, modifiedTicks, configuredInterval)));
        return info.Exists && info.LinkTarget is null && info.Length >= 48;
    }

    private void DeleteStaleStripFiles(Guid mediaId, string? keepStem)
    {
        if (!Directory.Exists(stripsDirectory)) return;
        if (new DirectoryInfo(stripsDirectory).LinkTarget is not null) return;
        var prefix = $"{mediaId:N}-";
        var keepFile = keepStem is null ? null : keepStem + ".strip";
        foreach (var path in Directory.EnumerateFiles(stripsDirectory, prefix + "*"))
        {
            if (keepFile is not null && string.Equals(Path.GetFileName(path), keepFile, StringComparison.Ordinal))
                continue;
            try { File.Delete(path); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
    }

    internal StripHeader? ReadStripHeader(Guid mediaId, long fileSize, long modifiedTicks, int configuredInterval)
    {
        if (!Directory.Exists(stripsDirectory)) return null;
        if (new DirectoryInfo(stripsDirectory).LinkTarget is not null) return null;
        var path = StripPath(StripStem(mediaId, fileSize, modifiedTicks, configuredInterval));
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.LinkTarget is not null || info.Length < 48) return null;
            using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            Span<byte> header = stackalloc byte[48];
            if (stream.ReadAtLeast(header, header.Length, throwOnEndOfStream: false) < header.Length) return null;
            if (!header[..8].SequenceEqual(StripMagic.Span)) return null;
            var storedMediaId = new Guid(header.Slice(8, 16));
            var storedSize = BinaryPrimitives.ReadInt64LittleEndian(header.Slice(24, 8));
            var storedModified = BinaryPrimitives.ReadInt64LittleEndian(header.Slice(32, 8));
            var intervalSeconds = BinaryPrimitives.ReadInt32LittleEndian(header.Slice(40, 4));
            var durationSeconds = BinaryPrimitives.ReadInt32LittleEndian(header.Slice(44, 4));
            Span<byte> countBytes = stackalloc byte[4];
            if (stream.ReadAtLeast(countBytes, 4, throwOnEndOfStream: false) < 4) return null;
            var frameCount = BinaryPrimitives.ReadInt32LittleEndian(countBytes);
            if (storedMediaId != mediaId || storedSize != fileSize || storedModified != modifiedTicks
                || frameCount is < 0 or > MaximumStripFrames)
                return null;
            var indexBytes = new byte[frameCount * 12];
            if (stream.ReadAtLeast(indexBytes, indexBytes.Length, throwOnEndOfStream: false) < indexBytes.Length)
                return null;
            var index = new List<(int Seconds, int Offset, int Length)>(frameCount);
            for (var i = 0; i < frameCount; i++)
            {
                var slice = indexBytes.AsSpan(i * 12, 12);
                var seconds = BinaryPrimitives.ReadInt32LittleEndian(slice[..4]);
                var offset = BinaryPrimitives.ReadInt32LittleEndian(slice.Slice(4, 4));
                var length = BinaryPrimitives.ReadInt32LittleEndian(slice.Slice(8, 4));
                if (offset < 52 + indexBytes.Length || length <= 0 || offset + (long)length > info.Length)
                    return null;
                index.Add((seconds, offset, length));
            }
            return new StripHeader(storedMediaId, storedSize, storedModified, intervalSeconds, durationSeconds, index);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private byte[]? ReadStripFrameBytes(Guid mediaId, long fileSize, long modifiedTicks, int configuredInterval, int offset, int length)
    {
        var path = StripPath(StripStem(mediaId, fileSize, modifiedTicks, configuredInterval));
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.LinkTarget is not null || offset + (long)length > info.Length) return null;
            using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            stream.Position = offset;
            var buffer = new byte[length];
            if (stream.ReadAtLeast(buffer, length, throwOnEndOfStream: false) < length) return null;
            if (!IsJpegStill(buffer)) return null;
            var now = clock.GetUtcNow().UtcDateTime;
            if (info.LastWriteTimeUtc < now.AddMinutes(-15))
            {
                try { File.SetLastWriteTimeUtc(path, now); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            }
            return buffer;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private async Task WriteStripFileAsync(
        Guid mediaId,
        long fileSize,
        long modifiedTicks,
        int configuredInterval,
        int effectiveInterval,
        int durationSeconds,
        List<(int Seconds, byte[] Data)> frames,
        long capBytes,
        CancellationToken cancellationToken)
    {
        var headerLength = 52 + frames.Count * 12;
        var totalPayload = frames.Sum(frame => frame.Data.Length);
        var totalLength = headerLength + totalPayload;
        if (totalLength > capBytes) return;

        var buffer = new byte[totalLength];
        StripMagic.Span.CopyTo(buffer.AsSpan(0, 8));
        mediaId.TryWriteBytes(buffer.AsSpan(8, 16));
        BinaryPrimitives.WriteInt64LittleEndian(buffer.AsSpan(24, 8), fileSize);
        BinaryPrimitives.WriteInt64LittleEndian(buffer.AsSpan(32, 8), modifiedTicks);
        BinaryPrimitives.WriteInt32LittleEndian(buffer.AsSpan(40, 4), effectiveInterval);
        BinaryPrimitives.WriteInt32LittleEndian(buffer.AsSpan(44, 4), durationSeconds);
        BinaryPrimitives.WriteInt32LittleEndian(buffer.AsSpan(48, 4), frames.Count);

        var payloadOffset = headerLength;
        for (var i = 0; i < frames.Count; i++)
        {
            var (seconds, data) = frames[i];
            var entrySpan = buffer.AsSpan(52 + i * 12, 12);
            BinaryPrimitives.WriteInt32LittleEndian(entrySpan[..4], seconds);
            BinaryPrimitives.WriteInt32LittleEndian(entrySpan.Slice(4, 4), payloadOffset);
            BinaryPrimitives.WriteInt32LittleEndian(entrySpan.Slice(8, 4), data.Length);
            data.CopyTo(buffer.AsSpan(payloadOffset, data.Length));
            payloadOffset += data.Length;
        }

        PrivateFilePermissions.CreatePrivateDirectory(stripsDirectory);
        if (new DirectoryInfo(stripsDirectory).LinkTarget is not null) return;
        var stem = StripStem(mediaId, fileSize, modifiedTicks, configuredInterval);
        DeleteStaleStripFiles(mediaId, keepStem: stem);
        PruneDiskToCap(capBytes, buffer.LongLength);

        var destination = StripPath(stem);
        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".pending";
        try
        {
            await using (var output = PrivateFilePermissions.OpenNewPrivateFile(temporary))
            {
                await output.WriteAsync(buffer, cancellationToken);
                await output.FlushAsync(cancellationToken);
            }
            File.Move(temporary, destination, overwrite: true);
            PrivateFilePermissions.ProtectFile(destination);
            File.SetLastWriteTimeUtc(destination, clock.GetUtcNow().UtcDateTime);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private (long UsedBytes, int StripCount) MeasureDiskUsage()
    {
        if (!Directory.Exists(stripsDirectory)) return (0, 0);
        if (new DirectoryInfo(stripsDirectory).LinkTarget is not null) return (0, 0);
        long bytes = 0;
        var count = 0;
        foreach (var path in Directory.EnumerateFiles(stripsDirectory, "*.strip"))
        {
            try
            {
                var info = new FileInfo(path);
                if (!info.Exists || info.LinkTarget is not null) continue;
                bytes += info.Length;
                count++;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
        return (bytes, count);
    }

    private void PruneDiskToCap(long capBytes, long requiredBytes)
    {
        if (!Directory.Exists(stripsDirectory)) return;
        if (new DirectoryInfo(stripsDirectory).LinkTarget is not null) return;
        var files = Directory.EnumerateFiles(stripsDirectory)
            .Select(path => new FileInfo(path))
            .Where(file => file.Exists && file.LinkTarget is null)
            .OrderBy(file => file.LastWriteTimeUtc)
            .ThenBy(file => file.Name, StringComparer.Ordinal)
            .ToList();
        var usedBytes = files.Where(file => file.Extension == ".strip").Sum(file => file.Length);
        foreach (var file in files)
        {
            if (file.Extension == ".pending" || usedBytes + requiredBytes > capBytes)
            {
                var length = file.Extension == ".strip" ? file.Length : 0;
                try
                {
                    file.Delete();
                    usedBytes = Math.Max(0, usedBytes - length);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            }
        }
    }

    private StoredSettings LoadSettings()
    {
        try
        {
            var info = new FileInfo(settingsPath);
            if (!info.Exists || info.LinkTarget is not null || info.Length > 4096)
                return new StoredSettings("off", DefaultIntervalSeconds, DefaultStorageCapMegabytes);
            using var stream = File.OpenRead(settingsPath);
            var loaded = JsonSerializer.Deserialize<StoredSettings>(stream, Json);
            if (loaded is null || !Modes.Contains(loaded.Mode)
                || loaded.IntervalSeconds is < MinimumIntervalSeconds or > MaximumIntervalSeconds
                || loaded.StorageCapMegabytes is < MinimumStorageCapMegabytes or > MaximumStorageCapMegabytes)
                return new StoredSettings("off", DefaultIntervalSeconds, DefaultStorageCapMegabytes);
            return loaded;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return new StoredSettings("off", DefaultIntervalSeconds, DefaultStorageCapMegabytes);
        }
    }

    private bool TryDequeueNext(out Guid mediaId)
    {
        while (priorityQueue.TryDequeue(out mediaId))
        {
            if (queuedIds.TryRemove(mediaId, out _)) return true;
        }
        while (importQueue.TryDequeue(out mediaId))
        {
            if (queuedIds.TryRemove(mediaId, out _)) return true;
        }
        mediaId = Guid.Empty;
        return false;
    }

    private void ClearQueues()
    {
        while (priorityQueue.TryDequeue(out _)) { }
        while (importQueue.TryDequeue(out _)) { }
        queuedIds.Clear();
        Interlocked.Exchange(ref completedCount, 0);
        Interlocked.Exchange(ref totalScheduledCount, 0);
    }

    private void SignalWork()
    {
        try { workSignal.Release(); }
        catch (SemaphoreFullException) { }
    }

    private static int ModeToCode(string mode) => mode switch
    {
        "onOpenOrPlay" => 1,
        "afterImport" => 2,
        _ => 0,
    };
}
