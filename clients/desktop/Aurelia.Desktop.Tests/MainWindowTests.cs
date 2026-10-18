using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Interactivity;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Aurelia.Desktop.Core;
using Aurelia.Desktop.Views;
using Xunit;

namespace Aurelia.Desktop.Tests;

/// <summary>The real window and styles, rendered off screen with Skia; no window appears.</summary>
public sealed class MainWindowTests
{
    [AvaloniaFact]
    public async Task EachConnectionStepShowsItsOwnScreen()
    {
        var (flow, _, _) = ConnectionFlowTests.Create();
        var window = new MainWindow(flow, _ => new FakeLibraryApi(), _ => new FakeEngineFactory(), TemporarySettings(), startOnOpen: false,
            artworkCache: _ => null);
        window.Show();
        await flow.StartAsync();
        Settle(window, "connect");
        Assert.True(window.FindControl<StackPanel>("ConnectStep")!.IsVisible);
        Assert.Equal("Connect to your Aurelia server", window.FindControl<TextBlock>("ConnectTitle")!.Text);
        Assert.False(window.FindControl<LibraryView>("Library")!.IsVisible);

        // Typing an address and pressing Continue reads the server's identity.
        window.FindControl<TextBox>("ServerAddress")!.Text = "192.168.1.20";
        window.FindControl<Button>("ConnectButton")!.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await WaitFor(() => flow.ShowsTrust);
        Settle(window, "trust");
        Assert.True(window.FindControl<StackPanel>("TrustStep")!.IsVisible);
        Assert.Equal("AAAA-AAAA-AAAA-AAAA-AAAA-AAAA", window.FindControl<TextBlock>("Fingerprint")!.Text);

        await flow.TrustAndPairAsync();
        Settle(window, "profiles");
        Assert.True(window.FindControl<StackPanel>("ProfilesStep")!.IsVisible);
        Assert.Equal(2, window.FindControl<ItemsControl>("ProfileList")!.ItemCount);

        await flow.ChooseProfileAsync(FakeServerApi.Owner);
        Settle(window, "pin");
        Assert.True(window.FindControl<StackPanel>("PinStep")!.IsVisible);
        await flow.SubmitPinAsync("0000");
        Settle(window, "pin-error");
        Assert.Equal("That PIN is not correct.", window.FindControl<TextBlock>("ErrorText")!.Text);
        Assert.True(window.FindControl<TextBlock>("ErrorText")!.IsVisible);

        await flow.SubmitPinAsync("5682");
        Settle(window, "library");
        Assert.True(window.FindControl<LibraryView>("Library")!.IsVisible);
        Assert.False(window.FindControl<PlayerView>("Player")!.IsVisible);
    }

    [AvaloniaFact]
    public async Task ThePairingCodeIsShownLargeWhileWaiting()
    {
        // The server stays pending, so the waiting screen stays until Cancel.
        var api = new FakeServerApi { PendingPolls = int.MaxValue };
        var waiting = new TaskCompletionSource();
        var flow = new ConnectionFlow(api, new ConnectionStore(new MemorySecretStore()), new NoServerDiscovery(), "Synthetic PC",
            action => action(), delay: async (_, token) =>
            {
                waiting.TrySetResult();
                await Task.Delay(Timeout.Infinite, token);
            });
        var window = new MainWindow(flow, startOnOpen: false);
        window.Show();
        await flow.StartAsync();
        flow.Address = "192.168.1.20";
        await flow.ConnectAsync();
        var pairing = flow.TrustAndPairAsync();
        await waiting.Task;
        Settle(window, "pairing");
        Assert.True(window.FindControl<StackPanel>("PairingStep")!.IsVisible);
        Assert.Equal("4815 1623", window.FindControl<TextBlock>("PairingCode")!.Text);

        await flow.CancelPairingAsync();
        await pairing;
        Assert.Contains("cancel", api.Calls);
        Assert.True(flow.ShowsConnect);
    }

    [Theory]
    [InlineData("0.0.2+build.2", "Version 0.0.2 (2)")]
    [InlineData("0.0.2+build.2.4f2c9e1", "Version 0.0.2 (2)")]
    [InlineData("0.2.0", "Version 0.2.0")]
    [InlineData(null, "Version unknown")]
    public void VersionLabelReadsTheBuildNumber(string? informational, string expected) =>
        Assert.Equal(expected, AppInfo.Label(informational));

    internal static PlaybackSettingsStore TemporarySettings() =>
        new(Path.Combine(Path.GetTempPath(), "aurelia-desktop-settings-" + Guid.NewGuid().ToString("N"), "playback.json"));

    internal static void Settle(Window window, string name)
    {
        Dispatcher.UIThread.RunJobs();
        var frame = window.CaptureRenderedFrame();
        Assert.NotNull(frame);
        if (Environment.GetEnvironmentVariable("AURELIA_DESKTOP_RENDER_DIR") is { Length: > 0 } directory)
        {
            Directory.CreateDirectory(directory);
            frame.Save(Path.Combine(directory, name + ".png"), PngBitmapEncoderOptions.Default);
        }
    }

    internal static async Task WaitFor(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 200 && !condition(); attempt++)
        {
            Dispatcher.UIThread.RunJobs();
            await Task.Delay(5, TestContext.Current.CancellationToken);
        }
        Assert.True(condition());
    }
}
