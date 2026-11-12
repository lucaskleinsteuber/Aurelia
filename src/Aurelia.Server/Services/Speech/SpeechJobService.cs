using System.Collections.Concurrent;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services.Speech;

/// <summary>
/// Subtitles from speech and Sync to Speech on the server ("server-speech-v1"): one title at a
/// time in the background, at low priority, pausing while anyone watches. A sound track is read
/// as 16 kHz mono by ffmpeg and handed to the recognizer in stretches of about ten minutes cut at
/// a quiet moment; sound and words exist only in memory. Only the finished subtitles are stored,
/// beside the downloaded ones (from speech, or a "Synced" copy of the moved track).
/// </summary>
public sealed partial class SpeechJobService : BackgroundService
{
    /// <summary>Stretches handed to the recognizer: ten minutes, cut at the quietest moment of the next thirty seconds.</summary>
    public const int ChunkSeconds = 600;
    public const int CutSearchSeconds = 30;
    private const int Rate = LiveSpeechAudio.SampleRate;

    private readonly IServiceScopeFactory scopes;
    private readonly LiveConversionService live;
    private readonly ActiveStreamRegistry streams;
    private readonly SubtitleDownloadService subtitles;
    private readonly DownloadedSubtitleStore downloads;
    private readonly SpeechModelStore models;
    private readonly ISpeechRecognizer recognizer;
    private readonly ILogger<SpeechJobService> logger;
    private readonly ConcurrentDictionary<Guid, Job> jobs = new();
    private readonly ConcurrentQueue<Guid> queue = new();
    private readonly SemaphoreSlim signal = new(0, int.MaxValue);

    public SpeechJobService(IServiceScopeFactory scopes, LiveConversionService live, ActiveStreamRegistry streams,
        SubtitleDownloadService subtitles, DownloadedSubtitleStore downloads, SpeechModelStore models, ISpeechRecognizer recognizer,
        ILogger<SpeechJobService> logger)
    {
        this.scopes = scopes;
        this.live = live;
        this.streams = streams;
        this.subtitles = subtitles;
        this.downloads = downloads;
        this.models = models;
        this.recognizer = recognizer;
        this.logger = logger;
    }

    private sealed class Job(Guid mediaId, string title, StartSpeechJobRequest request)
    {
        public Guid MediaId { get; } = mediaId;
        public string Title { get; } = title;
        public StartSpeechJobRequest Request { get; } = request;
        public CancellationTokenSource Cancellation { get; } = new();
        public SpeechJobState State { get; set; } = SpeechJobState.Waiting;
        public double Progress { get; set; }
        public bool Paused { get; set; }
        public string? Message { get; set; }
        public Guid? SubtitleId { get; set; }

        public SpeechJobStatus Status() => new(MediaId, Title, Request.Kind, Request.Language, Request.SubtitleIndex, State,
            Math.Clamp(Progress, 0, 1), Paused, Message, SubtitleId);

        public bool Finished => State is SpeechJobState.Done or SpeechJobState.AlreadyInSync or SpeechJobState.Failed or SpeechJobState.Cancelled;
    }

    public bool Available => recognizer.Available;

    public bool ModelReady => models.Current is not null;

    public IReadOnlyList<SpeechJobStatus> Jobs => [.. jobs.Values.Select(job => job.Status()).OrderBy(job => job.Title, StringComparer.CurrentCulture)];

    public SpeechJobStatus? Status(Guid mediaId) => jobs.TryGetValue(mediaId, out var job) ? job.Status() : null;

    /// <summary>Queues a job for a movie or an episode; a finished one of the same title is replaced.</summary>
    public async Task<SpeechJobStatus> StartAsync(Guid mediaId, StartSpeechJobRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!recognizer.Available)
            throw new MetadataException("speech_unavailable", "Speech recognition (whisper.cpp) isn't installed on this server.", StatusCodes.Status409Conflict);
        if (models.Current is null)
            throw new MetadataException("speech_model_missing", "Download a speech model in the server settings first.", StatusCodes.Status409Conflict);
        if (!SidecarSubtitles.TryParseLanguage(request.Language.Trim(), out var language))
            throw new MetadataException("invalid_subtitle_language", "Choose the language that is spoken.", StatusCodes.Status400BadRequest);
        if (request.Kind == SpeechJobKind.Sync && request.SubtitleIndex is null)
            throw new MetadataException("subtitle_track_required", "Choose the subtitles to sync.", StatusCodes.Status400BadRequest);
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var media = await database.MediaItems.AsNoTracking().Include(item => item.Metadata).Include(item => item.Parent).ThenInclude(parent => parent!.Metadata)
            .FirstOrDefaultAsync(item => item.Id == mediaId, cancellationToken)
            ?? throw new MetadataException("media_not_found", "The title was not found.", StatusCodes.Status404NotFound);
        if (media.Kind is not (MediaKind.Movie or MediaKind.Episode))
            throw new MetadataException("speech_not_playable", "Subtitles from speech are made for a movie or an episode.", StatusCodes.Status400BadRequest);
        if (jobs.TryGetValue(mediaId, out var running) && !running.Finished)
            throw new MetadataException("speech_job_running", "The server is already listening to this title.", StatusCodes.Status409Conflict);
        var job = new Job(mediaId, Describe(media), request with { Language = language });
        jobs[mediaId] = job;
        queue.Enqueue(mediaId);
        signal.Release();
        return job.Status();
    }

    public bool Cancel(Guid mediaId)
    {
        if (!jobs.TryGetValue(mediaId, out var job)) return false;
        if (job.Finished)
        {
            jobs.TryRemove(mediaId, out _);
            return true;
        }
        job.State = SpeechJobState.Cancelled;
        job.Message = "Stopped.";
        job.Cancellation.Cancel();
        return true;
    }

    private static string Describe(MediaItem media)
    {
        static string Name(MediaItem item) => item.OverrideTitle ?? item.Metadata?.ManualTitle ?? item.Metadata?.ProviderTitle ?? item.DetectedTitle;
        var title = Name(media);
        if (media.Kind != MediaKind.Episode) return title;
        var series = media.Parent is { } parent ? Name(parent) : null;
        return series is null ? title
            : FormattableString.Invariant($"{series} · S{media.SeasonNumber ?? 0:00}E{media.EpisodeNumber ?? 0:00}");
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                await signal.WaitAsync(stoppingToken);
                while (queue.TryDequeue(out var mediaId))
                {
                    if (!jobs.TryGetValue(mediaId, out var job) || job.Finished) continue;
                    await RunAsync(job, stoppingToken);
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    /// <summary>Runs one job to its end; tests call it directly.</summary>
    internal async Task RunNextAsync(CancellationToken cancellationToken)
    {
        while (queue.TryDequeue(out var mediaId))
        {
            if (jobs.TryGetValue(mediaId, out var job) && !job.Finished) await RunAsync(job, cancellationToken);
        }
    }

    private async Task RunAsync(Job job, CancellationToken stoppingToken)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken, job.Cancellation.Token);
        var token = linked.Token;
        try
        {
            job.State = SpeechJobState.Listening;
            var model = models.Current ?? throw new SpeechJobException("Download a speech model in the server settings first.");
            var tools = await live.ToolsAsync() ?? throw new SpeechJobException("ffmpeg isn't installed on this server.");
            await using var scope = scopes.CreateAsyncScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var media = await database.MediaItems.AsNoTracking().Include(item => item.LibraryRoot).FirstOrDefaultAsync(item => item.Id == job.MediaId, token)
                ?? throw new SpeechJobException("The title was not found.");
            OpenMediaFile file;
            try { file = MediaFileAccess.OpenRead(media); }
            catch (PlaybackException) { throw new SpeechJobException("The video file is offline."); }
            await using var stream = file.Stream;
            var path = Path.GetFullPath(media.SourcePath);
            var probe = await live.ProbeAsync(tools, file, path, media.Id, token);
            var track = LiveSpeechAudio.Choose(probe.Audio, job.Request.AudioIndex) ?? throw new SpeechJobException("The title has no sound track.");
            IReadOnlyList<SubtitleCue>? original = null;
            if (job.Request.Kind == SpeechJobKind.Sync)
            {
                original = SubtitleText.Cues(System.Text.Encoding.UTF8.GetString(await SubtitleTextAsync(tools, file, path, media.Id, job.Request.SubtitleIndex!.Value, token)));
                if (original.Count == 0) throw new SpeechJobException("These subtitles have no text to sync.");
            }
            var words = await ListenAsync(job, tools, file, path, track, probe.DurationSeconds ?? 0, model.Path, token);
            job.Progress = 1;
            job.State = SpeechJobState.Saving;
            if (job.Request.Kind == SpeechJobKind.Create)
            {
                var cues = SubtitleCueBuilder.Cues(words);
                if (cues.Count == 0) throw new SpeechJobException("Nobody could be heard speaking in this sound track.");
                var saved = await subtitles.AddWrittenAsync(job.MediaId, job.Request.Language, SubtitleCueBuilder.SubRip(cues), SubtitleDownloadService.SpeechProviderName, token);
                job.SubtitleId = saved.Id;
                job.Message = $"{cues.Count} subtitles written from speech.";
                job.State = SpeechJobState.Done;
                return;
            }
            var result = SubtitleSync.Find(SubtitleSync.Speech(words), [.. original!.Select(cue => new TimeSpan2(cue.Start, cue.End))]);
            switch (result.Verdict)
            {
                case SubtitleSyncVerdict.NoMatch:
                    throw new SpeechJobException("These subtitles don't match this sound track, probably another version or language. Nothing was changed.");
                case SubtitleSyncVerdict.AlreadyInSync:
                    job.Message = "These subtitles already fit the speech. Nothing was changed.";
                    job.State = SpeechJobState.AlreadyInSync;
                    return;
                default:
                    var moved = result.Timing.Apply(original!);
                    var synced = await subtitles.AddWrittenAsync(job.MediaId, job.Request.Language, SubtitleCueBuilder.SubRip(moved), SubtitleDownloadService.SyncedProviderName, token);
                    job.SubtitleId = synced.Id;
                    job.Message = SubtitleSync.Summary(result);
                    job.State = SpeechJobState.Done;
                    return;
            }
        }
        catch (OperationCanceledException) when (job.Cancellation.IsCancellationRequested)
        {
            job.State = SpeechJobState.Cancelled;
            job.Message = "Stopped.";
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            throw;
        }
        catch (SpeechJobException failure)
        {
            job.State = SpeechJobState.Failed;
            job.Message = failure.Message;
        }
        catch (Exception failure) when (failure is PlaybackException or MetadataException or InvalidOperationException or IOException)
        {
            job.State = SpeechJobState.Failed;
            job.Message = failure is MetadataException or PlaybackException ? failure.Message : "The server couldn't listen to this title.";
            LogFailed(logger, job.MediaId, failure.GetType().Name);
        }
        finally
        {
            job.Paused = false;
        }
    }

    /// <summary>The words of a whole sound track, stretch by stretch.</summary>
    private async Task<List<SpeechWord>> ListenAsync(Job job, FfmpegTools tools, OpenMediaFile file, string path, ProbedAudio track,
        double duration, string modelPath, CancellationToken token)
    {
        using var process = live.Start(tools.Ffmpeg, LiveSpeechAudio.Arguments(LiveConversionService.InputPath(file.Stream, path), track), lowPriority: true);
        try { process.PriorityClass = System.Diagnostics.ProcessPriorityClass.Idle; }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        using var stop = token.Register(() => LiveConversionService.Kill(process));
        var words = new List<SpeechWord>();
        var chunker = new SpeechChunker(Rate * ChunkSeconds, Rate * CutSearchSeconds);
        var output = process.StandardOutput.BaseStream;
        var buffer = new byte[1 << 16];
        long total = 0;
        try
        {
            while (true)
            {
                var read = await output.ReadAsync(buffer, token);
                if (read <= 0) break;
                total += chunker.Add(buffer.AsSpan(0, read));
                if (duration > 0) job.Progress = Math.Min(0.99, total / (duration * Rate));
                while (chunker.TakeReady() is { } chunk) await RecognizeAsync(job, chunk, modelPath, words, token);
            }
            if (chunker.TakeRest() is { } last) await RecognizeAsync(job, last, modelPath, words, token);
            await process.WaitForExitAsync(token);
        }
        finally
        {
            LiveConversionService.Stop(process);
        }
        if (total == 0) throw new SpeechJobException("The sound track could not be read.");
        return words;
    }

    private async Task RecognizeAsync(Job job, SpeechChunk chunk, string modelPath, List<SpeechWord> words, CancellationToken token)
    {
        await WaitWhilePlaybackAsync(job, token);
        var heard = await recognizer.RecognizeAsync(chunk.Samples, job.Request.Language, modelPath, token);
        var trimmed = SpeechTiming.TrimmingSilence(heard, SpeechTiming.Levels(chunk.Samples));
        words.AddRange(trimmed.Select(word => word with { Start = word.Start + chunk.StartSeconds, End = word.End + chunk.StartSeconds }));
    }

    private bool BusyWithPlayback() => streams.PlaybackCount > 0 || live.Running > 0;

    private async Task WaitWhilePlaybackAsync(Job job, CancellationToken token)
    {
        while (BusyWithPlayback())
        {
            job.Paused = true;
            await Task.Delay(TimeSpan.FromSeconds(5), token);
        }
        job.Paused = false;
    }

    /// <summary>The WebVTT of a subtitle track as the stream lists it: embedded, 1000+ beside the video, 2000+ downloaded.</summary>
    private async Task<byte[]> SubtitleTextAsync(FfmpegTools tools, OpenMediaFile file, string path, Guid mediaId, int index, CancellationToken token)
    {
        if (index >= SubtitleDownloadService.DownloadedTrackBase)
        {
            var list = downloads.List(mediaId);
            var position = index - SubtitleDownloadService.DownloadedTrackBase;
            if (position >= list.Count || downloads.SubtitlePath(mediaId, list[position].Id) is not { } stored)
                throw new SpeechJobException("The subtitles to sync were not found.");
            return await SidecarSubtitles.ReadAsWebVttAsync(stored, token);
        }
        if (index >= 1000)
        {
            var sidecars = SidecarSubtitles.Discover(path);
            var position = index - 1000;
            if (position >= sidecars.Count || !sidecars[position].Supported) throw new SpeechJobException("The subtitles to sync were not found.");
            return await SidecarSubtitles.ReadAsWebVttAsync(sidecars[position].FilePath, token);
        }
        file.Stream.Seek(0, SeekOrigin.Begin);
        return await live.ExtractSubtitlesAsync(tools, file, path, index, token);
    }

    [LoggerMessage(Level = LogLevel.Warning, Message = "Speech job for {MediaId} failed: {Error}")]
    private static partial void LogFailed(ILogger logger, Guid mediaId, string error);
}

/// <summary>A failure the person can read and act on.</summary>
public sealed class SpeechJobException(string message) : Exception(message);

/// <summary>A stretch of sound and where it starts in the track.</summary>
public sealed record SpeechChunk(short[] Samples, double StartSeconds);

/// <summary>
/// Collects 16-bit samples and hands out stretches of <c>chunk</c> samples, each cut at the
/// quietest 300 ms within the following <c>search</c> samples, so words are rarely split.
/// </summary>
public sealed class SpeechChunker(int chunk, int search, int sampleRate = 16_000)
{
    private readonly List<short> samples = [];
    private byte? odd;
    private long taken;

    /// <summary>Adds bytes of little-endian PCM; returns how many samples arrived.</summary>
    public int Add(ReadOnlySpan<byte> bytes)
    {
        var added = 0;
        var index = 0;
        if (odd is { } low && bytes.Length > 0)
        {
            samples.Add((short)(low | (bytes[0] << 8)));
            odd = null;
            index = 1;
            added++;
        }
        for (; index + 1 < bytes.Length; index += 2)
        {
            samples.Add((short)(bytes[index] | (bytes[index + 1] << 8)));
            added++;
        }
        if (index < bytes.Length) odd = bytes[index];
        return added;
    }

    public SpeechChunk? TakeReady()
    {
        if (samples.Count < chunk + search) return null;
        var cut = QuietestCut(chunk, chunk + search);
        return Take(cut);
    }

    public SpeechChunk? TakeRest() => samples.Count == 0 ? null : Take(samples.Count);

    private SpeechChunk Take(int count)
    {
        var part = samples.GetRange(0, count).ToArray();
        samples.RemoveRange(0, count);
        var start = (double)taken / sampleRate;
        taken += count;
        return new SpeechChunk(part, start);
    }

    private int QuietestCut(int from, int to)
    {
        var window = sampleRate * 3 / 10;
        var best = from;
        var quietest = double.MaxValue;
        for (var start = from; start + window <= to; start += window / 2)
        {
            double energy = 0;
            for (var index = start; index < start + window; index += 4) energy += Math.Abs((int)samples[index]);
            if (energy < quietest)
            {
                quietest = energy;
                best = start + window / 2;
            }
        }
        return best;
    }
}
