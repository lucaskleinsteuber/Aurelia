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
        HlsSession? winner = null;
        lock (gate)
        {
            if (sessions.TryGetValue(session.Key, out var existing)) winner = existing.Session;
            else if (sessions.Count < MaximumSessions)
            {
                var key = session.Key;
                var watch = streams.Watch(key.UserId, key.ProfileSessionId, key.MediaId, () => _ = EndAsync(key));
                sessions[key] = new Entry(session, watch);
                return session;
            }
        }
        await session.DisposeAsync();
        return winner ?? throw new HlsBusyException();
    }

    /// <summary>Stops the conversions of the same title in the same profile session in other qualities or sound tracks.</summary>
    internal async Task YieldOthersAsync(HlsSession session)
    {
        List<HlsSession> others;
        lock (gate)
        {
            others = sessions.Values.Select(entry => entry.Session)
                .Where(other => other != session && other.Key.ProfileSessionId == session.Key.ProfileSessionId
                    && other.Key.MediaId == session.Key.MediaId)
                .ToList();
        }
        foreach (var other in others) await other.StopProducerAsync();
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

    [LoggerMessage(LogLevel.Warning, "An HLS session did not end cleanly: {Message}")]
    private static partial void LogEndFailed(ILogger logger, string message);
}

/// <summary>Ends idle HLS sessions every few seconds.</summary>
public sealed class HlsSessionSweeper(HlsSessionManager sessions, TimeProvider clock) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5), clock);
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken)) await sessions.SweepAsync();
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        finally { await sessions.DisposeAsync(); }
    }
}
