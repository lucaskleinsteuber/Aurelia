using System.ComponentModel;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Aurelia.Contracts;
using Aurelia.Desktop.Controls;
using Aurelia.Desktop.Core;
using Aurelia.Desktop.Playback;

namespace Aurelia.Desktop.Views;

public sealed partial class MainWindow : Window, IDisposable
{
    private readonly ConnectionFlow flow;
    private readonly Func<ConnectionFlow, ILibraryApi?> libraries;
    private readonly Func<StoredConnection, IVideoEngineFactory> engines;
    private readonly PlaybackSettingsStore settings;
    private readonly Func<Guid, ArtworkDiskCache?> artworkCache;
    private LibraryModel? library;
    private ArtworkLoader? artwork;
    private PlayerModel? player;

    /// <summary>The app as installed: real network, the platform's secret store, local discovery and VLC.</summary>
    public MainWindow()
        : this(CreateProductionFlow(out var api), flow => flow.Connection is { } connection && flow.Session is { } session
                ? new LibraryClient(api, connection, session)
                : null,
            connection => new VlcVideoEngineFactory(Aurelia.Desktop.Core.ServerAddress.IsLoopback(connection.Address)), PlaybackSettingsStore.Default)
    {
    }

    internal MainWindow(ConnectionFlow flow, Func<ConnectionFlow, ILibraryApi?>? libraries = null,
        Func<StoredConnection, IVideoEngineFactory>? engines = null, PlaybackSettingsStore? settings = null, bool startOnOpen = true,
        Func<Guid, ArtworkDiskCache?>? artworkCache = null)
    {
        this.artworkCache = artworkCache ?? ArtworkDiskCache.ForServer;
        this.flow = flow;
        this.libraries = libraries ?? (_ => null);
        this.engines = engines ?? (_ => new VlcVideoEngineFactory(localServer: false));
        this.settings = settings ?? PlaybackSettingsStore.Default;
        InitializeComponent();
        DataContext = flow;
        // Each view gets its own model when it is shown, never the connection flow.
        Library.DataContext = null;
        Player.DataContext = null;
        flow.PropertyChanged += FlowChanged;
        Library.SwitchProfileRequested += async () => await flow.SwitchProfileAsync();
        Player.CloseRequested += async () => await ClosePlayerAsync();
        if (startOnOpen) Opened += async (_, _) => await flow.StartAsync();
        Closing += async (_, _) => await ClosePlayerAsync();
        Closed += (_, _) =>
        {
            CloseLibrary();
            flow.Dispose();
        };
    }

    public void Dispose() => CloseLibrary();

    internal ConnectionFlow Flow => flow;
    internal LibraryModel? LibraryModel => library;
    internal PlayerModel? PlayerModel => player;

    private static ConnectionFlow CreateProductionFlow(out AureliaServerApi api)
    {
        api = new AureliaServerApi();
        return new ConnectionFlow(api, new ConnectionStore(DesktopPaths.CreateSecretStore()), new MdnsServerDiscovery(),
            Environment.MachineName, action => Dispatcher.UIThread.Post(action));
    }

    private async void FlowChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(ConnectionFlow.Phase)) return;
        if (flow.Phase == ConnectionPhase.Connected) await OpenLibraryAsync();
        else
        {
            await ClosePlayerAsync();
            CloseLibrary();
        }
    }

    /// <summary>The opened profile's library, with artwork cached for this server.</summary>
    private async Task OpenLibraryAsync()
    {
        CloseLibrary();
        if (libraries(flow) is not { } api || flow.Connection is not { } connection) return;
        artwork = new ArtworkLoader(api, artworkCache(connection.ServerId));
        ArtworkImage.Loader = artwork;
        library = new LibraryModel(api);
        library.PlayRequested += request => _ = OpenPlayerAsync(request);
        Library.DataContext = library;
        Library.ShowProfile(flow.SignedInName);
        Library.IsVisible = player is null;
        await library.ShowAsync(LibrarySection.Home);
    }

    private void CloseLibrary()
    {
        library?.Dispose();
        (library?.Api as IDisposable)?.Dispose();
        library = null;
        Library.DataContext = null;
        Library.IsVisible = false;
        artwork?.Dispose();
        artwork = null;
        ArtworkImage.Loader = null;
        ArtworkImage.ClearMemory();
    }

    private async Task OpenPlayerAsync(PlaybackRequest request)
    {
        if (library is null || flow.Connection is not { } connection) return;
        await ClosePlayerAsync();
        var opened = new PlayerModel(library.Api, engines(connection), settings, request, action => Dispatcher.UIThread.Post(action));
        opened.CloseRequested += () => _ = ClosePlayerAsync();
        player = opened;
        Player.Show(opened);
        Player.IsVisible = true;
        Library.IsVisible = false;
        await opened.StartAsync();
    }

    private async Task ClosePlayerAsync()
    {
        if (player is not { } closing) return;
        player = null;
        Player.Release();
        Player.IsVisible = false;
        Library.IsVisible = flow.ShowsLibrary && library is not null;
        if (WindowState == WindowState.FullScreen) WindowState = WindowState.Normal;
        await closing.DisposeAsync();
        // Continue Watching and progress bars reflect what was just watched.
        if (library is { } current && current.Section == LibrarySection.Home && !current.ShowsDetail) await current.LoadHomeAsync();
        else if (library?.Detail is { } detail) await library.OpenDetailAsync(detail.Item.Id);
    }

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
        if (flow.HasError || flow.ShowsLibrary) PinBox.Text = "";
    }

    private async void Refresh(object? sender, RoutedEventArgs e) => await flow.RefreshProfilesAsync();

    private async void Disconnect(object? sender, RoutedEventArgs e) => await flow.DisconnectAsync();
}
