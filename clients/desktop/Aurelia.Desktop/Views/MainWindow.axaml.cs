using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Views;

public sealed partial class MainWindow : Window
{
    private readonly ConnectionFlow flow;

    /// <summary>The app as installed: real network, the platform's secret store, local discovery.</summary>
    public MainWindow()
        : this(new ConnectionFlow(new AureliaServerApi(), new ConnectionStore(DesktopPaths.CreateSecretStore()),
            new MdnsServerDiscovery(), Environment.MachineName, action => Dispatcher.UIThread.Post(action)))
    {
    }

    internal MainWindow(ConnectionFlow flow, bool startOnOpen = true)
    {
        this.flow = flow;
        InitializeComponent();
        DataContext = flow;
        VersionLabel.Text = AppInfo.VersionLabel;
        if (startOnOpen) Opened += async (_, _) => await flow.StartAsync();
        Closed += (_, _) => flow.Dispose();
    }

    internal ConnectionFlow Flow => flow;

    private async void Connect(object? sender, RoutedEventArgs e) => await flow.ConnectAsync();

    private async void AddressKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) await flow.ConnectAsync();
    }

    private async void ChooseServer(object? sender, RoutedEventArgs e)
    {
        if ((sender as Control)?.DataContext is DiscoveredServer server) await flow.ConnectAsync(server);
    }

    private async void Trust(object? sender, RoutedEventArgs e) => await flow.TrustAndPairAsync();

    private void Back(object? sender, RoutedEventArgs e)
    {
        PinBox.Text = "";
        flow.Back();
    }

    private async void CancelPairing(object? sender, RoutedEventArgs e) => await flow.CancelPairingAsync();

    private async void ChooseProfile(object? sender, RoutedEventArgs e)
    {
        if ((sender as Control)?.DataContext is not WatchingProfile profile) return;
        PinBox.Text = "";
        await flow.ChooseProfileAsync(profile);
        if (flow.ShowsPin) PinBox.Focus();
    }

    private async void SubmitPin(object? sender, RoutedEventArgs e) => await SubmitPinAsync();

    private async void PinKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) await SubmitPinAsync();
    }

    private async Task SubmitPinAsync()
    {
        var pin = PinBox.Text ?? "";
        await flow.SubmitPinAsync(pin);
        if (flow.HasError) PinBox.Text = "";
        else if (flow.ShowsLibrary) PinBox.Text = "";
    }

    private async void Refresh(object? sender, RoutedEventArgs e) => await flow.RefreshProfilesAsync();

    private async void Disconnect(object? sender, RoutedEventArgs e) => await flow.DisconnectAsync();

    private async void SwitchProfile(object? sender, RoutedEventArgs e) => await flow.SwitchProfileAsync();
}
