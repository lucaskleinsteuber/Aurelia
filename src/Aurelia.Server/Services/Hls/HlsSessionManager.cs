namespace Aurelia.Server.Services.Hls;

/// <summary>
/// The running HLS sessions: at most six, each ended a minute after its last request, when its
/// user, profile session or title is revoked, or when the server stops. Only one session per
/// title and profile session converts at a time; switching quality makes the other one yield.
/// </summary>
public sealed partial class HlsSessionManager(
    LiveConversionService live,
    ActiveStreamRegistry streams,
    ILogger<HlsSessionManager> logger,
    TimeProvider? clock = null,
    IHlsConverter? converter = null) : IAsyncDisposable
{
    public const int MaximumSessions = 6;
    /// <summary>One profile never takes every conversion: the others keep two (audit S-L7).</summary>
    public const int MaximumSessionsPerUser = 4;
    public static readonly TimeSpan IdleTimeout = TimeSpan.FromSeconds(60);

    private readonly TimeProvider clock = clock ?? TimeProvider.System;
    private readonly IHlsConverter converter = converter ?? new FfmpegHlsConverter(live);
    private readonly object gate = new();
    private readonly Dictionary<HlsSessionKey, Entry> sessions = [];

    private sealed record Entry(HlsSession Session, IDisposable Watch);

    public int Count { get { lock (gate) return sessions.Count; } }

    public IReadOnlyList<HlsSession> Sessions { get { lock (gate) return sessions.Values.Select(entry => entry.Session).ToList(); } }

    public HlsSession? Find(HlsSessionKey key)
    {
        lock (gate) return sessions.TryGetValue(key, out var entry) ? entry.Session : null;
    }

    /// <summary>A new session for an open title file; it is not running until <see cref="AddAsync"/> keeps it.</summary>
    public HlsSession Create(HlsSessionKey key, FileStream file, IDisposable fileOwner, string sourcePath, string title, double durationSeconds,
        StreamingStep step, ProbedVideo video, ProbedAudio? audio, HdrToneMapping toneMapping, FfmpegTools tools) =>
        new(this, key, file, fileOwner, sourcePath, title, durationSeconds, step, video, audio, toneMapping, tools, live, converter, logger, this.clock);

    /// <summary>Keeps the session, or returns the one another request kept first and ends this one.</summary>
    /// <exception cref="HlsBusyException">Six sessions run already.</exception>
    public async Task<HlsSession> AddAsync(HlsSession session)
    {
        ArgumentNullException.ThrowIfNull(session);
        await SweepAsync();
        while (true)
        {
            HlsSession? winner = null;
            HlsSessionKey? reclaim = null;
            lock (gate)
            {
                if (sessions.TryGetValue(session.Key, out var existing)) winner = existing.Session;
                else
                {
                    var userFull = sessions.Keys.Count(key => key.UserId == session.Key.UserId) >= MaximumSessionsPerUser;
                    var totalFull = sessions.Count >= MaximumSessions;
                    if (!totalFull && !userFull)
                    {
                        var key = session.Key;
                        var watch = streams.Watch(key.UserId, key.ProfileSessionId, key.MediaId, () => _ = EndAsync(key));
                        sessions[key] = new Entry(session, watch);
                        return session;
                    }
                    reclaim = PickReclaimableLocked(session.Key, onlySameUser: userFull);
                }
            }
            if (reclaim is { } victim)
            {
                await EndAsync(victim);
                continue;
            }
            await session.DisposeAsync();
            return winner ?? throw new HlsBusyException();
        }
    }

    private HlsSessionKey? PickReclaimableLocked(HlsSessionKey incoming, bool onlySameUser)
    {
        var candidates = sessions.Values
            .Select(entry => entry.Session)
            .Where(other => other.IsReclaimable && (!onlySameUser || other.Key.UserId == incoming.UserId));
        var chosen = candidates
            .OrderByDescending(other => other.Key.UserId == incoming.UserId)
            .ThenByDescending(other => other.Key.ProfileSessionId == incoming.ProfileSessionId)
            .ThenByDescending(other => other.Key.MediaId == incoming.MediaId)
            .ThenBy(other => other.LastUsed)
            .FirstOrDefault();
        return chosen?.Key;
    }

    /// <summary>Stops the conversions of the same title in the same profile session in other qualities or sound tracks.</summary>
    internal async Task YieldOthersAsync(HlsSession session)
    {
        List<HlsSession> others;
        lock (gate)
        {
            others = sessions.Values.Select(entry => entry.Session)
                .Where(other => other != session && other.Key.ProfileSessionId == session.Key.ProfileSessionId
                    && other.Key.MediaId == session.Key.MediaId && other.Key.Download == session.Key.Download)
                .ToList();
        }
        foreach (var other in others) await other.YieldAsync();
    }

    private int playbackWaiting;

    /// <summary>Whether someone who watches is waiting for a place to encode; downloads hold back meanwhile.</summary>
    internal bool PlaybackWaiting => Volatile.Read(ref playbackWaiting) > 0;

    /// <summary>Counts a session that watches while it waits for a place to encode.</summary>
    internal IDisposable WaitForPlace()
    {
        Interlocked.Increment(ref playbackWaiting);
        return new Waiting(this);
    }

    private sealed class Waiting(HlsSessionManager owner) : IDisposable
    {
        private int done;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref done, 1) == 0) Interlocked.Decrement(ref owner.playbackWaiting);
        }
    }

    /// <summary>
    /// Ends one running download conversion so someone can watch. The download's session stays;
    /// its next segment starts converting again once a place is free.
    /// </summary>
    internal async Task<bool> PauseDownloadAsync(HlsSession forSession)
    {
        HlsSession? download;
        lock (gate)
        {
            download = sessions.Values.Select(entry => entry.Session)
                .FirstOrDefault(other => other != forSession && other.Key.Download && other.IsProducing);
        }
        if (download is null) return false;
        LogDownloadPaused(logger);
        await download.StopProducerAsync();
        return true;
    }

    /// <summary>
    /// Stops one paused playback conversion of another title in the same profile session so a
    /// newly opened title gets its encoding slot immediately. Its buffered segments stay in memory.
    /// </summary>
    internal async Task<bool> PausePausedSiblingAsync(HlsSession forSession)
    {
        HlsSession? sibling;
        lock (gate)
        {
            sibling = sessions.Values.Select(entry => entry.Session)
                .Where(other => other != forSession
                    && !other.Key.Download
                    && other.Key.ProfileSessionId == forSession.Key.ProfileSessionId
                    && other.Key.MediaId != forSession.Key.MediaId
                    && other.IsPaused)
                .OrderBy(other => other.LastUsed)
                .FirstOrDefault();
        }
        if (sibling is null) return false;
        await sibling.StopProducerAsync();
        return true;
    }

    /// <summary>Ends sessions without a request for a minute.</summary>
    public async Task SweepAsync()
    {
        var now = clock.GetUtcNow();
        List<HlsSessionKey> idle;
        lock (gate) idle = sessions.Where(pair => now - pair.Value.Session.LastUsed >= IdleTimeout).Select(pair => pair.Key).ToList();
        foreach (var key in idle) await EndAsync(key);
    }

    /// <summary>Ends every session of the title in this profile session, for instance when its ticket was revoked.</summary>
    public async Task EndTitleAsync(Guid profileSessionId, Guid mediaId)
    {
        List<HlsSessionKey> keys;
        lock (gate) keys = sessions.Keys.Where(key => key.ProfileSessionId == profileSessionId && key.MediaId == mediaId).ToList();
        foreach (var key in keys) await EndAsync(key);
    }

    public async Task EndAsync(HlsSessionKey key)
    {
        Entry? entry;
        lock (gate)
        {
            if (!sessions.Remove(key, out entry)) return;
        }
        entry.Watch.Dispose();
        try { await entry.Session.DisposeAsync(); }
        catch (Exception exception) when (exception is ObjectDisposedException or InvalidOperationException)
        {
            LogEndFailed(logger, exception.Message);
        }
    }

    public async ValueTask DisposeAsync()
    {
        List<HlsSessionKey> keys;
        lock (gate) keys = [.. sessions.Keys];
        foreach (var key in keys) await EndAsync(key);
    }

    [LoggerMessage(LogLevel.Information, "A download's conversion paused so someone can watch")]
    private static partial void LogDownloadPaused(ILogger logger);

    [LoggerMessage(LogLevel.Warning, "An HLS session did not end cleanly: {Message}")]
    private static partial void LogEndFailed(ILogger logger, string message);
}

/// <summary>Ends idle HLS sessions every few seconds.</summary>
public sealed class HlsSessionSweeper(HlsSessionManager sessions, TimeProvider clock, ILogger<HlsSessionSweeper>? logger = null) : BackgroundService
{
    private static readonly Action<ILogger, Exception?> SweepFailed = LoggerMessage.Define(
        LogLevel.Warning, new EventId(4416, nameof(SweepFailed)), "HLS session sweep paused after an unexpected failure.");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5), clock);
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken))
            {
                try { await sessions.SweepAsync(); }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    if (logger is not null) SweepFailed(logger, exception);
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        finally { await sessions.DisposeAsync(); }
    }
}
