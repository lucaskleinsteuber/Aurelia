namespace Aurelia.Server.Services;

/// <summary>
/// When a player's sleep timer ends on any device, a server with Linux sleep mode may go to sleep
/// five minutes later, as long as nothing plays meanwhile on any device. The server only leaves a
/// <c>sleep-ready</c> file in its data folder; the operating system's sleep mode
/// (<c>aurelia sleep on</c>) decides and removes it.
/// </summary>
public sealed class ServerSleepSignal(ServerRuntimeOptions runtime, ActiveStreamRegistry streams, TimeProvider clock)
{
    public const string FileName = "sleep-ready";
    public static readonly TimeSpan Delay = TimeSpan.FromMinutes(5);
    // The player that ran the timer may still finish a read just after it ended.
    private static readonly TimeSpan Grace = TimeSpan.FromSeconds(30);
    private readonly object gate = new();
    private DateTimeOffset? requestedAt;

    private string ReadyPath => Path.Combine(runtime.DataDirectory, FileName);

    public void SleepTimerEnded()
    {
        lock (gate) requestedAt = clock.GetUtcNow();
    }

    /// <summary>Someone started watching: no sleep is due any more.</summary>
    public void PlaybackStarted()
    {
        lock (gate)
        {
            requestedAt = null;
            Remove();
        }
    }

    /// <summary>Checks the request and leaves the file once it is due. True when it was written.</summary>
    public bool Evaluate()
    {
        lock (gate)
        {
            if (requestedAt is not { } at) return false;
            var now = clock.GetUtcNow();
            var playedSince = streams.LastPlaybackActivity is { } last && last > at + Grace;
            if (playedSince || (now - at > Grace && streams.PlaybackCount > 0))
            {
                requestedAt = null;
                return false;
            }

            if (now - at < Delay) return false;
            // One request leads to one sleep: after waking, the server stays up until the next timer.
            requestedAt = null;
            PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
            File.WriteAllText(ReadyPath, now.ToUnixTimeSeconds().ToString(System.Globalization.CultureInfo.InvariantCulture));
            return true;
        }
    }

    public void Remove()
    {
        try { File.Delete(ReadyPath); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }
}

public sealed partial class ServerSleepWorker(ServerSleepSignal signal, ILogger<ServerSleepWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // A file from before a restart belongs to a request that no longer exists.
        signal.Remove();
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(30), stoppingToken);
                try
                {
                    if (signal.Evaluate()) SleepReady(logger);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    SignalUnavailable(logger, exception.GetType().Name);
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    [LoggerMessage(LogLevel.Information, "A sleep timer ended and nothing played for five minutes; the server may sleep.")]
    private static partial void SleepReady(ILogger logger);

    [LoggerMessage(LogLevel.Warning, "The sleep signal could not be written ({ErrorType}).")]
    private static partial void SignalUnavailable(ILogger logger, string errorType);
}
