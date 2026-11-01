using Aurelia.Linux.Core.Platform;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class AppInstanceTests
{
    [Fact]
    public async Task ASecondLaunchRaisesTheExistingWindowWithoutStartingAnotherOwner()
    {
        var path = Path.Combine(Path.GetTempPath(), "aurelia-instance-" + Guid.NewGuid().ToString("N"));
        using var owner = new AppInstance(path);
        Assert.True(owner.IsOwner);
        var shown = 0;
        owner.OnShow(() => Interlocked.Increment(ref shown));
        await Task.Run(async () =>
        {
            using var second = new AppInstance(path);
            Assert.False(second.IsOwner);
            await second.NotifyExistingAsync(true, TestContext.Current.CancellationToken);
            await second.NotifyExistingAsync(false, TestContext.Current.CancellationToken);
        }, TestContext.Current.CancellationToken);
        Assert.Equal(1, Volatile.Read(ref shown));
    }

    [Fact]
    public async Task AnEarlyShowRequestWaitsForTheWindowCallback()
    {
        var path = Path.Combine(Path.GetTempPath(), "aurelia-instance-" + Guid.NewGuid().ToString("N"));
        using var owner = new AppInstance(path);
        await Task.Run(async () =>
        {
            using var second = new AppInstance(path);
            Assert.False(second.IsOwner);
            await second.NotifyExistingAsync(true, TestContext.Current.CancellationToken);
        }, TestContext.Current.CancellationToken);
        var shown = 0;
        owner.OnShow(() => shown++);
        Assert.Equal(1, shown);
    }

    [Fact]
    public void AClosedOwnerReleasesTheInstanceAndDifferentSettingsStayIsolated()
    {
        var path = Path.Combine(Path.GetTempPath(), "aurelia-instance-" + Guid.NewGuid().ToString("N"));
        using (var first = new AppInstance(path))
        {
            Assert.True(first.IsOwner);
            using var separate = new AppInstance(path + "-isolated");
            Assert.True(separate.IsOwner);
        }
        using var next = new AppInstance(path);
        Assert.True(next.IsOwner);
    }
}
