using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Core.Settings;
using Avalonia.Headless.XUnit;
using Avalonia.Threading;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class PlayOnReceiverTests
{
    private static RemotePlaybackCommand Command(string action, Guid? media = null, double? position = null, double? skip = null) =>
        new(Guid.NewGuid(), action, media, position, skip, DateTimeOffset.UtcNow);

    [AvaloniaFact]
    public void EveryRemoteCommandUsesTheProductionPlayerAndHonorsItsState()
    {
        var engines = new SimulatedEngines();
        var server = FakeLibrary.Create(pictures: false);
        var window = FakeLibrary.ShowLibrary(server, engines);
        var library = window.Session.Library!;
        var item = library.Catalog.Single(i => i.Id == FakeLibrary.MovieA);
        server.Answer("GET", $"/api/v1/catalog/items/{item.Id}/summary", JsonSerializer.Serialize(item, AureliaJson.Options));
        var receiver = new PlayOnReceiver(new PlaybackClient(window.Session.Api, library.Client), new MemorySettingsStore(), "Synthetic PC", window,
            action => Dispatcher.UIThread.Post(action), TimeProvider.System);

        receiver.Apply(Command("play", item.Id, position: 123.456));
        FakeLibrary.Pump(() => window.Player?.State == PlayerState.Playing);
        Assert.Equal(123_456, engines.Last.OpenedAt);
        receiver.Apply(Command("pause"));
        FakeLibrary.Pump(() => window.Player?.State == PlayerState.Paused);
        Assert.False(engines.Last.IsPlaying);
        receiver.Apply(Command("pause"));
        Assert.False(engines.Last.IsPlaying);
        receiver.Apply(Command("resume"));
        FakeLibrary.Pump(() => window.Player?.State == PlayerState.Playing);
        Assert.True(engines.Last.IsPlaying);
        receiver.Apply(Command("resume"));
        Assert.True(engines.Last.IsPlaying);
        receiver.Apply(Command("seek", position: 250.125));
        FakeLibrary.Pump(() => window.Player!.Position == 250_125);
        Assert.Equal(250_125, engines.Last.Time);
        receiver.Apply(Command("skip", skip: -15.5));
        FakeLibrary.Pump(() => window.Player!.Position == 234_625);
        Assert.Equal(234_625, engines.Last.Time);
        receiver.Apply(Command("seek", position: -100));
        FakeLibrary.Pump(() => window.Player!.Position == 0);
        Assert.Equal(0, engines.Last.Time);
        var count = engines.Created.Count;
        receiver.Apply(Command("unknown"));
        receiver.Apply(Command("play"));
        Assert.Equal(count, engines.Created.Count);
        var engine = engines.Last;
        receiver.Apply(Command("stop"));
        FakeLibrary.Pump(() => window.Player is null);
        Assert.Null(window.Player);
        Assert.True(engine.Unloaded);
        // A command with no explicit position follows the normal saved-resume rule.
        receiver.Apply(Command("play", item.Id));
        FakeLibrary.Pump(() => window.Player?.State == PlayerState.Playing);
        Assert.Equal(1_200_000, engines.Last.OpenedAt);
        receiver.Apply(Command("stop"));
        FakeLibrary.Pump(() => window.Player is null);
        window.Session.Rest();
        window.Close();
    }

    [AvaloniaFact]
    public async Task TheHeartbeatReportsPausedPlaybackThroughTheUiDispatch()
    {
        var engines = new SimulatedEngines();
        var server = FakeLibrary.Create(pictures: false)
            .Answer("POST", "/api/v1/devices/player/heartbeat", JsonSerializer.Serialize(new PlayerHeartbeatResponse(true, DateTimeOffset.UtcNow), AureliaJson.Options));
        var time = new ManualTime();
        var window = FakeLibrary.ShowLibrary(server, engines, time);
        var library = window.Session.Library!;
        var playing = window.PlayAsync(library.Catalog.Single(i => i.Id == FakeLibrary.MovieA), resume: true);
        FakeLibrary.Pump(() => playing.IsCompleted && window.Player?.State == PlayerState.Playing);
        window.Player!.PlayPause();
        FakeLibrary.Pump(() => window.Player.State == PlayerState.Paused);
        server.Bodies.Remove("POST /api/v1/devices/player/heartbeat");
        var queued = new Queue<Action>();
        var settings = new MemorySettingsStore();
        var receiver = new PlayOnReceiver(new PlaybackClient(window.Session.Api, library.Client), settings, "Synthetic PC", window, queued.Enqueue, time);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var receiving = receiver.RunAsync(cancellation.Token);
        Assert.NotEmpty(queued);
        while (queued.Count > 0) queued.Dequeue()();
        FakeLibrary.Pump(() => server.Bodies.ContainsKey("POST /api/v1/devices/player/heartbeat"));
        var heartbeat = JsonSerializer.Deserialize<PlayerHeartbeatRequest>(server.Bodies["POST /api/v1/devices/player/heartbeat"], AureliaJson.Options)!;
        Assert.True(heartbeat.IsPlaying);
        Assert.True(heartbeat.IsPaused);
        Assert.Equal(FakeLibrary.MovieA, heartbeat.MediaId);
        Assert.Equal(1_200, heartbeat.PositionSeconds);
        Assert.Equal(PlayOnReceiver.DeviceId(settings), heartbeat.DeviceId);
        cancellation.Cancel();
        await receiving.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        await window.Player.CloseAsync();
        window.Session.Rest();
        window.Close();
    }
}
