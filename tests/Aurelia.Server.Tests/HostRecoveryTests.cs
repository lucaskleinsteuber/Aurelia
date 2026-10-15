using Aurelia.Server.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class HostRecoveryTests
{
    [Fact]
    public async Task BonjourShutdownIsIdempotentWhenHostStopAndDisposalOverlap()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var service = factory.Services.GetServices<Microsoft.Extensions.Hosting.IHostedService>()
            .OfType<BonjourAdvertisementService>().Single();
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var tasks = Enumerable.Range(0, 32).Select(async index =>
        {
            await ready.Task;
            if (index % 2 == 0) await service.StopAsync(CancellationToken.None);
            else await service.DisposeAsync();
        }).ToArray();
        ready.SetResult();
        await Task.WhenAll(tasks);
    }

    [Fact]
    public async Task ServerShutdownCancelsPendingRequestsAndRestoresTheirOriginalToken()
    {
        using var stopping = new CancellationTokenSource();
        using var client = new CancellationTokenSource();
        var context = new DefaultHttpContext { RequestAborted = client.Token };
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var request = ServerShutdownRequest.RunAsync(context, async current =>
        {
            started.SetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, current.RequestAborted);
        }, stopping.Token);
        await started.Task;
        stopping.Cancel();
        await request.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(client.Token, context.RequestAborted);
        Assert.False(client.IsCancellationRequested);
    }

    [Fact]
    public async Task ClientCancellationIsNotMistakenForServerShutdown()
    {
        using var client = new CancellationTokenSource();
        var context = new DefaultHttpContext { RequestAborted = client.Token };
        client.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ServerShutdownRequest.RunAsync(
            context, current => Task.Delay(Timeout.InfiniteTimeSpan, current.RequestAborted), CancellationToken.None));
        Assert.Equal(client.Token, context.RequestAborted);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(3)]
    public async Task ClosedHostLifelineRequestsOneGracefulShutdown(int bufferedBytes)
    {
        using var input = new MemoryStream(new byte[bufferedBytes]);
        var stops = 0;
        await ParentProcessMonitor.MonitorLifelineAsync(input, () => stops++, CancellationToken.None);
        Assert.Equal(1, stops);
    }

    [Fact]
    public async Task OrdinaryServiceCancellationDoesNotRequestAnotherShutdown()
    {
        using var input = new MemoryStream();
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var stops = 0;
        await ParentProcessMonitor.MonitorLifelineAsync(input, () => stops++, cancellation.Token);
        Assert.Equal(0, stops);
    }

    [Fact]
    public async Task CancellationDoesNotWaitForAnUninterruptibleInputRead()
    {
        using var input = new NonCancellableInput();
        using var cancellation = new CancellationTokenSource();
        var stops = 0;
        var monitor = ParentProcessMonitor.MonitorLifelineAsync(input, () => stops++, cancellation.Token);
        cancellation.Cancel();
        await monitor.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(0, stops);
    }

    private sealed class NonCancellableInput : MemoryStream
    {
        private readonly TaskCompletionSource<int> pending = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
            => new(pending.Task);
    }

    [Fact]
    public async Task HostStartupWaitsForThePreviousInstanceToReleaseItsLock()
    {
        var directory = TestPaths.CreateDataDirectory();
        try
        {
            using var previous = ServerInstanceLock.Acquire(directory);
            var pending = ServerInstanceLock.AcquireForHostAsync(directory, CancellationToken.None);
            Assert.False(pending.IsCompleted);
            previous.Dispose();
            using var recovered = await pending.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.True(File.Exists(Path.Combine(directory, "server.lock")));
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public async Task CancelledHostStartupDoesNotBypassTheExistingInstanceLock()
    {
        var directory = TestPaths.CreateDataDirectory();
        try
        {
            using var previous = ServerInstanceLock.Acquire(directory);
            using var cancellation = new CancellationTokenSource();
            var pending = ServerInstanceLock.AcquireForHostAsync(directory, cancellation.Token);
            cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
            Assert.Throws<InvalidOperationException>(() => ServerInstanceLock.Acquire(directory));
        }
        finally { Directory.Delete(directory, recursive: true); }
    }
}
