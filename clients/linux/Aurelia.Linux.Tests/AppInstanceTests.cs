using System.Diagnostics;
using System.Runtime.InteropServices;
using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class AppInstanceTests
{
    [Fact]
    public async Task ASecondProcessHandsOffWithADifferentLongTemporaryDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "aurelia-instance-process-" + Guid.NewGuid().ToString("N"));
        var config = Path.Combine(path, "config");
        var temporary = Path.Combine(path, new string('t', 140));
        Directory.CreateDirectory(temporary);
        try
        {
            using var owner = new AppInstance(Path.Combine(config, AppPaths.FolderName));
            Assert.True(owner.IsOwner);
            var executable = Path.GetFullPath(Path.Combine(RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", "..",
                OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet"));
            var start = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true };
            start.ArgumentList.Add(typeof(Program).Assembly.Location);
            // The real app entry point hands this off before graphics or settings initialization.
            start.ArgumentList.Add("--background");
            start.Environment["XDG_CONFIG_HOME"] = config;
            start.Environment["TMPDIR"] = temporary;
            start.Environment["TMP"] = temporary;
            start.Environment["TEMP"] = temporary;
            start.Environment["DISPLAY"] = "";
            start.Environment["WAYLAND_DISPLAY"] = "";
            using var child = Process.Start(start)!;
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(15));
            try
            {
                var output = child.StandardOutput.ReadToEndAsync(timeout.Token);
                var error = child.StandardError.ReadToEndAsync(timeout.Token);
                await child.WaitForExitAsync(timeout.Token);
                Assert.True(child.ExitCode == 0, $"Second app launch exited {child.ExitCode}: {await error}\n{await output}");
            }
            finally
            {
                if (!child.HasExited) child.Kill(entireProcessTree: true);
            }
            using var stillSecond = new AppInstance(Path.Combine(config, AppPaths.FolderName));
            Assert.False(stillSecond.IsOwner);
            await stillSecond.NotifyExistingAsync(false, TestContext.Current.CancellationToken);
        }
        finally
        {
            Directory.Delete(path, recursive: true);
        }
    }

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
