using System.Text.Json.Nodes;
using Aurelia.Linux.Core.Hosting;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class HostingRaceTests
{
    private sealed class DeadlineClock(DateTimeOffset before, DateTimeOffset after) : TimeProvider, IDisposable
    {
        private readonly ManualResetEventSlim release = new();
        private int calls;
        public TaskCompletionSource CheckingConfirmation { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public override DateTimeOffset GetUtcNow()
        {
            if (Interlocked.Increment(ref calls) != 1) return after;
            CheckingConfirmation.TrySetResult();
            Assert.True(release.Wait(TimeSpan.FromSeconds(10)), "Confirmation was not released by the test.");
            return before;
        }

        public void Release() => release.Set();
        public void Dispose() => release.Dispose();
    }

    [Fact]
    public async Task AConfirmationBeforeTheDeadlineCannotBeOverwrittenByTheWatchdog()
    {
        var root = Path.Combine(Path.GetTempPath(), "aurelia-host-race-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var id = Guid.NewGuid();
        var deadline = DateTimeOffset.UtcNow.AddSeconds(60);
        var settings = """{"version":2,"serverName":"Confirmed","lanAccessEnabled":false,"lanHttpsPort":45111,"revision":3}""";
        var journal = JsonNode.Parse($$$"""
            {"version":1,"id":"{{{id}}}","kind":"network","state":"awaitingConfirmation","confirmBefore":"{{{deadline:O}}}",
             "previousSettings":{"version":2,"serverName":"Previous","lanAccessEnabled":false,"lanHttpsPort":43111,"revision":4}}
            """)!;
        await File.WriteAllTextAsync(Path.Combine(root, "server-settings.json"), settings, TestContext.Current.CancellationToken);
        await File.WriteAllTextAsync(Path.Combine(root, "host-operation.json"), journal.ToJsonString(), TestContext.Current.CancellationToken);
        using var time = new DeadlineClock(deadline.AddMilliseconds(-1), deadline.AddMilliseconds(1));
        await using var host = new LocalServerHost(new LocalServerOptions("missing-synthetic-server", root, Path.Combine(root, "logs"), 43110, 43111, false, "Synthetic"), time);
        try
        {
            var confirming = Task.Run(() => host.ConfirmNetwork(new JsonObject { ["id"] = id.ToString() }), TestContext.Current.CancellationToken);
            await time.CheckingConfirmation.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
            var watchdogStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var watchdog = Task.Run(async () =>
            {
                watchdogStarted.TrySetResult();
                await host.RollBackExpiredTrialAsync();
            }, TestContext.Current.CancellationToken);
            await watchdogStarted.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
            // The confirmation owns the journal while the deadline passes. The watchdog must
            // reread the completed state after that transaction, rather than applying its snapshot.
            time.Release();
            Assert.True(await confirming);
            await watchdog;
            Assert.Equal(settings, await File.ReadAllTextAsync(Path.Combine(root, "server-settings.json"), TestContext.Current.CancellationToken));
            journal = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(root, "host-operation.json"), TestContext.Current.CancellationToken))!;
            Assert.Equal("completed", journal["state"]!.GetValue<string>());
            Assert.Null(journal["previousSettings"]);
        }
        finally
        {
            time.Release();
            Directory.Delete(root, recursive: true);
        }
    }
}
