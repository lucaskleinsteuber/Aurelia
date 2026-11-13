using Aurelia.Contracts;
using Aurelia.Linux.Core.Management;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class WakeCheckTests
{
    private static readonly ServerPowerSettings Server = new(true, "sleep", 15, null, null, WakeSupport: "pumbg", Hosting: "linuxServer",
        Network: "wired", WakeOn: "g", SleepKind: "deep");

    private static string[] Titles(ServerPowerSettings power, string mode) =>
        [.. (WakeCheckText.Items(power, mode) ?? []).Select(item => $"{item.State}: {item.Title}")];

    [Fact]
    public void TheCheckSaysWhatTheServerFoundAndWhatOnlyATestShows()
    {
        Assert.Equal(["Ok: Connected by cable", "Ok: Wake-on-LAN is on", "Ok: Real sleep", "Info: Try it once"], Titles(Server, "sleep"));
        Assert.Equal(["Ok: Connected by cable", "Ok: Wake-on-LAN is on", "Info: Waking from off needs the BIOS", "Info: Try it once"], Titles(Server, "shutdown"));
        Assert.Contains("Power On By PCI-E", WakeCheckText.Items(Server, "shutdown")![2].Detail, StringComparison.Ordinal);
        Assert.Equal(["Problem: Connected by Wi-Fi", "Warning: Wake-on-LAN is off right now", "Warning: Only light sleep", "Info: Try it once"],
            Titles(Server with { Network = "wifi", WakeOn = "d", SleepKind = "light" }, "sleep"));
        Assert.Equal(["Problem: The network card can't wake the computer", "Problem: This computer can't sleep"],
            Titles(Server with { WakeSupport = "d", SleepKind = "none" }, "sleep")[1..3]);
        // An older server sends none of it.
        Assert.Equal(["Info: Network card not checked yet", "Info: Try it once"],
            Titles(new ServerPowerSettings(true, "sleep", 15, null, null, WakeSupport: "pumbg"), "sleep"));
    }

    [Fact]
    public void NothingIsCheckedWhereNothingWakesOverTheNetwork()
    {
        Assert.Null(WakeCheckText.Items(Server, "off"));
        Assert.Null(WakeCheckText.Items(Server, "stop"));
        Assert.Null(WakeCheckText.Items(Server with { Hosting = "linuxApp" }, "sleep"));
        Assert.Null(WakeCheckText.Items(Server with { Available = false }, "sleep"));
    }
}
