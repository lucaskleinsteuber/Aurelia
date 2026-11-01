using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Playback;

/// <summary>What this computer does when another device sends it a command.</summary>
public interface IPlayOnTarget
{
    /// <summary>The player now, for the heartbeat; null when nothing plays.</summary>
    PlaybackController? Player { get; }

    void Play(Guid mediaId, double? positionSeconds);
}

/// <summary>
/// Play On, receiving side: this computer announces itself as a player every 15 seconds (with
/// what it plays, the position and whether it is paused) and waits for commands from other devices
/// (play, pause, resume, seek, skip, stop). Unlike the Mac app, the position of "play" and the
/// pause state are honored. Runs while a profile is open.
/// </summary>
public sealed class PlayOnReceiver(PlaybackClient client, ISettingsStore settings, string deviceName, IPlayOnTarget target, Action<Action> post, TimeProvider time)
{
    public const string DeviceIdKey = "deviceId";
    public static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(15);

    /// <summary>A stable id for this computer, made once and kept in the settings.</summary>
    public static string DeviceId(ISettingsStore settings)
    {
        var id = settings.Read<string>(DeviceIdKey);
        if (Guid.TryParse(id, out _)) return id!;
        id = Guid.NewGuid().ToString();
        settings.Write(DeviceIdKey, id);
        return id;
    }

    public Task RunAsync(CancellationToken cancellation) => Task.WhenAll(HeartbeatLoopAsync(cancellation), CommandLoopAsync(cancellation));

    private async Task HeartbeatLoopAsync(CancellationToken cancellation)
    {
        var id = DeviceId(settings);
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                await client.HeartbeatAsync(await SnapshotAsync(id), cancellation);
            }
            catch (AureliaApiException failure) when (failure.Status == 404)
            {
                return;
            }
            catch (Exception failure) when (failure is AureliaApiException or OperationCanceledException)
            {
                if (cancellation.IsCancellationRequested) return;
            }
            try
            {
                await Task.Delay(HeartbeatInterval, time, cancellation);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private Task<PlayerHeartbeatRequest> SnapshotAsync(string id)
    {
        var done = new TaskCompletionSource<PlayerHeartbeatRequest>();
        post(() =>
        {
            var player = target.Player;
            done.SetResult(new PlayerHeartbeatRequest(id, deviceName, "linux", player is not null, player?.Item?.Id, player?.Item?.Title,
                player is null ? null : player.Position / 1000.0, player is null ? null : player.Duration / 1000.0, player?.State == PlayerState.Paused));
        });
        return done.Task;
    }

    private async Task CommandLoopAsync(CancellationToken cancellation)
    {
        var id = DeviceId(settings);
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                foreach (var command in await client.CommandsAsync(id, cancellation)) post(() => Apply(command));
            }
            catch (AureliaApiException failure) when (failure.Status == 404)
            {
                return;
            }
            catch (Exception failure) when (failure is AureliaApiException or OperationCanceledException)
            {
                if (cancellation.IsCancellationRequested) return;
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(2), time, cancellation);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
    }

    internal void Apply(RemotePlaybackCommand command)
    {
        var player = target.Player;
        switch (command.Action)
        {
            case "play" when command.MediaId is { } media:
                target.Play(media, command.PositionSeconds);
                break;
            case "pause" when player?.State == PlayerState.Playing:
                player.PlayPause();
                break;
            case "resume" when player?.State == PlayerState.Paused:
                player.PlayPause();
                break;
            case "seek" when player is not null && command.PositionSeconds is { } seconds:
                player.SeekTo((long)(seconds * 1000));
                break;
            case "skip" when player is not null && command.SkipSeconds is { } skip:
                player.SeekTo(player.Position + (long)(skip * 1000));
                break;
            case "stop" when player is not null:
                _ = player.CloseAsync();
                break;
        }
    }
}

/// <summary>
/// Play On, sending side: other players in the household, and remote control of one of them. The
/// remote's status is checked every 2.5 seconds; it ends when the device stops playing.
/// </summary>
public sealed class RemotePlayback(PlaybackClient client, ISettingsStore settings, TimeProvider time) : ObservableObject, IDisposable
{
    public static readonly TimeSpan StatusInterval = TimeSpan.FromSeconds(2.5);
    private RemotePlayerDevice? device;
    private CancellationTokenSource? polling;

    /// <summary>The device being controlled, with its last reported state, or null.</summary>
    public RemotePlayerDevice? Device
    {
        get => device;
        private set => SetProperty(ref device, value);
    }

    public async Task<IReadOnlyList<RemotePlayerDevice>> PlayersAsync()
    {
        try
        {
            return await client.PlayersAsync(PlayOnReceiver.DeviceId(settings), CancellationToken.None);
        }
        catch (AureliaApiException)
        {
            return [];
        }
    }

    public async Task PlayAsync(RemotePlayerDevice target, CatalogItemSummary item)
    {
        var resume = item.Progress is { IsCompleted: false } progress ? progress.PositionMilliseconds / 1000.0 : (double?)null;
        await client.SendCommandAsync(target.DeviceId, new RemotePlaybackCommandRequest("play", item.Id, resume), CancellationToken.None);
        Device = target;
        polling?.Cancel();
        polling = new CancellationTokenSource();
        _ = PollAsync(target.DeviceId, polling.Token);
    }

    public Task SendAsync(string action, double? seconds = null)
    {
        if (Device is not { } target) return Task.CompletedTask;
        var request = action switch
        {
            "seek" => new RemotePlaybackCommandRequest("seek", PositionSeconds: seconds),
            "skip" => new RemotePlaybackCommandRequest("skip", SkipSeconds: seconds),
            _ => new RemotePlaybackCommandRequest(action),
        };
        if (action == "stop") Stop();
        return client.SendCommandAsync(target.DeviceId, request, CancellationToken.None);
    }

    public void Stop()
    {
        polling?.Cancel();
        Device = null;
    }

    public void Dispose()
    {
        polling?.Cancel();
        polling?.Dispose();
    }

    private async Task PollAsync(string deviceId, CancellationToken cancellation)
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(StatusInterval, time, cancellation);
                Device = await client.PlayerStatusAsync(deviceId, cancellation);
            }
            catch (AureliaApiException failure) when (failure.Status is 404 or 409)
            {
                Device = null;
                return;
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (AureliaApiException)
            {
            }
        }
    }
}
