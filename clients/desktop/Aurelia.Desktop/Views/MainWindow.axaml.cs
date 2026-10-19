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
    private readonly HostSetupFlow? host;
    private readonly AppModeStore? modes;
    private readonly ConnectionStore? store;
    private readonly Func<StoredConnection, ProfileSessionResponse, ServerSettingsModel>? serverSettings;
    private readonly HostingController? hosting;
    private LibraryModel? library;
    private ArtworkLoader? artwork;
    private PlayerModel? player;
    private ServerSettingsWindow? settingsWindow;
    private bool quitting;
    private bool started;

    /// <summary>The app as installed: real network, the platform's secret store, local discovery, VLC and its own server.</summary>
    public MainWindow()
        : this(Production.Create())
    {
    }

    private MainWindow(Production production)
        : this(production.Flow, flow => flow.Connection is { } connection && flow.Session is { } session
                ? new LibraryClient(production.Api, connection, session)
                : null,
            connection => new VlcVideoEngineFactory(Aurelia.Desktop.Core.ServerAddress.IsLoopback(connection.Address)), PlaybackSettingsStore.Default,
            host: production.Host, modes: AppModeStore.Default, store: production.Store,
            serverSettings: (connection, session) => new ServerSettingsModel(production.Host.Host, production.Api, connection, session,
                replacement => new ServerManagementClient(production.Api, connection, replacement.Token), Production.Post,
                production.Hosting, NetworkProfile.PublicNetworkCheck),
            hosting: production.Hosting)
    {
    }

    internal MainWindow(ConnectionFlow flow, Func<ConnectionFlow, ILibraryApi?>? libraries = null,
        Func<StoredConnection, IVideoEngineFactory>? engines = null, PlaybackSettingsStore? settings = null, bool startOnOpen = true,
        Func<Guid, ArtworkDiskCache?>? artworkCache = null, HostSetupFlow? host = null, AppModeStore? modes = null,
        ConnectionStore? store = null, Func<StoredConnection, ProfileSessionResponse, ServerSettingsModel>? serverSettings = null,
        HostingController? hosting = null)
    {
        this.artworkCache = artworkCache ?? ArtworkDiskCache.ForServer;
        this.flow = flow;
        this.libraries = libraries ?? (_ => null);
        this.engines = engines ?? (_ => new VlcVideoEngineFactory(localServer: false));
        this.settings = settings ?? PlaybackSettingsStore.Default;
        this.host = host;
        this.modes = modes;
        this.store = store;
        this.serverSettings = serverSettings;
        this.hosting = hosting;
        InitializeComponent();
        DataContext = flow;
        // Each view gets its own model when it is shown, never the connection flow.
        Library.DataContext = null;
        Player.DataContext = null;
        HostSetup.DataContext = host;
        SetUpHereButton.IsVisible = host is not null;
        SetUpHereButton.Content = OperatingSystem.IsWindows() ? "Set Up This PC Instead" : "Set Up This Computer Instead";
        flow.PropertyChanged += FlowChanged;
        if (host is not null)
        {
            host.PropertyChanged += HostChanged;
            host.Ready += async (connection, session) => await flow.OpenLocalAsync(connection, session);
            host.ClientModeChosen += async () =>
            {
                // Windows no longer needs to start this computer's server at sign-in.
                hosting?.HostingEnded();
                await flow.StartAsync();
            };
            if (hosting?.KeepRunning == true)
                host.BackgroundNote = OperatingSystem.IsWindows()
                    ? "When you close Aurelia, your server keeps running in the notification area and starts when you sign in to Windows. You can change this in Server Settings."
                    : "When you close Aurelia, your server keeps running in the menu bar. You can change this in Server Settings.";
            host.ServerInterrupted += () =>
            {
                // A network trial is confirmed in Server Settings after the restart; any other
                // restart ends its management session, so the settings close with it.
                if (settingsWindow?.DataContext is not ServerSettingsModel { AwaitsRestart: true }) settingsWindow?.Close();
                flow.ServerInterrupted();
            };
        }
        UpdateWelcome();
        Library.SwitchProfileRequested += async () => await flow.SwitchProfileAsync();
        Library.ServerSettingsRequested += OpenServerSettings;
        Player.CloseRequested += async () => await ClosePlayerAsync();
        if (startOnOpen) Opened += async (_, _) => await StartAsync();
        Closing += async (_, e) =>
        {
            // Signing out or shutting down Windows does not wait for the window; the server ends with the app.
            if (quitting || host is null || e.CloseReason == WindowCloseReason.OSShutdown)
            {
                await ClosePlayerAsync();
                return;
            }
            e.Cancel = true;
            if (hosting?.RunsInBackground == true && e.CloseReason != WindowCloseReason.ApplicationShutdown)
            {
                // The server keeps running in the notification area, where the window opens again.
                await ClosePlayerAsync();
                settingsWindow?.Close();
                Hide();
                return;
            }
            await QuitAsync();
        };
        Closed += async (_, _) =>
        {
            CloseLibrary();
            flow.Dispose();
            if (host is not null) await host.Host.DisposeAsync();
        };
    }

    public void Dispose() => CloseLibrary();

    internal ConnectionFlow Flow => flow;
    internal HostSetupFlow? HostFlow => host;
    internal LibraryModel? LibraryModel => library;
    internal PlayerModel? PlayerModel => player;
    internal ServerSettingsWindow? SettingsWindow => settingsWindow;
    internal HostingController? Hosting => hosting;

    /// <summary>Whether this computer runs its own server, as chosen on the welcome screen.</summary>
    internal bool HostsThisComputer => host is not null && modes?.Load() == AppMode.Host;

    /// <summary>Quit Aurelia: playback ends, the server stops cleanly and keeps its data for the next start.</summary>
    internal async Task QuitAsync()
    {
        if (quitting) return;
        quitting = true;
        await ClosePlayerAsync();
        settingsWindow?.Close();
        if (host is not null) await host.Host.StopAsync();
        Close();
    }

    /// <summary>Opens this computer's server, a server elsewhere, or the choice between them on first start.</summary>
    internal async Task StartAsync()
    {
        // The window may open again from the notification area; the server is already running then.
        if (started) return;
        started = true;
        if (host is null || modes is null)
        {
            await flow.StartAsync();
            return;
        }
        // Before this choice existed, a saved connection meant a server elsewhere.
        var mode = modes.Load() ?? (store?.Load() is { LocalHost: false } ? AppMode.Client : null);
        switch (mode)
        {
            case AppMode.Host:
                await host.StartAsync();
                break;
            case AppMode.Client:
                await flow.StartAsync();
                break;
            default:
                host.ShowChoice();
                break;
        }
    }

    private sealed record Production(AureliaServerApi Api, ConnectionStore Store, ConnectionFlow Flow, HostSetupFlow Host, HostingController Hosting)
    {
        public static void Post(Action action) => Dispatcher.UIThread.Post(action);

        public static Production Create()
        {
            var api = new AureliaServerApi();
            var store = new ConnectionStore(DesktopPaths.CreateSecretStore());
            var flow = new ConnectionFlow(api, store, new MdnsServerDiscovery(), Environment.MachineName, Post);
            var server = new LocalServerHost(LocalServerOptions.ForThisComputer());
            var hosting = new HostingController(server, HostingPreferencesStore.Default, SystemHosting.ForThisComputer(),
                HostingPreferences.ForThisComputer, Post);
            server.Hosting = () => hosting.Current;
            var host = new HostSetupFlow(server, api, store, AppModeStore.Default,
                (connection, session) => new ServerManagementClient(api, connection, session.Token), Environment.MachineName, Post);
            return new Production(api, store, flow, host, hosting);
        }
    }

    private void HostChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(HostSetupFlow.IsActive)) UpdateWelcome();
    }

    /// <summary>One card at a time: this computer's server while it is set up or starts, otherwise the connection steps.</summary>
    private void UpdateWelcome()
    {
        var hosting = host?.IsActive == true;
        HostSetup.IsVisible = hosting;
        Welcome.IsVisible = flow.ShowsWelcome && !hosting;
    }

    private async void FlowChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ConnectionFlow.ShowsWelcome)) UpdateWelcome();
        if (e.PropertyName == nameof(ConnectionFlow.Session) && flow.Phase == ConnectionPhase.Connected && flow.Session is not null && library is not null)
        {
            // A confirmed network change gave the open profile a new session.
            await OpenLibraryAsync();
            return;
        }
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
        Library.ShowServerSettings(serverSettings is not null && flow.IsLocalHost && flow.Session?.User.Role == UserRole.Owner);
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

    private void OpenServerSettings()
    {
        if (settingsWindow is not null)
        {
            settingsWindow.Activate();
            return;
        }
        if (serverSettings is null || flow.Connection is not { LocalHost: true } connection || flow.Session is not { } session) return;
        var model = serverSettings(connection, session);
        model.SessionReplaced += replacement => Dispatcher.UIThread.Post(() => flow.AdoptSession(replacement));
        settingsWindow = new ServerSettingsWindow(model);
        settingsWindow.Closed += (_, _) => settingsWindow = null;
        settingsWindow.Show(this);
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

    private async void SetUpHere(object? sender, RoutedEventArgs e)
    {
        if (host is not null) await host.ChooseHostAsync();
    }

    private async void UseAnotherServer(object? sender, RoutedEventArgs e)
    {
        if (host is not null) await host.UseAnotherServerAsync();
    }

    private void ForgotPin(object? sender, RoutedEventArgs e)
    {
        PinBox.Text = "";
        host?.BeginPinReset();
    }
}
