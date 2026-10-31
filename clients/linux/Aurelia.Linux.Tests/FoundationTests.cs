using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class SettingsTests : IDisposable
{
    private readonly string folder = Path.Combine(Path.GetTempPath(), "aurelia-linux-tests-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
    }

    [Fact]
    public void KeepsValuesAcrossRestarts()
    {
        var path = Path.Combine(folder, "settings.json");
        var first = new JsonFileSettingsStore(path);
        first.Write("operatingMode", "client");
        first.Write("sidebarWidth", 250.5);
        first.Remove("missing");

        var second = new JsonFileSettingsStore(path);
        Assert.Equal("client", second.Read<string>("operatingMode"));
        Assert.Equal(250.5, second.Read<double>("sidebarWidth"));
        Assert.Null(second.Read<string>("missing"));
    }

    [Fact]
    public void OnlyThisUserMayReadTheFile()
    {
        if (OperatingSystem.IsWindows())
        {
            Assert.Skip("Unix permissions only.");
            return;
        }
        var path = Path.Combine(folder, "nested", "settings.json");
        new JsonFileSettingsStore(path).Write("a", 1);
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(path));
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute, File.GetUnixFileMode(Path.GetDirectoryName(path)!));
    }

    [Fact]
    public void ADamagedFileIsSetAsideAndDefaultsApply()
    {
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, "settings.json");
        File.WriteAllText(path, "{ not json");
        var store = new JsonFileSettingsStore(path);
        Assert.Null(store.Read<string>("operatingMode"));
        Assert.True(File.Exists(path + ".damaged"));
    }

    [Fact]
    public void AWrongTypeReadsAsDefault()
    {
        var store = new JsonFileSettingsStore(Path.Combine(folder, "settings.json"));
        store.Write("value", "text");
        Assert.Equal(0, store.Read<int>("value"));
    }

    [Fact]
    public void FollowsTheXdgFolders()
    {
        var environment = new Dictionary<string, string?>
        {
            ["HOME"] = "/home/someone",
            ["XDG_CONFIG_HOME"] = "/custom/config",
            ["XDG_CACHE_HOME"] = "relative/is/ignored",
        };
        var paths = AppPaths.FromEnvironment(name => environment.GetValueOrDefault(name));
        Assert.Equal("/custom/config/aurelia-desktop", paths.ConfigDirectory);
        Assert.Equal("/home/someone/.cache/aurelia-desktop", paths.CacheDirectory);
        Assert.Equal("/home/someone/.local/state/aurelia-desktop", paths.StateDirectory);
        Assert.Equal("/custom/config/aurelia-desktop/settings.json", paths.SettingsFile);
    }
}

public sealed class WindowButtonLayoutTests
{
    [Fact]
    public void ReadsKdeLettersOnBothSides()
    {
        var layout = WindowButtonLayout.FromKde("XIA", "");
        Assert.Equal([WindowButton.Close, WindowButton.Minimize, WindowButton.Maximize], layout.Left);
        Assert.Empty(layout.Right);
    }

    [Fact]
    public void KdeDefaultsPutTheButtonsOnTheRight()
    {
        var layout = WindowButtonLayout.FromKde(null, null);
        Assert.Empty(layout.Left);
        Assert.Equal([WindowButton.Minimize, WindowButton.Maximize, WindowButton.Close], layout.Right);
    }

    [Theory]
    [InlineData("'appmenu:minimize,maximize,close'\n", new WindowButton[0], new[] { WindowButton.Minimize, WindowButton.Maximize, WindowButton.Close })]
    [InlineData("'close,minimize,maximize:'", new[] { WindowButton.Close, WindowButton.Minimize, WindowButton.Maximize }, new WindowButton[0])]
    [InlineData("close:", new[] { WindowButton.Close }, new WindowButton[0])]
    public void ReadsGnomeLayouts(string value, WindowButton[] left, WindowButton[] right)
    {
        var layout = WindowButtonLayout.FromGnome(value)!;
        Assert.Equal(left, layout.Left);
        Assert.Equal(right, layout.Right);
    }

    [Fact]
    public void ReadsTheKdeDecorationGroupOnly()
    {
        var layout = DesktopButtonLayoutReader.FromKwinrc(
        [
            "[Other]",
            "ButtonsOnLeft=A",
            "[org.kde.kdecoration2]",
            "BorderSize=Tiny",
            "ButtonsOnLeft=XIA",
            "ButtonsOnRight=",
        ]);
        Assert.Equal([WindowButton.Close, WindowButton.Minimize, WindowButton.Maximize], layout.Left);
        Assert.Empty(layout.Right);
    }

    [Fact]
    public void OtherDesktopsUseTheGnomeSettingOrTheDefault()
    {
        Assert.Equal(
            [WindowButton.Close],
            DesktopButtonLayoutReader.Read(name => name == "XDG_CURRENT_DESKTOP" ? "GNOME" : null, () => "'close:'").Left);
        Assert.Equal(
            WindowButtonLayout.Default.Right,
            DesktopButtonLayoutReader.Read(_ => null, () => null).Right);
    }
}

public sealed class AppFlowTests
{
    [Fact]
    public void StartsThenAsksWhereTheServerRuns()
    {
        var flow = new AppFlow(new MemorySettingsStore());
        Assert.Equal(AppScreen.Starting, flow.Screen);
        flow.FinishStarting();
        Assert.Equal(AppScreen.Welcome, flow.Screen);
    }

    [Fact]
    public void RemembersTheChosenMode()
    {
        var settings = new MemorySettingsStore();
        var flow = new AppFlow(settings);
        flow.FinishStarting();
        flow.ChooseMode(OperatingMode.Client);
        Assert.Equal(AppScreen.Connection, flow.Screen);

        var restarted = new AppFlow(settings);
        restarted.FinishStarting();
        Assert.Equal(OperatingMode.Client, restarted.Mode);
        Assert.Equal(AppScreen.Connection, restarted.Screen);
    }

    [Fact]
    public void HostingLeadsToHostSetupAndBackForgetsTheMode()
    {
        var settings = new MemorySettingsStore();
        var flow = new AppFlow(settings);
        flow.ChooseMode(OperatingMode.Host);
        Assert.Equal(AppScreen.HostSetup, flow.Screen);
        flow.ReturnToWelcome();
        Assert.Equal(AppScreen.Welcome, flow.Screen);
        Assert.Null(settings.Read<string>(AppFlow.OperatingModeKey));
    }
}
