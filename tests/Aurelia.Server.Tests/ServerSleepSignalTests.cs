using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerSleepSignalTests
{
    [Fact]
    public void AnEndedSleepTimerLetsTheServerSleepAfterFiveQuietMinutes()
    {
        using var fixture = new Fixture();
        fixture.Signal.SleepTimerEnded();
        Assert.False(fixture.Signal.Evaluate());
        fixture.Clock.Advance(TimeSpan.FromMinutes(4));
        Assert.False(fixture.Signal.Evaluate());
        Assert.False(File.Exists(fixture.ReadyPath));
        fixture.Clock.Advance(TimeSpan.FromMinutes(1));
        Assert.True(fixture.Signal.Evaluate());
        Assert.True(File.Exists(fixture.ReadyPath));

        // One timer leads to one sleep; a new playback removes a file nobody consumed.
        Assert.False(fixture.Signal.Evaluate());
        fixture.Signal.PlaybackStarted();
        Assert.False(File.Exists(fixture.ReadyPath));
    }

    [Fact]
    public void PlaybackOnAnyDeviceKeepsTheServerAwake()
    {
        using var fixture = new Fixture();
        fixture.Signal.SleepTimerEnded();
        fixture.Signal.PlaybackStarted();
        fixture.Clock.Advance(TimeSpan.FromMinutes(6));
        Assert.False(fixture.Signal.Evaluate());

        // Someone else is still watching when the timer ends: their stream keeps sending data.
        fixture.Signal.SleepTimerEnded();
        using (var lease = fixture.Streams.Enter(Guid.NewGuid(), Guid.NewGuid(), 32, 4, CancellationToken.None))
        {
            for (var minute = 1; minute <= 3; minute++)
            {
                fixture.Clock.Advance(TimeSpan.FromMinutes(1));
                lease.MarkRead();
                Assert.False(fixture.Signal.Evaluate());
            }
        }
        fixture.Clock.Advance(TimeSpan.FromMinutes(6));
        Assert.False(fixture.Signal.Evaluate());
        Assert.False(File.Exists(fixture.ReadyPath));
    }

    [Fact]
    public void APausedPlayerHoldingItsStreamOpenDoesNotKeepTheServerAwake()
    {
        using var fixture = new Fixture();
        using var lease = fixture.Streams.Enter(Guid.NewGuid(), Guid.NewGuid(), 32, 4, CancellationToken.None);
        fixture.Signal.SleepTimerEnded();
        // The player fills its buffer for a moment after pausing, then sends nothing more.
        fixture.Clock.Advance(TimeSpan.FromSeconds(40));
        lease.MarkRead();
        Assert.False(fixture.Signal.Evaluate());
        fixture.Clock.Advance(TimeSpan.FromMinutes(5));
        Assert.True(fixture.Signal.Evaluate());
        Assert.True(File.Exists(fixture.ReadyPath));
        Assert.Equal(1, fixture.Streams.PlaybackCount);
    }

    [Fact]
    public async Task ReadsThroughTheMediaStreamCountAsWatchingAndKeepItsBytes()
    {
        using var fixture = new Fixture();
        using var lease = fixture.Streams.Enter(Guid.NewGuid(), Guid.NewGuid(), 32, 4, CancellationToken.None);
        fixture.Clock.Advance(TimeSpan.FromMinutes(3));
        await using var stream = new PlaybackReadStream(new MemoryStream([1, 2, 3, 4, 5]), lease);
        stream.Seek(2, SeekOrigin.Begin);
        var buffer = new byte[8];
        Assert.Equal(3, await stream.ReadAsync(buffer));
        Assert.Equal([3, 4, 5], buffer[..3]);
        Assert.Equal(fixture.Clock.GetUtcNow(), fixture.Streams.LastPlaybackActivity);
        // Reaching the end sends nothing and notes nothing.
        fixture.Clock.Advance(TimeSpan.FromMinutes(1));
        Assert.Equal(0, await stream.ReadAsync(buffer));
        Assert.True(fixture.Streams.LastPlaybackActivity < fixture.Clock.GetUtcNow());
    }

    private sealed class Fixture : IDisposable
    {
        private readonly DirectoryInfo root = Directory.CreateTempSubdirectory("aurelia-sleep-");
        public Clock Clock { get; } = new();
        public ActiveStreamRegistry Streams { get; }
        public ServerSleepSignal Signal { get; }
        public string ReadyPath => Path.Combine(root.FullName, ServerSleepSignal.FileName);

        public Fixture()
        {
            var runtime = new ServerRuntimeOptions(root.FullName, Path.Combine(root.FullName, "unused.db"),
                "http://127.0.0.1:43110", "Synthetic", false, 43111, "", "", null);
            Streams = new ActiveStreamRegistry(Clock);
            Signal = new ServerSleepSignal(runtime, Streams, Clock);
        }

        public void Dispose() => root.Delete(recursive: true);
    }

    private sealed class Clock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan by) => now += by;
    }
}
