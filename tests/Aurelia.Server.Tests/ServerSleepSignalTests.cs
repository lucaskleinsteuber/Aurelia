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

        // Someone else is still watching when the timer ends.
        fixture.Signal.SleepTimerEnded();
        using (fixture.Streams.Enter(Guid.NewGuid(), Guid.NewGuid(), 32, 4, CancellationToken.None))
        {
            fixture.Clock.Advance(TimeSpan.FromMinutes(1));
            Assert.False(fixture.Signal.Evaluate());
        }
        fixture.Clock.Advance(TimeSpan.FromMinutes(6));
        Assert.False(fixture.Signal.Evaluate());
        Assert.False(File.Exists(fixture.ReadyPath));
    }

    private sealed class Fixture : IDisposable
    {
        private readonly DirectoryInfo root = Directory.CreateTempSubdirectory("aurelia-sleep-");
        public Clock Clock { get; } = new();
        public ActiveStreamRegistry Streams { get; } = new();
        public ServerSleepSignal Signal { get; }
        public string ReadyPath => Path.Combine(root.FullName, ServerSleepSignal.FileName);

        public Fixture()
        {
            var runtime = new ServerRuntimeOptions(root.FullName, Path.Combine(root.FullName, "unused.db"),
                "http://127.0.0.1:43110", "Synthetic", false, 43111, "", "", null);
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
