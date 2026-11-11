using System.Globalization;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

/// <summary>
/// Power for a server that Aurelia for Mac or Aurelia for Linux hosts on a desktop or laptop: with
/// "stop", the server ends after the unused minutes (or five minutes after a player's sleep timer)
/// with <see cref="ServerHosting.IdleExitCode"/>, and its app leaves it stopped until someone opens
/// Aurelia on that computer. Awake hours and anything playing keep it running. Linux package
/// servers are handled by the operating system's aurelia-autosleep instead.
/// </summary>
public sealed partial class AppHostedIdleStop(
    ServerRuntimeOptions runtime,
    ServerPowerSettingsStore power,
    ServerUseClock use,
    ActiveStreamRegistry streams,
    IHostApplicationLifetime lifetime,
    TimeProvider clock,
    ILogger<AppHostedIdleStop> logger) : BackgroundService
{
    private static readonly TimeSpan Check = TimeSpan.FromMinutes(1);

    /// <summary>Why the server should stop now, or null while it should keep running.</summary>
    public static string? Decide(ServerPowerSettings settings, DateTimeOffset now, DateTimeOffset lastActive, int playing,
        DateTimeOffset? sleepTimerEnded, TimeZoneInfo zone)
    {
        if (settings.Mode != "stop" || playing > 0) return null;
        if (settings.AfterSleepTimer && sleepTimerEnded is { } ended && ended >= lastActive) return "A sleep timer ended";
        if (InAwakeHours(settings, TimeZoneInfo.ConvertTime(now, zone))) return null;
        return now - lastActive >= TimeSpan.FromMinutes(settings.IdleMinutes) ? $"Unused for {settings.IdleMinutes} minutes" : null;
    }

    public static bool InAwakeHours(ServerPowerSettings settings, DateTimeOffset local)
    {
        if (settings.AwakeFrom is not { } from || settings.AwakeUntil is not { } until) return false;
        var start = TimeOnly.ParseExact(from, "HH:mm", CultureInfo.InvariantCulture);
        var end = TimeOnly.ParseExact(until, "HH:mm", CultureInfo.InvariantCulture);
        var time = TimeOnly.FromDateTime(local.DateTime);
        return start < end ? time >= start && time < end : time >= start || time < end;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!ServerHosting.ByApp(ServerHosting.Kind(runtime))) return;
        var started = clock.GetUtcNow();
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                await Task.Delay(Check, clock, stoppingToken);
                var now = clock.GetUtcNow();
                var lastActive = new[] { started, use.LastUse ?? started, streams.LastPlaybackActivity ?? started }.Max();
                var reason = Decide(power.Read(), now, lastActive, streams.PlaybackCount, SleepTimerEnded(), TimeZoneInfo.Local);
                if (reason is null) continue;
                Stopping(logger, reason);
                Environment.ExitCode = ServerHosting.IdleExitCode;
                lifetime.StopApplication();
                return;
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    private DateTimeOffset? SleepTimerEnded()
    {
        var path = Path.Combine(runtime.DataDirectory, ServerSleepSignal.FileName);
        return File.Exists(path) ? new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero) : null;
    }

    [LoggerMessage(LogLevel.Information, "{Reason}: Aurelia Server stops until Aurelia is opened on this computer again.")]
    private static partial void Stopping(ILogger logger, string reason);
}
