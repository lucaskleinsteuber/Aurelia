using System.Diagnostics;

namespace Aurelia.Server.Services.Hls;

/// <summary>Which HLS session a request belongs to: the profile session's title in one quality and sound track.</summary>
/// <remarks>
/// It holds no playback ticket, so a renewed ticket keeps using the same session. A download
/// (<paramref name="Download"/>) is a session of its own: it gives its conversion place to anyone
/// who starts watching and never makes a playing session yield.
/// </remarks>
public sealed record HlsSessionKey(Guid UserId, Guid ProfileSessionId, Guid MediaId, string Step, int? Audio, bool Download = false);

/// <summary>One running ffmpeg for a session: its fragmented MP4 output and how to end it.</summary>
public interface IHlsRun : IDisposable
{
    Stream Output { get; }

    /// <summary>ffmpeg's last messages once it ended, for a failure's log line.</summary>
    Task<string> ErrorsAsync();

    /// <summary>ffmpeg's exit status once it ended; null while it runs.</summary>
    int? ExitCode { get; }
}

/// <summary>Starts ffmpeg for a session; tests replace it with invented output.</summary>
public interface IHlsConverter
{
    IHlsRun Start(HlsSession session, LiveStreamOptions options, Action<double> speed);
}

/// <summary>The production converter: ffmpeg without a shell, reading the session's open file, writing to its standard output.</summary>
public sealed class FfmpegHlsConverter(LiveConversionService live) : IHlsConverter
{
    public IHlsRun Start(HlsSession session, LiveStreamOptions options, Action<double> speed)
    {
        ArgumentNullException.ThrowIfNull(session);
        var arguments = new List<string> { "-progress", "pipe:2", "-stats_period", "2" };
        arguments.AddRange(LiveConversionPlanner.Arguments(LiveConversionService.InputPath(session.File, session.SourcePath), options));
        var process = live.Start(session.Ffmpeg, arguments);
        return new Run(process, LiveConversionService.ReadDiagnosticsAsync(process.StandardError, speed));
    }

    private sealed class Run(Process process, Task<string> errors) : IHlsRun
    {
        public Stream Output => process.StandardOutput.BaseStream;
        public Task<string> ErrorsAsync() => errors;

        public int? ExitCode
        {
            get
            {
                try { return process.HasExited ? process.ExitCode : null; }
                catch (InvalidOperationException) { return null; }
            }
        }

        public void Dispose()
        {
            LiveConversionService.Stop(process);
            process.Dispose();
        }
    }
}

/// <summary>
/// One title converted for HLS in one quality: an open file, at most one ffmpeg and the segments
/// in memory. A request for a segment the conversion has not reached starts ffmpeg again at that
/// segment (a seek). ffmpeg writes only to its standard output; segments live in a
/// <see cref="SegmentStore"/> and are gone when the session ends.
/// </summary>
public sealed partial class HlsSession : IAsyncDisposable
{
    private static readonly TimeSpan InitWait = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan SegmentWait = TimeSpan.FromSeconds(30);

    private readonly HlsSessionManager manager;
    private readonly IHlsConverter converter;
    private readonly LiveConversionService live;
    private readonly FfmpegTools tools;
    private readonly ILogger logger;
    private readonly TimeProvider clock;
    private readonly IDisposable fileOwner;
    private readonly object lifecycleGate = new();
    private readonly SemaphoreSlim control = new(1, 1);
    private readonly SegmentStore store = new();
    private readonly CancellationTokenSource ending = new();
    private Fmp4Init? init;
    private (LiveVideoEncoder Kind, HardwareEncoder? Chip)? encoder;
    private CancellationTokenSource? producerStop;
    private Task? producer;
    private int failures;
    private int activeOperations;
    private bool disposed;
    private bool primitivesDisposed;
    private long lastUsedTicks;
    private double speed;
    private volatile bool yielded;
    private volatile bool completed;

    internal HlsSession(
        HlsSessionManager manager,
        HlsSessionKey key,
        FileStream file,
        IDisposable fileOwner,
        string sourcePath,
        string title,
        double durationSeconds,
        StreamingStep step,
        ProbedVideo video,
        ProbedAudio? audio,
        HdrToneMapping toneMapping,
        FfmpegTools tools,
        LiveConversionService live,
        IHlsConverter converter,
        ILogger logger,
        TimeProvider clock)
    {
        this.manager = manager;
        Key = key;
        File = file;
        this.fileOwner = fileOwner;
        SourcePath = sourcePath;
        Title = title;
        DurationSeconds = durationSeconds;
        Step = step;
        Video = video;
        Audio = audio;
        ToneMapping = toneMapping;
        this.tools = tools;
        this.live = live;
        this.converter = converter;
        this.logger = logger;
        this.clock = clock;
        Touch();
    }

    public HlsSessionKey Key { get; }
    public FileStream File { get; }
    public string SourcePath { get; }
    public string Title { get; }
    public double DurationSeconds { get; }
    public StreamingStep Step { get; }
    public ProbedVideo Video { get; }
    public ProbedAudio? Audio { get; }
    public HdrToneMapping ToneMapping { get; }
    public string Ffmpeg => tools.Ffmpeg;
    public int SegmentCount => HlsPlaylists.SegmentCount(DurationSeconds);
    public SegmentStore Store => store;

    /// <summary>When a request last used the session.</summary>
    public DateTimeOffset LastUsed => new(Interlocked.Read(ref lastUsedTicks), TimeSpan.Zero);

    /// <summary>Whether ffmpeg runs for this session now.</summary>
    public bool IsProducing { get { lock (store) return producer is { IsCompleted: false }; } }

    /// <summary>Whether ffmpeg is running but paused because the player is far behind.</summary>
    internal bool IsPaused => IsProducing && store.ShouldPause;

    /// <summary>Whether this session yielded to another quality or finished converting and can be reclaimed.</summary>
    internal bool IsReclaimable => !IsProducing && (yielded || completed);

    /// <summary>The encoder of the conversion, once one started.</summary>
    public LiveVideoEncoder? Encoder => encoder?.Kind;

    /// <summary>The last speed ffmpeg reported against real time, such as 3.2.</summary>
    public double? Speed => Volatile.Read(ref speed) is var value && value > 0 ? value : null;

    internal CancellationToken Ending => ending.Token;

    internal bool IsDisposed { get { lock (lifecycleGate) return disposed; } }

    private bool TryEnterOperation()
    {
        lock (lifecycleGate)
        {
            if (disposed) return false;
            activeOperations++;
            return true;
        }
    }

    private void ExitOperation()
    {
        bool shouldDisposePrimitives;
        lock (lifecycleGate)
        {
            activeOperations--;
            shouldDisposePrimitives = disposed && activeOperations == 0 && !primitivesDisposed;
            if (shouldDisposePrimitives) primitivesDisposed = true;
        }
        if (shouldDisposePrimitives)
        {
            control.Dispose();
            ending.Dispose();
        }
    }

    private void Touch() => Interlocked.Exchange(ref lastUsedTicks, clock.GetUtcNow().UtcTicks);

    /// <summary>The init segment; starts the conversion when none ran yet. Null when the conversion failed.</summary>
    public async Task<byte[]?> InitAsync(CancellationToken cancellationToken)
    {
        if (!TryEnterOperation()) throw new HlsSessionEndedException();
        try
        {
            Touch();
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, ending.Token);
            linked.CancelAfter(InitWait);
            try
            {
                while (true)
                {
                    var changed = store.ChangedAsync(linked.Token);
                    if (Volatile.Read(ref init) is { } ready) return ready.Data;
                    if (!IsProducing)
                    {
                        if (Volatile.Read(ref failures) >= 2) return null;
                        await StartAsync(Math.Max(0, store.Playhead), force: true, linked.Token);
                        continue;
                    }
                    await changed;
                }
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                if (IsDisposed) throw new HlsSessionEndedException();
                return null;
            }
        }
        finally
        {
            ExitOperation();
        }
    }

    /// <summary>A segment, converting or seeking as needed. Null when it could not be made in time.</summary>
    public async Task<byte[]?> SegmentAsync(int index, CancellationToken cancellationToken)
    {
        if (index < 0 || index >= SegmentCount) return null;
        if (!TryEnterOperation()) throw new HlsSessionEndedException();
        try
        {
            Touch();
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, ending.Token);
            linked.CancelAfter(SegmentWait);
            var attempts = 0;
            try
            {
                while (true)
                {
                    var changed = store.ChangedAsync(linked.Token);
                    switch (store.Request(index))
                    {
                        case SegmentPlan.Ready:
                            if (store.TryGet(index) is { } segment)
                            {
                                Touch();
                                return segment;
                            }
                            break;
                        case SegmentPlan.Restart:
                            if (attempts++ >= 2 || Volatile.Read(ref failures) >= 2) return null;
                            await StartAsync(index, force: false, linked.Token);
                            continue;
                        case SegmentPlan.Wait:
                            if (!IsProducing) goto case SegmentPlan.Restart;
                            break;
                    }
                    await changed;
                }
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                if (IsDisposed) throw new HlsSessionEndedException();
                return null;
            }
        }
        finally
        {
            ExitOperation();
        }
    }

    /// <summary>Starts ffmpeg at the segment unless the running one already serves it.</summary>
    private async Task StartAsync(int index, bool force, CancellationToken cancellationToken)
    {
        await control.WaitAsync(cancellationToken);
        try
        {
            if (IsDisposed || ending.IsCancellationRequested) throw new HlsSessionEndedException();
            if (!force && store.Request(index) != SegmentPlan.Restart && IsProducing) return;
            if (force && IsProducing) return;
            await StopProducerAsync();
            // Only one conversion per title and profile session: an earlier quality yields its place.
            await manager.YieldOthersAsync(this);
            if (IsDisposed || ending.IsCancellationRequested) throw new HlsSessionEndedException();
            var slot = await EnterAsync(cancellationToken) ?? throw new HlsBusyException();
            var handedOff = false;
            try
            {
                if (IsDisposed || ending.IsCancellationRequested) throw new HlsSessionEndedException();
                yielded = false;
                completed = false;
                encoder ??= live.ChooseEncoder(tools) ?? throw new InvalidOperationException("The server cannot encode pictures.");
                var stop = CancellationTokenSource.CreateLinkedTokenSource(ending.Token);
                try
                {
                    if (IsDisposed || ending.IsCancellationRequested)
                    {
                        stop.Dispose();
                        throw new HlsSessionEndedException();
                    }
                    var options = new LiveStreamOptions(index * HlsPlaylists.SegmentSeconds, Video, encoder.Value.Kind, Audio, CopyAudio: false,
                        ToneMapping, encoder.Value.Chip, Step, HlsPlaylists.SegmentSeconds, live.Pace.Preset(encoder.Value.Kind, Step.Id));
                    store.BeginProducing(index);
                    lock (store)
                    {
                        if (IsDisposed || ending.IsCancellationRequested)
                        {
                            stop.Dispose();
                            store.EndProducing(finished: false);
                            throw new HlsSessionEndedException();
                        }
                        producerStop = stop;
                        producer = Task.Run(() => ProduceAsync(index, options, slot, stop.Token), CancellationToken.None);
                        handedOff = true;
                    }
                }
                catch
                {
                    if (!handedOff) stop.Dispose();
                    throw;
                }
            }
            finally
            {
                if (!handedOff) slot.Dispose();
            }
        }
        finally { control.Release(); }
    }

    /// <summary>
    /// A place to encode pictures. Someone watching takes the place of a download when every place
    /// is taken; a download waits while anyone who watches is waiting for one.
    /// </summary>
    private async Task<IDisposable?> EnterAsync(CancellationToken cancellationToken)
    {
        if (Key.Download)
        {
            if (manager.PlaybackWaiting) return null;
            return await live.EnterAsync(encodesVideo: true, cancellationToken);
        }
        using (manager.WaitForPlace())
        {
            if (live.VideoPlacesTaken) await manager.PauseDownloadAsync(this);
            if (live.VideoPlacesTaken) await manager.PausePausedSiblingAsync(this);
            return await live.EnterAsync(encodesVideo: true, cancellationToken);
        }
    }

    /// <summary>Stops converting because another quality of the same title took over.</summary>
    internal async Task YieldAsync()
    {
        yielded = true;
        await StopProducerAsync();
    }

    /// <summary>Ends the running ffmpeg, if any, and waits until it is gone.</summary>
    internal async Task StopProducerAsync()
    {
        Task? running;
        CancellationTokenSource? stop;
        lock (store)
        {
            running = producer;
            stop = producerStop;
            producer = null;
            producerStop = null;
        }
        if (stop is not null) await stop.CancelAsync();
        if (running is not null)
        {
            try { await running; }
            catch (Exception exception) when (exception is OperationCanceledException) { }
        }
        stop?.Dispose();
    }

    private async Task ProduceAsync(int start, LiveStreamOptions options, IDisposable slot, CancellationToken cancellationToken)
    {
        var finished = false;
        var fragments = 0;
        // ffmpeg reports its average speed so far. The best one after a few segments shows what the
        // computer manages; later ones drop while reading pauses for a player that is far behind.
        var peak = 0.0;
        IHlsRun? run = null;
        try
        {
            run = converter.Start(this, options, value =>
            {
                Volatile.Write(ref speed, value);
                if (Volatile.Read(ref fragments) >= 2 && value > peak) peak = value;
            });
            using var stopOnCancel = cancellationToken.Register(static state => ((IHlsRun)state!).Dispose(), run);
            byte[]? ftyp = null;
            byte[]? moof = null;
            var last = start * (double)HlsPlaylists.SegmentSeconds;
            while (await Fmp4.ReadBoxAsync(run.Output, cancellationToken) is { } box)
            {
                switch (box.Type)
                {
                    case "ftyp":
                        ftyp = box.Data;
                        break;
                    case "moov":
                        AcceptInit(Fmp4.ParseInit(ftyp ?? [], box.Data));
                        break;
                    case "moof":
                        moof = box.Data;
                        break;
                    case "mdat" when moof is not null && Volatile.Read(ref init) is { } current:
                        last = Fmp4.FragmentStart(moof, current) ?? last;
                        var fragment = new byte[moof.Length + box.Data.Length];
                        moof.CopyTo(fragment, 0);
                        box.Data.CopyTo(fragment, moof.Length);
                        store.Add(HlsPlaylists.SegmentFor(last), fragment);
                        fragments++;
                        moof = null;
                        // Reading pauses while the player is far behind, so ffmpeg waits on its full pipe.
                        while (store.ShouldPause) await store.ChangedAsync(cancellationToken);
                        break;
                }
            }
            finished = run.ExitCode is null or 0 || fragments > 0;
        }
        // A seek or the session's end killed ffmpeg on purpose; its broken pipe is no failure.
        catch (Exception exception) when (cancellationToken.IsCancellationRequested && exception is OperationCanceledException
                                              or IOException or ObjectDisposedException or InvalidDataException)
        { }
        catch (Exception exception) when (exception is InvalidDataException or IOException or ObjectDisposedException
                                              or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            LogBroken(logger, exception.Message);
        }
        finally
        {
            if (finished && fragments > 0 && !cancellationToken.IsCancellationRequested) completed = true;
            store.EndProducing(finished && fragments > 0);
            if (fragments == 0 && !cancellationToken.IsCancellationRequested)
            {
                var errors = run is null ? string.Empty : await run.ErrorsAsync().WaitAsync(TimeSpan.FromSeconds(5), CancellationToken.None).ConfigureAwait(false);
                LiveConversionService.LogFailed(logger, "ffmpeg " + HardwareEncoding.EncoderName(options.Encoder ?? LiveVideoEncoder.Libx264),
                    run?.ExitCode ?? -1, errors, SourcePath);
                if (options.Hardware is not null && tools.HasSoftwareEncoder)
                {
                    // The chip failed: this session and the next conversions use the processor for a while.
                    live.Health.ReportFailure();
                    encoder = (LiveVideoEncoder.Libx264, null);
                }
                else Interlocked.Increment(ref failures);
            }
            if (fragments >= 3 && peak > 0 && options.Encoder is { } kind)
                live.Pace.Record(kind, Step.Id, options.X264Preset, peak);
            run?.Dispose();
            slot.Dispose();
        }
    }

    private void AcceptInit(Fmp4Init candidate)
    {
        var current = Volatile.Read(ref init);
        if (current is not null && current.Descriptions.AsSpan().SequenceEqual(candidate.Descriptions)) return;
        // Another encoder or setting gave different codec settings: older segments would not decode with it.
        if (current is not null) store.Clear();
        Volatile.Write(ref init, candidate);
    }

    /// <summary>Ends the conversion and frees the memory and the file.</summary>
    public async ValueTask DisposeAsync()
    {
        lock (lifecycleGate)
        {
            if (disposed) return;
            disposed = true;
            activeOperations++;
        }
        try
        {
            await ending.CancelAsync();
            await control.WaitAsync();
            try
            {
                await StopProducerAsync();
            }
            finally
            {
                control.Release();
            }
            store.Clear();
            fileOwner.Dispose();
        }
        finally
        {
            ExitOperation();
        }
    }

    [LoggerMessage(LogLevel.Warning, "An HLS conversion stopped: {Message}")]
    private static partial void LogBroken(ILogger logger, string message);
}

/// <summary>The server converts as many titles as it can.</summary>
public sealed class HlsBusyException() : Exception("The server is converting as many titles as it can.");

/// <summary>The HLS session ended while a segment request was starting or waiting on it.</summary>
public sealed class HlsSessionEndedException() : Exception("The HLS session has ended.");
