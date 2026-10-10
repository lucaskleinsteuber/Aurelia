using System.Text.Json;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerDiagnosticsStoreTests
{
    [Fact]
    public async Task UnchangedHistoryDoesNotWriteAgain()
    {
        using var fixture = new Fixture();
        await fixture.Store.FlushAsync(CancellationToken.None);
        Assert.False(File.Exists(fixture.HistoryPath));

        fixture.Store.Record("synthetic_event", "information");
        await fixture.Store.FlushAsync(CancellationToken.None);
        var sentinel = new DateTime(2020, 1, 2, 3, 4, 5, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(fixture.HistoryPath, sentinel);
        await fixture.Store.FlushAsync(CancellationToken.None);

        Assert.Equal(sentinel, File.GetLastWriteTimeUtc(fixture.HistoryPath));
        Assert.Single(await fixture.ReadHistoryAsync());
    }

    [Fact]
    public async Task ExpiryPersistsWithoutReceivingAnotherEvent()
    {
        using var fixture = new Fixture();
        fixture.Store.Record("synthetic_event", "information");
        await fixture.Store.FlushAsync(CancellationToken.None);
        fixture.Clock.Advance(TimeSpan.FromDays(31));
        await fixture.Store.FlushAsync(CancellationToken.None);

        Assert.Empty(fixture.Store.Read());
        Assert.Empty(await fixture.ReadHistoryAsync());
    }

    [Fact]
    public async Task RetentionAndCountSettingChangesApplyWithoutNewEvents()
    {
        using var fixture = new Fixture();
        fixture.Configuration.Update(fixture.Configuration.Current with { MaximumEvents = 200 });
        for (var index = 0; index < 200; index++)
            fixture.Store.Record("synthetic_event", "information", status: index);
        await fixture.Store.FlushAsync(CancellationToken.None);

        fixture.Configuration.Update(fixture.Configuration.Current with { MaximumEvents = 100 });
        await fixture.Store.FlushAsync(CancellationToken.None);
        var retained = await fixture.ReadHistoryAsync();
        Assert.Equal(100, retained.Length);
        Assert.Equal(100, retained[0].Status);

        fixture.Clock.Advance(TimeSpan.FromDays(2));
        fixture.Configuration.Update(fixture.Configuration.Current with { EventRetentionDays = 1 });
        await fixture.Store.FlushAsync(CancellationToken.None);
        Assert.Empty(await fixture.ReadHistoryAsync());
    }

    [Fact]
    public async Task FailedWriteIsRetriedWithoutLosingThePendingSnapshot()
    {
        using var fixture = new Fixture();
        Directory.CreateDirectory(fixture.HistoryPath);
        fixture.Store.Record("synthetic_event", "warning");
        await fixture.Store.FlushAsync(CancellationToken.None);
        Assert.Single(fixture.Store.Read());
        Assert.Empty(Directory.GetFiles(fixture.Root, "*.pending"));

        Directory.Delete(fixture.HistoryPath);
        await fixture.Store.FlushAsync(CancellationToken.None);
        Assert.Single(await fixture.ReadHistoryAsync());
        Assert.Empty(Directory.GetFiles(fixture.Root, "*.pending"));
    }

    [Fact]
    public async Task ConcurrentFlushesSerializeAndDoNotDropQueuedEvents()
    {
        using var fixture = new Fixture();
        fixture.Store.Record("synthetic_one", "information");
        var first = fixture.Store.FlushAsync(CancellationToken.None);
        fixture.Store.Record("synthetic_two", "information");
        await Task.WhenAll(first, fixture.Store.FlushAsync(CancellationToken.None));
        Assert.Equal(2, (await fixture.ReadHistoryAsync()).Length);
    }

    private sealed class Fixture : IDisposable
    {
        private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
        public Fixture()
        {
            Directory.CreateDirectory(Root);
            var runtime = new ServerRuntimeOptions(Root, Path.Combine(Root, "unused.db"),
                "http://127.0.0.1:43110", "Synthetic Diagnostics", false, 43111,
                Path.Combine(Root, "unused.pem"), Path.Combine(Root, "unused-key.pem"), null);
            Configuration = new(runtime);
            Store = new(runtime, Configuration, Clock);
        }

        public string Root { get; } = TestPaths.CreateDataDirectory();
        public string HistoryPath => Path.Combine(Root, "server-events.json");
        public MutableClock Clock { get; } = new();
        public ServerConfigurationStore Configuration { get; }
        public ServerDiagnosticsStore Store { get; }
        public async Task<ServerEvent[]> ReadHistoryAsync() =>
            JsonSerializer.Deserialize<ServerEvent[]>(await File.ReadAllTextAsync(HistoryPath),
                Json)!;

        public void Dispose()
        {
            Store.Dispose();
            if (Directory.Exists(Root)) Directory.Delete(Root, recursive: true);
        }
    }

    private sealed class MutableClock : TimeProvider
    {
        private DateTimeOffset current = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => current;
        public void Advance(TimeSpan duration) => current += duration;
    }
}
