using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Hosting;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class HostedEnvironmentTests
{
    [Fact]
    public void TheFlatpakServerUsesRuntimeEncodersInsteadOfTheAppsDecoderLibraries()
    {
        var environment = new Dictionary<string, string?>
        {
            ["FLATPAK_ID"] = AppInfo.ApplicationId,
            ["LD_LIBRARY_PATH"] = "/app/lib:/usr/lib/runtime:/app/lib/vlc:/app/lib64",
            ["VLC_PLUGIN_PATH"] = "/app/lib/vlc/plugins",
            ["AURELIA_HOST_LIFELINE"] = "1",
        };
        HostedServerEnvironment.Configure(environment);
        Assert.Equal("/usr/lib/runtime", environment["LD_LIBRARY_PATH"]);
        Assert.False(environment.ContainsKey("VLC_PLUGIN_PATH"));
        Assert.Equal("1", environment["AURELIA_HOST_LIFELINE"]);
        environment["LD_LIBRARY_PATH"] = "/app/lib";
        HostedServerEnvironment.Configure(environment);
        Assert.False(environment.ContainsKey("LD_LIBRARY_PATH"));
    }

    [Fact]
    public void NativeHostingPreservesTheDistributionsLibraryConfiguration()
    {
        var environment = new Dictionary<string, string?> { ["LD_LIBRARY_PATH"] = "/custom/lib", ["VLC_PLUGIN_PATH"] = "/custom/vlc" };
        HostedServerEnvironment.Configure(environment);
        Assert.Equal("/custom/lib", environment["LD_LIBRARY_PATH"]);
        Assert.Equal("/custom/vlc", environment["VLC_PLUGIN_PATH"]);
    }
}
