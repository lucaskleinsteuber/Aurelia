using System.Buffers;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services.FileChecks;

/// <summary>
/// The file watch: reads every title's file in the background, keeps its SHA-256, and lets ffmpeg
/// look at every packet (or decode everything) once per file version. It finds files the drive
/// cannot read, files that are cut off or damaged, and files whose content changed while their
/// size and date stayed the same (bit rot). Only the checksum and the finding are stored; the
/// media file is only ever read. The work holds one conversion place, waits while anyone watches,
/// and does not keep an unused computer awake.
/// </summary>
public sealed partial class FileCheckService : BackgroundService
{
    public const string SettingsFileName = "file-check-settings.json";

    /// <summary>The rhythms the owner can choose for reading every file again, in days; 0 never.</summary>
    public static readonly IReadOnlyList<int> RecheckChoices = [0, 30, 90, 180];

    private const int ReadBlock = 1 << 20;
    private const long YieldEveryBytes = 64L << 20;
    private static readonly TimeSpan StallLimit = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan FailureBackoff = TimeSpan.FromDays(1);
    private static readonly TimeSpan RoundInterval = TimeSpan.FromHours(1);
    private static readonly TimeSpan StatusLifetime = TimeSpan.FromSeconds(5);
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private readonly ServerRuntimeOptions runtime;
    private readonly IServiceScopeFactory scopes;
    private readonly LiveConversionService live;
    private readonly ActiveStreamRegistry streams;
    private readonly LibraryScanScheduler scans;
    private readonly MetadataJobScheduler metadataJobs;
    private readonly ILogger<FileCheckService> logger;
    private readonly TimeProvider clock;
    private readonly string settingsPath;
    private readonly object settingsGate = new();
    private readonly SemaphoreSlim workSignal = new(0, int.MaxValue);
    private readonly SemaphoreSlim processing = new(1, 1);
    private readonly ConcurrentQueue<Guid> requested = new();
    private readonly ConcurrentDictionary<Guid, DateTimeOffset> failed = new();

    private StoredSettings settings;
    private int running;
    private int pausedForPlayback;
    private Activity? activity;
    private double? bytesPerSecond;
    private (DateTimeOffset At, Counts Counts)? status;

    private sealed record StoredSettings(bool Enabled = false, FileCheckDepth Depth = FileCheckDepth.Container, int RecheckDays = 90);

    private sealed record Activity(string Title, string Step, double Fraction);

    private sealed record Counts(int Total, int Checked, int Pending, int Problems, long PendingBytes, DateTimeOffset? LastCheckedAt);

    private sealed record CheckRow(long Size, long ModifiedMilliseconds, FileCheckDepth Depth, FileCheckState State, DateTimeOffset VerifiedAt, bool Ignored);

    private sealed record FileRow(Guid Id, long Size, long ModifiedMilliseconds, CheckRow? Check);

    private sealed record ReadResult(byte[]? Hash, long? FailedAt);

    /// <summary>A file to examine: in full (a new or changed version) or only by reading it again.</summary>
    public sealed record Work(Guid MediaId, bool VerifyOnly, long Bytes);

    /// <summary>Raised when an ffmpeg run had to end because someone started watching and it could not be held still.</summary>
    private sealed class RunInterruptedException : Exception;

    public FileCheckService(
        ServerRuntimeOptions runtime,
        IServiceScopeFactory scopes,
        LiveConversionService live,
        ActiveStreamRegistry streams,
        LibraryScanScheduler scans,
        MetadataJobScheduler metadataJobs,
        ILogger<FileCheckService> logger,
        TimeProvider? clock = null)
    {
        this.runtime = runtime;
        this.scopes = scopes;
        this.live = live;
        this.streams = streams;
        this.scans = scans;
        this.metadataJobs = metadataJobs;
        this.logger = logger;
        this.clock = clock ?? TimeProvider.System;
        settingsPath = Path.Combine(runtime.DataDirectory, SettingsFileName);
        settings = LoadSettings();
    }

    public override void Dispose()
    {
        base.Dispose();
        workSignal.Dispose();
        processing.Dispose();
    }

    public bool IsEnabled
    {
        get { lock (settingsGate) return settings.Enabled; }
    }

    private StoredSettings Current
    {
        get { lock (settingsGate) return settings; }
    }

    /// <summary>Hook after a library scan: new and changed files are examined.</summary>
    public void NotifyScanCompleted()
    {
        status = null;
        if (IsEnabled) Signal();
    }

    public async Task<FileCheckSettingsResponse> ReadSettingsAsync(CancellationToken cancellationToken)
    {
        var tools = await live.ToolsAsync();
        var current = Current;
        var counts = await CountsAsync(tools, cancellationToken);
        var active = Volatile.Read(ref running) > 0;
        var now = activity;
        int? estimate = bytesPerSecond is > 0 and var rate && counts.PendingBytes > 0
            ? (int)Math.Min(int.MaxValue, Math.Ceiling(counts.PendingBytes / rate))
            : null;
        return new FileCheckSettingsResponse(
            current.Enabled,
            current.Depth,
            current.RecheckDays,
            tools is not null,
            counts.Total,
            counts.Checked,
            current.Enabled ? counts.Pending : counts.Total - counts.Checked,
            counts.Problems,
            active,
            Volatile.Read(ref pausedForPlayback) > 0,
            active ? now?.Title : null,
            active ? now?.Step : null,
            active ? now?.Fraction : null,
            current.Enabled ? estimate : null,
            counts.LastCheckedAt);
    }

    public async Task<FileCheckSettingsResponse> UpdateSettingsAsync(UpdateFileCheckSettingsRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.RecheckDays is { } days && !RecheckChoices.Contains(days))
            throw new AccountException("invalid_recheck_days", "Choose never, 30, 90 or 180 days.", 400);
        if (request.Depth is { } depth && !Enum.IsDefined(depth))
            throw new AccountException("invalid_depth", "Choose Read, Container or Decode.", 400);
        StoredSettings updated;
        lock (settingsGate)
        {
            updated = new StoredSettings(request.Enabled, request.Depth ?? settings.Depth, request.RecheckDays ?? settings.RecheckDays);
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
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        status = null;
        if (updated.Enabled) Signal();
        return await ReadSettingsAsync(cancellationToken);
    }

    /// <summary>
    /// Examines one title again from the start: its finding and checksum are replaced, so a file
    /// that was repaired or replaced from a backup becomes the new reference.
    /// </summary>
    public async Task RecheckAsync(Guid mediaId, CancellationToken cancellationToken)
    {
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        if (!await database.MediaItems.IgnoreQueryFilters().AnyAsync(item => item.Id == mediaId && item.Kind != MediaKind.Series, cancellationToken))
            throw new AccountException("item_not_found", "The title was not found.", StatusCodes.Status404NotFound);
        await database.MediaFileChecks.IgnoreQueryFilters().Where(check => check.MediaItemId == mediaId).ExecuteDeleteAsync(cancellationToken);
        failed.TryRemove(mediaId, out _);
        status = null;
        requested.Enqueue(mediaId);
        Signal();
    }

    /// <summary>Sets a problem aside (or back): it stays listed under Set Aside and out of the count.</summary>
    public async Task SetIgnoredAsync(Guid mediaId, bool ignored, CancellationToken cancellationToken)
    {
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var changed = await database.MediaFileChecks.IgnoreQueryFilters()
            .Where(check => check.MediaItemId == mediaId && check.State != FileCheckState.Ok)
            .ExecuteUpdateAsync(update => update.SetProperty(check => check.Ignored, ignored), cancellationToken);
        if (changed == 0)
            throw new AccountException("problem_not_found", "This title has no problem to set aside.", StatusCodes.Status404NotFound);
        status = null;
    }

    /// <summary>Files with a finding other than Ok in their current version: open problems, or the ones set aside.</summary>
    public async Task<IReadOnlyList<FileProblemSummary>> ProblemsAsync(bool ignored, int offset, int limit, CancellationToken cancellationToken)
    {
        offset = Math.Max(0, offset);
        limit = Math.Clamp(limit, 1, 100);
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var rows = await database.MediaFileChecks.IgnoreQueryFilters().AsNoTracking()
            .Where(check => check.State != FileCheckState.Ok && check.Ignored == ignored)
            .Include(check => check.MediaItem).ThenInclude(item => item.Metadata)
            .Include(check => check.MediaItem).ThenInclude(item => item.Parent).ThenInclude(parent => parent!.Metadata)
            .Include(check => check.MediaItem).ThenInclude(item => item.LibraryRoot)
            .ToListAsync(cancellationToken);
        return rows
            .Where(row => row.MediaItem.Availability == MediaAvailability.Available && IsCurrent(row, row.MediaItem.FileSize, row.MediaItem.FileModifiedAt))
            .OrderBy(row => Severity(row.State)).ThenByDescending(row => row.CheckedAt).ThenBy(row => row.MediaItemId)
            .Skip(offset).Take(limit)
            .Select(row => new FileProblemSummary(
                row.MediaItemId,
                Label(row.MediaItem),
                row.MediaItem.Kind,
                Path.GetFileName(row.MediaItem.SourcePath),
                row.MediaItem.LibraryRoot.Name,
                row.State,
                row.ErrorCount,
                row.ProblemAtMilliseconds / 1000.0,
                row.DurationMilliseconds / 1000.0,
                row.Detail,
                row.Depth,
                row.CheckedAt,
                row.Ignored))
            .ToList();
    }

    private static int Severity(FileCheckState state) => state switch
    {
        FileCheckState.Unreadable => 0,
        FileCheckState.ChangedUnexpectedly => 1,
        FileCheckState.Damaged => 2,
        _ => 3,
    };

    /// <summary>How many open problems there are, for Server Health.</summary>
    public async Task<int> ProblemCountAsync(CancellationToken cancellationToken) =>
        (await CountsAsync(await live.ToolsAsync(), cancellationToken)).Problems;

    /// <summary>The files to examine now: new and changed versions first, then the ones whose checksum is due.</summary>
    public async Task<IReadOnlyList<Work>> PlanAsync(CancellationToken cancellationToken)
    {
        var tools = await live.ToolsAsync();
        var current = Current;
        var wanted = Wanted(current, tools);
        var now = clock.GetUtcNow();
        var files = await LoadAsync(cancellationToken);
        var unseen = new List<Work>();
        var changed = new List<Work>();
        var verify = new List<(Work Work, DateTimeOffset VerifiedAt)>();
        foreach (var file in files)
        {
            if (failed.TryGetValue(file.Id, out var failedAt) && now - failedAt < FailureBackoff) continue;
            if (NeedsFull(file, wanted)) (file.Check is null ? unseen : changed).Add(new Work(file.Id, false, file.Size));
            else if (NeedsVerify(file, current, now)) verify.Add((new Work(file.Id, true, file.Size), file.Check!.VerifiedAt));
        }
        return [.. unseen, .. changed, .. verify.OrderBy(entry => entry.VerifiedAt).Select(entry => entry.Work)];
    }

    /// <summary>Examines every file that needs it now; the background loop and tests call this. Returns how many were examined.</summary>
    public async Task<int> ProcessPendingAsync(CancellationToken cancellationToken)
    {
        await processing.WaitAsync(cancellationToken);
        try
        {
            var examined = 0;
            var plan = new Queue<Work>(await PlanAsync(cancellationToken));
            var done = new HashSet<Guid>();
            while (IsEnabled)
            {
                Work? next = null;
                if (requested.TryDequeue(out var asked)) next = new Work(asked, false, 0);
                else if (plan.TryDequeue(out var planned)) next = planned;
                if (next is null) break;
                // A title asked for again is examined once, not again where the plan also has it.
                if (!done.Add(next.MediaId)) continue;
                cancellationToken.ThrowIfCancellationRequested();
                await WaitWhileLibraryBusyAsync(cancellationToken);
                Interlocked.Increment(ref running);
                try
                {
                    if (await CheckAsync(next.MediaId, next.VerifyOnly, cancellationToken)) examined++;
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    failed[next.MediaId] = clock.GetUtcNow();
                    LogCheckFailed(logger, next.MediaId, exception);
                }
                finally
                {
                    Interlocked.Decrement(ref running);
                    activity = null;
                    status = null;
                }
            }
            return examined;
        }
        finally
        {
            processing.Release();
        }
    }

    /// <summary>
    /// Examines one file. Returns false when nothing was decided: the file is missing, changed
    /// while it was read, or the examination had to stop.
    /// </summary>
    public async Task<bool> CheckAsync(Guid mediaId, bool verifyOnly, CancellationToken cancellationToken)
    {
        MediaItem? media;
        MediaFileCheck? existing;
        await using (var scope = scopes.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            media = await database.MediaItems.IgnoreQueryFilters().AsNoTracking()
                .Include(item => item.LibraryRoot)
                .Include(item => item.Metadata)
                .Include(item => item.Parent).ThenInclude(parent => parent!.Metadata)
                .SingleOrDefaultAsync(item => item.Id == mediaId, cancellationToken);
            existing = await database.MediaFileChecks.IgnoreQueryFilters().AsNoTracking()
                .SingleOrDefaultAsync(check => check.MediaItemId == mediaId, cancellationToken);
        }
        if (media is not { FileSize: { } size, FileModifiedAt: { } modified, Availability: MediaAvailability.Available }
            || media.Kind == MediaKind.Series) return false;

        var tools = await live.ToolsAsync();
        var current = Current;
        var wanted = Wanted(current, tools);
        var sameVersion = existing is not null && existing.FileSize == size && SameTime(existing.FileModifiedAt, modified);
        if (!sameVersion || existing!.State == FileCheckState.Unreadable) verifyOnly = false;
        var label = Label(media);

        OpenMediaFile file;
        try
        {
            file = MediaFileAccess.OpenRead(media);
        }
        catch (PlaybackException)
        {
            return false;
        }
        await using var stream = file.Stream;
        // The catalog describes another version: the next scan updates it, then it is examined.
        if (file.Length != size || !SameTime(file.LastModified, modified)) return false;
        var checkedPath = Path.GetFullPath(media.SourcePath);

        double? duration = sameVersion && existing!.DurationMilliseconds is { } known ? known / 1000.0 : null;
        if (duration is null && tools is not null)
        {
            try
            {
                duration = (await live.ProbeAsync(tools, file, checkedPath, media.Id, cancellationToken)).DurationSeconds;
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                // A file ffprobe cannot read is examined all the same; ffmpeg's look will say why.
                LogProbeFailed(logger, media.Id, exception);
            }
        }

        var started = clock.GetTimestamp();
        using var hold = new Hold(this);
        await hold.EnterAsync(cancellationToken);
        activity = new Activity(label, verifyOnly ? "Reading again and comparing" : "Reading every byte", 0);
        var read = await ReadAllAsync(stream, file.Length, hold, label, verifyOnly, cancellationToken);
        if (read is null || !StillTheSame(checkedPath, file)) return false;

        FileFinding finding;
        var hash = read.Hash;
        var depth = verifyOnly ? existing!.Depth : wanted;
        if (read.FailedAt is { } offset)
        {
            finding = FileCheckRules.Unreadable(offset, file.Length, duration, null);
            hash = sameVersion ? existing!.Sha256 : null;
        }
        else if (sameVersion && existing!.Sha256 is { Length: > 0 } reference && !CryptographicOperations.FixedTimeEquals(reference, hash))
        {
            // The reference stays: a later look compares against the file as it was first seen.
            finding = FileCheckRules.ChangedUnexpectedly();
            hash = reference;
        }
        else if (verifyOnly)
        {
            finding = new FileFinding(existing!.State, existing.ErrorCount, existing.ProblemAtMilliseconds / 1000.0, existing.Detail);
        }
        else if (wanted >= FileCheckDepth.Container && tools is not null)
        {
            var inspected = await InspectAsync(tools, stream, checkedPath, wanted, duration, label, hold, cancellationToken);
            if (inspected is null || !StillTheSame(checkedPath, file)) return false;
            finding = inspected;
        }
        else
        {
            finding = new FileFinding(FileCheckState.Ok, 0, null, null);
        }

        var seconds = clock.GetElapsedTime(started).TotalSeconds;
        if (!verifyOnly && seconds > 1 && file.Length > 0)
        {
            var rate = file.Length / seconds;
            bytesPerSecond = bytesPerSecond is { } average ? average * 0.7 + rate * 0.3 : rate;
        }
        await SaveAsync(media, existing, sameVersion, file, hash, depth, finding, duration, verifyOnly, cancellationToken);
        return true;
    }

    private async Task SaveAsync(MediaItem media, MediaFileCheck? existing, bool sameVersion, OpenMediaFile file, byte[]? hash,
        FileCheckDepth depth, FileFinding finding, double? duration, bool verifyOnly, CancellationToken cancellationToken)
    {
        var now = clock.GetUtcNow();
        await using (var scope = scopes.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var row = await database.MediaFileChecks.IgnoreQueryFilters().SingleOrDefaultAsync(check => check.MediaItemId == media.Id, cancellationToken);
            if (row is null)
            {
                row = new MediaFileCheck { MediaItemId = media.Id };
                database.MediaFileChecks.Add(row);
            }
            row.FileSize = file.Length;
            row.FileModifiedAt = file.LastModified;
            row.Sha256 = hash;
            row.Depth = depth;
            row.State = finding.State;
            row.ErrorCount = finding.ErrorCount;
            row.ProblemAtMilliseconds = finding.ProblemAtSeconds is { } at ? (long)Math.Round(at * 1000) : null;
            row.DurationMilliseconds = duration is { } length ? (long)Math.Round(length * 1000) : null;
            row.Detail = finding.Detail is { Length: > 1024 } detail ? detail[..1024] : finding.Detail;
            // A problem set aside stays aside while it is the same problem in the same file.
            row.Ignored = sameVersion && existing!.Ignored && existing.State == finding.State;
            row.CheckedAt = verifyOnly && existing is not null ? existing.CheckedAt : now;
            row.VerifiedAt = now;
            try
            {
                await database.SaveChangesAsync(cancellationToken);
            }
            catch (DbUpdateException)
            {
                // The title was removed while its file was read; there is nothing to keep.
                return;
            }

            var isNew = !sameVersion || existing!.State != finding.State;
            if (isNew && finding.State is FileCheckState.Damaged or FileCheckState.Unreadable or FileCheckState.ChangedUnexpectedly)
            {
                LogProblem(logger, media.Id, finding.State);
            }
        }
        status = null;
    }

    /// <summary>Reads the whole file once and returns its SHA-256, or where the drive could not read it.</summary>
    private async Task<ReadResult?> ReadAllAsync(FileStream stream, long length, Hold hold, string label, bool verifyOnly, CancellationToken cancellationToken)
    {
        var buffer = ArrayPool<byte>.Shared.Rent(ReadBlock);
        try
        {
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            stream.Seek(0, SeekOrigin.Begin);
            long offset = 0;
            long sinceYield = 0;
            while (true)
            {
                int count;
                try
                {
                    count = await stream.ReadAsync(buffer.AsMemory(0, ReadBlock), cancellationToken);
                }
                catch (IOException)
                {
                    return new ReadResult(null, offset);
                }
                if (count == 0) break;
                hash.AppendData(buffer, 0, count);
                offset += count;
                sinceYield += count;
                if (sinceYield >= YieldEveryBytes)
                {
                    sinceYield = 0;
                    var fraction = length > 0 ? Math.Clamp((double)offset / length, 0, 1) : 0;
                    activity = new Activity(label, verifyOnly ? "Reading again and comparing" : "Reading every byte", verifyOnly ? fraction : fraction / 2);
                    await hold.YieldIfBusyAsync(null, cancellationToken);
                }
            }
            // A file that grew or shrank while it was read is examined again in its new version.
            return offset == length ? new ReadResult(hash.GetHashAndReset(), null) : null;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    /// <summary>Lets ffmpeg read every packet, or decode everything; with the chip first and the processor again for a problem.</summary>
    private async Task<FileFinding?> InspectAsync(FfmpegTools tools, FileStream stream, string checkedPath, FileCheckDepth depth,
        double? duration, string label, Hold hold, CancellationToken cancellationToken)
    {
        var input = LiveConversionService.InputPath(stream, checkedPath);
        var chip = depth == FileCheckDepth.Decode ? ChipArguments(tools) : [];
        var finding = await RunAsync(tools, input, checkedPath, depth, chip, duration, label, hold, cancellationToken);
        // A decoder on a chip can stumble over what the processor reads fine; only the processor's word counts.
        if (finding is { State: not FileCheckState.Ok } && chip.Count > 0)
            finding = await RunAsync(tools, input, checkedPath, depth, [], duration, label, hold, cancellationToken);
        return finding;
    }

    /// <summary>ffmpeg's arguments for a look at a file: every packet copied to nothing, or everything decoded.</summary>
    public static IReadOnlyList<string> Arguments(string input, FileCheckDepth depth, IReadOnlyList<string> chip)
    {
        ArgumentNullException.ThrowIfNull(chip);
        List<string> arguments = ["-hide_banner", "-nostdin", "-nostats", "-v", "error", "-progress", "pipe:2", "-stats_period", "0.5"];
        arguments.AddRange(chip);
        arguments.AddRange(["-i", input]);
        arguments.AddRange(depth == FileCheckDepth.Decode
            ? ["-map", "0:v:0?", "-map", "0:a?", "-sn", "-dn"]
            : ["-map", "0:v?", "-map", "0:a?", "-map", "0:s?", "-c", "copy"]);
        arguments.AddRange(["-f", "null", "-"]);
        return arguments;
    }

    private static List<string> ChipArguments(FfmpegTools tools) => tools switch
    {
        { Hardware: { Decodes: true } chip } => [.. HardwareEncoding.DeviceArguments(chip, decode: true)],
        { Encoder: LiveVideoEncoder.VideoToolbox } => ["-hwaccel", "videotoolbox"],
        _ => [],
    };

    private async Task<FileFinding?> RunAsync(FfmpegTools tools, string input, string checkedPath, FileCheckDepth depth,
        IReadOnlyList<string> chip, double? duration, string label, Hold hold, CancellationToken cancellationToken)
    {
        var step = depth == FileCheckDepth.Decode ? "Decoding picture and sound" : "Reading every packet";
        activity = new Activity(label, step, 0.5);
        using var process = live.Start(tools.Ffmpeg, Arguments(input, depth, chip), lowPriority: true);
        try { process.PriorityClass = ProcessPriorityClass.Idle; }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        var output = new FfmpegCheckOutput(input);
        var lines = ReadLinesAsync(process.StandardError, output, checkedPath);
        try
        {
            var lastProgress = output.ProgressLines;
            var lastMove = clock.GetTimestamp();
            while (!process.HasExited)
            {
                using (var tick = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
                {
                    tick.CancelAfter(TimeSpan.FromSeconds(2));
                    try { await process.WaitForExitAsync(tick.Token); }
                    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { }
                }
                if (process.HasExited) break;
                if (duration is > 0 and var length)
                    activity = new Activity(label, step, 0.5 + Math.Clamp(output.Seconds / length, 0, 1) / 2);
                bool paused;
                try
                {
                    paused = await hold.YieldIfBusyAsync(process, cancellationToken);
                }
                catch (RunInterruptedException)
                {
                    return null;
                }
                if (paused || output.ProgressLines != lastProgress)
                {
                    lastProgress = output.ProgressLines;
                    lastMove = clock.GetTimestamp();
                }
                else if (clock.GetElapsedTime(lastMove) > StallLimit)
                {
                    LogStalled(logger);
                    throw new TimeoutException("ffmpeg stopped moving while examining a file.");
                }
            }
            await lines;
            return FileCheckRules.Inspect(output, process.ExitCode, duration);
        }
        finally
        {
            if (!process.HasExited) LiveConversionService.Stop(process);
        }
    }

    private static async Task ReadLinesAsync(StreamReader reader, FfmpegCheckOutput output, string checkedPath)
    {
        try
        {
            while (await reader.ReadLineAsync() is { } line)
            {
                output.Add(line.Length > 1024 ? line[..1024] : line.Replace(checkedPath, "the file", StringComparison.Ordinal));
            }
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException) { }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            // Let the server finish starting and the other background work begin first.
            await Task.Delay(TimeSpan.FromSeconds(90), stoppingToken);
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    if (IsEnabled)
                    {
                        using (ServerWorkSignal.Begin(scopes, keepAwake: false)) await ProcessPendingAsync(stoppingToken);
                    }
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    LogLoopFailed(logger, exception);
                    await Task.Delay(TimeSpan.FromMinutes(1), stoppingToken);
                }
                // Due checksums come round by the hour; a scan, a recheck or a setting wakes the loop sooner.
                await workSignal.WaitAsync(RoundInterval, stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    private void Signal()
    {
        try { workSignal.Release(); }
        catch (SemaphoreFullException) { }
        catch (ObjectDisposedException) { }
    }

    private bool IsBusy(int ownConversions) => streams.PlaybackCount > 0 || live.Running > ownConversions;

    private async Task WaitWhileBusyAsync(int ownConversions, CancellationToken cancellationToken)
    {
        if (!IsBusy(ownConversions)) return;
        Interlocked.Increment(ref pausedForPlayback);
        try
        {
            while (IsBusy(ownConversions))
            {
                cancellationToken.ThrowIfCancellationRequested();
                await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
            }
        }
        finally
        {
            Interlocked.Decrement(ref pausedForPlayback);
        }
    }

    /// <summary>A library scan or metadata job reads the same drives and finishes first.</summary>
    private async Task WaitWhileLibraryBusyAsync(CancellationToken cancellationToken)
    {
        while (scans.ActiveCount > 0 || metadataJobs.ActiveCount > 0)
        {
            await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken);
        }
    }

    /// <summary>
    /// The conversion place a check holds while it reads, so other background work waits instead
    /// of reading the same drive at the same time. It is given back while anyone watches.
    /// </summary>
    private sealed class Hold(FileCheckService owner) : IDisposable
    {
        private IDisposable? slot;

        public async Task EnterAsync(CancellationToken cancellationToken)
        {
            while (slot is null)
            {
                await owner.WaitWhileBusyAsync(0, cancellationToken);
                slot = await owner.live.EnterAsync(encodesVideo: false, cancellationToken);
            }
        }

        /// <summary>Waits while anyone watches, holding a running ffmpeg still. Returns whether it waited.</summary>
        public async Task<bool> YieldIfBusyAsync(Process? ffmpeg, CancellationToken cancellationToken)
        {
            if (!owner.IsBusy(slot is null ? 0 : 1)) return false;
            var suspended = false;
            if (ffmpeg is not null)
            {
                suspended = ProcessPause.Suspend(ffmpeg);
                if (!suspended) throw new RunInterruptedException();
            }
            slot?.Dispose();
            slot = null;
            try
            {
                await EnterAsync(cancellationToken);
            }
            finally
            {
                if (suspended) ProcessPause.Resume(ffmpeg!);
            }
            return true;
        }

        public void Dispose()
        {
            slot?.Dispose();
            slot = null;
        }
    }

    private async Task<Counts> CountsAsync(FfmpegTools? tools, CancellationToken cancellationToken)
    {
        if (status is { } cached && clock.GetUtcNow() - cached.At < StatusLifetime) return cached.Counts;
        var current = Current;
        var wanted = Wanted(current, tools);
        var now = clock.GetUtcNow();
        var files = await LoadAsync(cancellationToken);
        var checkedCount = 0;
        var pending = 0;
        var problems = 0;
        long pendingBytes = 0;
        DateTimeOffset? last = null;
        foreach (var file in files)
        {
            var full = NeedsFull(file, wanted);
            if (!full && file.Check is not null) checkedCount++;
            if (full || NeedsVerify(file, current, now))
            {
                pending++;
                pendingBytes += file.Size;
            }
            if (file.Check is { } check && IsCurrent(check, file))
            {
                if (!check.Ignored && check.State is FileCheckState.Damaged or FileCheckState.Unreadable or FileCheckState.ChangedUnexpectedly) problems++;
                if (last is null || check.VerifiedAt > last) last = check.VerifiedAt;
            }
        }
        var counts = new Counts(files.Count, checkedCount, pending, problems, pendingBytes, last);
        status = (now, counts);
        return counts;
    }

    private async Task<List<FileRow>> LoadAsync(CancellationToken cancellationToken)
    {
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var items = await database.MediaItems.IgnoreQueryFilters().AsNoTracking()
            .Where(item => item.Kind != MediaKind.Series && item.Availability == MediaAvailability.Available && item.FileSize != null)
            .Select(item => new { item.Id, item.FileSize, item.FileModifiedAt })
            .ToListAsync(cancellationToken);
        var checks = await database.MediaFileChecks.IgnoreQueryFilters().AsNoTracking()
            .Select(check => new { check.MediaItemId, check.FileSize, check.FileModifiedAt, check.Depth, check.State, check.VerifiedAt, check.Ignored })
            .ToDictionaryAsync(check => check.MediaItemId, cancellationToken);
        return [.. items.Where(item => item.FileModifiedAt is not null).Select(item => new FileRow(
            item.Id,
            item.FileSize!.Value,
            item.FileModifiedAt!.Value.ToUnixTimeMilliseconds(),
            checks.TryGetValue(item.Id, out var check)
                ? new CheckRow(check.FileSize, check.FileModifiedAt.ToUnixTimeMilliseconds(), check.Depth, check.State, check.VerifiedAt, check.Ignored)
                : null))];
    }

    /// <summary>The depth a new file gets: the chosen one, or only reading where there is no ffmpeg.</summary>
    private static FileCheckDepth Wanted(StoredSettings settings, FfmpegTools? tools) => tools is null ? FileCheckDepth.Read : settings.Depth;

    private static bool IsCurrent(CheckRow check, FileRow file) =>
        check.Size == file.Size && check.ModifiedMilliseconds == file.ModifiedMilliseconds;

    private static bool IsCurrent(MediaFileCheck check, long? size, DateTimeOffset? modified) =>
        size == check.FileSize && modified is { } value && SameTime(value, check.FileModifiedAt);

    private static bool NeedsFull(FileRow file, FileCheckDepth wanted) =>
        file.Check is not { } check || !IsCurrent(check, file) || check.Depth < wanted;

    private static bool NeedsVerify(FileRow file, StoredSettings settings, DateTimeOffset now) =>
        settings.RecheckDays > 0 && file.Check is { } check && IsCurrent(check, file)
        && check.State != FileCheckState.ChangedUnexpectedly
        && now - check.VerifiedAt >= TimeSpan.FromDays(settings.RecheckDays);

    private static bool SameTime(DateTimeOffset first, DateTimeOffset second) =>
        first.ToUnixTimeMilliseconds() == second.ToUnixTimeMilliseconds();

    /// <summary>Whether the file at the path is still the one that was opened: same size and date.</summary>
    private static bool StillTheSame(string path, OpenMediaFile file)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists && info.Length == file.Length
                && SameTime(new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero), file.LastModified);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>"Title" for a movie, "Series · S01E02" for an episode.</summary>
    private static string Label(MediaItem item)
    {
        var title = MetadataPresentation.ToSummary(item).Title;
        return item.Kind == MediaKind.Episode && item.Parent is { } parent
            ? $"{MetadataPresentation.ToSummary(parent).Title} · S{item.SeasonNumber ?? 0:00}E{item.EpisodeNumber ?? 0:00}"
            : title;
    }

    private StoredSettings LoadSettings()
    {
        try
        {
            if (!File.Exists(settingsPath)) return new StoredSettings();
            using var file = File.OpenRead(settingsPath);
            var stored = JsonSerializer.Deserialize<StoredSettings>(file, Json) ?? new StoredSettings();
            return stored with
            {
                Depth = Enum.IsDefined(stored.Depth) ? stored.Depth : FileCheckDepth.Container,
                RecheckDays = RecheckChoices.Contains(stored.RecheckDays) ? stored.RecheckDays : 90,
            };
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException)
        {
            LogSettingsUnreadable(logger, exception);
            return new StoredSettings();
        }
    }

    [LoggerMessage(LogLevel.Warning, "The file watch could not examine title {MediaId}; it tries again tomorrow")]
    private static partial void LogCheckFailed(ILogger logger, Guid mediaId, Exception exception);

    [LoggerMessage(LogLevel.Debug, "The file watch could not read the header of title {MediaId}")]
    private static partial void LogProbeFailed(ILogger logger, Guid mediaId, Exception exception);

    [LoggerMessage(LogLevel.Warning, "The file watch found a problem in title {MediaId}: {State}")]
    private static partial void LogProblem(ILogger logger, Guid mediaId, FileCheckState state);

    [LoggerMessage(LogLevel.Warning, "ffmpeg stopped moving while the file watch examined a file; it was ended")]
    private static partial void LogStalled(ILogger logger);

    [LoggerMessage(LogLevel.Warning, "The file watch stopped unexpectedly and starts again in a minute")]
    private static partial void LogLoopFailed(ILogger logger, Exception exception);

    [LoggerMessage(LogLevel.Warning, "The file watch settings could not be read; it stays off")]
    private static partial void LogSettingsUnreadable(ILogger logger, Exception exception);
}
