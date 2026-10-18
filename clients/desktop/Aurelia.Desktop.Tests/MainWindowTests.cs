using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Media.Imaging;
using Aurelia.Desktop.Views;
using Xunit;

namespace Aurelia.Desktop.Tests;

public sealed class MainWindowTests
{
    [AvaloniaFact]
    public void ShowsTheSidebarAndHowToConnect()
    {
        var window = new MainWindow();
        window.Show();

        var navigation = window.FindControl<ListBox>("Navigation")!;
        Assert.Equal(["Home", "Movies", "TV Shows", "Search"],
            navigation.Items.Cast<ListBoxItem>().Select(item => item.Content as string));
        Assert.Equal(0, navigation.SelectedIndex);
        Assert.Equal("Connect to your Aurelia server", window.FindControl<TextBlock>("ConnectTitle")!.Text);
        // Connecting is not built yet, so the button must not pretend to work.
        Assert.False(window.FindControl<Button>("ConnectButton")!.IsEnabled);
        Assert.StartsWith("Version ", window.FindControl<TextBlock>("VersionLabel")!.Text);

        var frame = window.CaptureRenderedFrame();
        Assert.NotNull(frame);
        if (Environment.GetEnvironmentVariable("AURELIA_DESKTOP_RENDER") is { Length: > 0 } path)
            frame.Save(path, PngBitmapEncoderOptions.Default);
    }

    [Theory]
    [InlineData("0.0.1+build.1", "Version 0.0.1 (1)")]
    [InlineData("0.0.1+build.1.4f2c9e1", "Version 0.0.1 (1)")]
    [InlineData("0.2.0", "Version 0.2.0")]
    [InlineData(null, "Version unknown")]
    public void VersionLabelReadsTheBuildNumber(string? informational, string expected) =>
        Assert.Equal(expected, AppInfo.Label(informational));
}
