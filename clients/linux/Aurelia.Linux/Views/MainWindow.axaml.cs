using System.ComponentModel;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Hosting;
using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Hosting;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Playback;
using Aurelia.Linux.Core.Settings;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Threading;

namespace Aurelia.Linux.Views;

public sealed partial class MainWindow : Window, IPlayOnTarget, IDisposable
{
    private readonly AppServices services;
    private LibraryShell? shell;

    public MainWindow() : this(AppServices.CreateDefault())
    {
    }

    public MainWindow(AppServices services, bool startSession = true)
    {
        this.services = services;
        InitializeComponent();
        if (OperatingSystem.IsLinux())
        {
            // Wayland: Aurelia extends into the window and the toolkit draws only the resize border.
            // X11: the window manager keeps a thin border for resizing and drops its title bar.
            ExtendClientAreaToDecorationsHint = true;
            WindowDecorations = WindowDecorations.BorderOnly;
        }
        Chrome.Attach(this, services.ButtonLayout);
        AppWindowBehavior.Attach(this);
        Flow = new AppFlow(services.Settings);
        var discovery = new DiscoveryCache(services.CreateDiscovery());
        var api = new AureliaApi(services.Transport);
        Session = new AppSession(Flow, api, services.Credentials,
            new ServerWakeUp(api, services.WakeOnLan, () => discovery.Latest, services.Time), services.DeviceName, services.Time,
            new GeneralPreferences(services.Settings), new ArtworkCache(services.ArtworkDirectory));
        Flow.PropertyChanged += OnFlowChanged;
        Session.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppSession.Library)) StartPlayOn();
        };
        KeyBindings.Add(new KeyBinding { Gesture = new KeyGesture(Key.Q, KeyModifiers.Control), Command = new RelayCommand(Close) });
        Closing += (_, e) =>
        {
            // With "Also when Aurelia is closed", closing only hides the window; the server keeps running.
            if (quitting || !KeepsRunning) return;
            e.Cancel = true;
            Hide();
            Tray().IsVisible = true;
        };
        KeyBindings.Add(new KeyBinding { Gesture = new KeyGesture(Key.OemComma, KeyModifiers.Control), Command = new RelayCommand(() => OpenSettings()) });
        AddHandler(PointerMovedEvent, (_, _) => NoteUse(), Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        AddHandler(PointerPressedEvent, (_, _) => NoteUse(), Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        AddHandler(KeyDownEvent, (_, _) => NoteUse(), Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        Activated += (_, _) => NoteUse();
        Deactivated += (_, _) => lastUse = services.Time.GetUtcNow();
        restCheck = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        restCheck.Tick += (_, _) => CheckRest();
        restCheck.Start();
        ShowScreen();
        if (startSession) Opened += async (_, _) => await Session.StartAsync(StartHostingAsync);
        Closed += (_, _) =>
        {
            Dispose();
            discovery.Dispose();
            api.Dispose();
        };
    }

    public AppFlow Flow { get; }

    public AppSession Session { get; }

    internal LibraryShell? Shell => shell;

    internal Control? CurrentScreen => ScreenHost.Content as Control;

    private void OnFlowChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppFlow.Screen)) ShowScreen();
    }

    private void ShowScreen()
    {
        if (Flow.Screen != AppScreen.Library) shell = null;
        Control screen = Flow.Screen switch
        {
            AppScreen.Starting => new StartingView(Session),
            AppScreen.Welcome => new WelcomeView(Flow),
            AppScreen.HostSetup => HostSetup(),
            AppScreen.Connection => Connection(),
            AppScreen.InitialLibrarySetup => new InitialLibrarySetupView(Session),
            AppScreen.ServerUnreachable => new ServerUnreachableView(Session),
            AppScreen.ProfilePicker => ProfilePicker(),
            _ => shell ??= NewShell(),
        };
        ScreenHost.Content = screen;
    }

    private HostSetupModel? hosting;
    private HostingTray? tray;
    private IDisposable? awake;
    private bool quitting;

    /// <summary>This computer hosts the server and keeps it running when the window closes.</summary>
    internal bool KeepsRunning => Flow.Mode == OperatingMode.Host && hosting is not null
        && HostingSettings.Read(services.Settings).KeepRunning;

    /// <summary>Starts without a window, as the login item does: the server runs, the icon offers the window.</summary>
    public async Task StartInBackgroundAsync()
    {
        Tray().IsVisible = true;
        await Session.StartAsync(StartHostingAsync);
    }

    /// <summary>Shows the window again from the notification area.</summary>
    public void ShowFromTray()
    {
        Show();
        Activate();
        if (!KeepsRunning && tray is not null) tray.IsVisible = false;
    }

    /// <summary>Quits Aurelia and stops this computer's server.</summary>
    public void Quit()
    {
        quitting = true;
        Close();
        if (Avalonia.Application.Current?.ApplicationLifetime is Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime desktop)
            desktop.Shutdown();
    }

    private HostingTray Tray() => tray ??= new HostingTray(ShowFromTray, Quit);

    /// <summary>Keeps the computer awake while its server runs, when the owner asked for it.</summary>
    internal async Task UpdateKeepAwakeAsync()
    {
        var wanted = hosting?.Host.State is LocalServerState.Running or LocalServerState.SetupRequired
            && HostingSettings.Read(services.Settings).KeepAwake;
        if (wanted == (awake is not null)) return;
        if (!wanted)
        {
            awake?.Dispose();
            awake = null;
            return;
        }
        awake = await (services.HostingSystem?.KeepAwakeAsync("Aurelia Server runs on this computer") ?? Task.FromResult<IDisposable?>(null))
            ?? new NoLock();
    }

    private sealed class NoLock : IDisposable
    {
        public void Dispose()
        {
        }
    }
    private bool hostStarted;
    private string? connectionAddress;

    /// <summary>This computer's server and its setup, once hosting is chosen; null where no server comes with the app.</summary>
    internal HostSetupModel? Hosting
    {
        get
        {
            if (hosting is not null || services.CreateHost is not { } create) return hosting;
            var host = create();
            if (host is LocalServerHost local) local.Hosting = () => HostingSettings.Read(services.Settings);
            hosting = new HostSetupModel(host, Session, Flow, services.Credentials, action => Dispatcher.UIThread.Post(action));
            host.Changed += () => Dispatcher.UIThread.Post(() => _ = UpdateKeepAwakeAsync());
            return hosting;
        }
    }

    private Task StartHostingAsync()
    {
        if (Hosting is not { } model) return Task.CompletedTask;
        hostStarted = true;
        return model.StartAsync();
    }

    private Control HostSetup()
    {
        if (Hosting is not { } model)
        {
            return new PreviewNoticeView(Flow, "Set Up This PC", "The server that comes with Aurelia is missing. Install Aurelia again, or connect to a server that runs elsewhere.");
        }
        if (!hostStarted) _ = StartHostingAsync();
        return new HostSetupView(model, async otherHere =>
        {
            if (otherHere)
            {
                // Another Aurelia Server runs on this computer: pair with it like with any server.
                connectionAddress = "127.0.0.1";
                Flow.ChooseMode(OperatingMode.Client);
                return;
            }
            hostStarted = false;
            await model.UseAnotherServerAsync();
        });
    }

    private ConnectionView Connection()
    {
        var model = new ConnectionModel(Session, services.CreateDiscovery(), action => Dispatcher.UIThread.Post(action));
        if (connectionAddress is { } address)
        {
            model.Address = address;
            connectionAddress = null;
        }
        return new ConnectionView(model, Flow);
    }

    private LibraryShell NewShell()
    {
        var created = new LibraryShell { LeadingInset = Chrome.LeadingWidth, Session = Session };
        if (Remote is not null) created.AttachRemote(Remote);
        created.PlayRequested += (item, resume) => _ = PlayAsync(item, resume);
        created.SettingsRequested += () => OpenSettings();
        return created;
    }

    private CancellationTokenSource? playOn;
    private readonly DispatcherTimer restCheck;
    private DateTimeOffset lastUse = DateTimeOffset.UtcNow;
    private Settings.SettingsWindow? settings;

    /// <summary>Opens Settings, or brings the open Settings window forward.</summary>
    public Settings.SettingsWindow OpenSettings(Settings.SettingsCategory category = Settings.SettingsCategory.General)
    {
        if (settings is { } open)
        {
            open.Category = category;
            open.Activate();
            return open;
        }
        settings = new Settings.SettingsWindow(Session, shell, services, category);
        settings.Closed += (_, _) => settings = null;
        settings.HostingChanged += () =>
        {
            _ = UpdateKeepAwakeAsync();
            if (tray is not null && !KeepsRunning && IsVisible) tray.IsVisible = false;
        };
        settings.Show(this);
        return settings;
    }

    private void NoteUse()
    {
        lastUse = services.Time.GetUtcNow();
        if (Session.IsResting) _ = WakeFromRestAsync();
    }

    /// <summary>Lets the server rest when nothing plays and nobody used Aurelia for the chosen minutes, as on the Mac.</summary>
    internal void CheckRest()
    {
        var prefs = Session.Preferences;
        var withoutUse = services.Time.GetUtcNow() - lastUse;
        if (Session.IsResting || Session.Library is null) return;
        if (!Core.Settings.GeneralPreferences.ShouldRest(prefs.RestsWhenUnused, prefs.RestMinutes, withoutUse, Player is not null, Session.ConnectedElsewhere)) return;
        playOn?.Cancel();
        Session.Rest();
        RestHost.Content = RestView();
        RestHost.IsVisible = true;
    }

    private async Task WakeFromRestAsync()
    {
        RestHost.IsVisible = false;
        RestHost.Content = null;
        await Session.ResumeFromRestAsync();
    }

    private Panel RestView()
    {
        var name = Session.Server?.Name ?? "your server";
        var minutes = Session.Preferences.RestMinutes;
        var resume = new Button { Content = "Continue", Classes = { "primary" }, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center };
        resume.Click += async (_, _) => await WakeFromRestAsync();
        return ScreenParts.Backdrop(new StackPanel
        {
            Spacing = 14,
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
            Children =
            {
                ScreenParts.Symbol("IconSleep", 46),
                ScreenParts.Title("Aurelia Is Resting"),
                ScreenParts.Detail($"Nothing played and no one used Aurelia for {minutes} minutes, so it let go of {name}. The server can save power now."),
                ScreenParts.Detail("Click anywhere or press a key to continue."),
                resume,
            },
        });
    }

    public void Dispose()
    {
        restCheck.Stop();
        playOn?.Cancel();
        playOn?.Dispose();
        playOn = null;
        Remote?.Dispose();
        // The server runs only while Aurelia does, unless it keeps running in the background.
        if (hosting is not null) _ = hosting.Host.DisposeAsync().AsTask();
        awake?.Dispose();
        awake = null;
        tray?.Dispose();
        tray = null;
    }

    /// <summary>Remote control of another device in the household, for the open profile.</summary>
    public RemotePlayback? Remote { get; private set; }

    /// <summary>Play On while a profile is open: announce this computer and follow commands from other devices.</summary>
    private void StartPlayOn()
    {
        playOn?.Cancel();
        playOn = null;
        Remote?.Stop();
        Remote = null;
        if (Session.Library is not { } library) return;
        var client = new PlaybackClient(Session.Api, library.Client);
        Remote = new RemotePlayback(client, services.Settings, services.Time);
        shell?.AttachRemote(Remote);
        if (services.Engines is null) return;
        playOn = new CancellationTokenSource();
        _ = new PlayOnReceiver(client, services.Settings, services.DeviceName, this, action => Dispatcher.UIThread.Post(action), services.Time).RunAsync(playOn.Token);
    }

    /// <summary>Another device asked this computer to play a title.</summary>
    void IPlayOnTarget.Play(Guid mediaId, double? positionSeconds) => _ = PlayRemoteAsync(mediaId, positionSeconds);

    private async Task PlayRemoteAsync(Guid mediaId, double? positionSeconds)
    {
        if (Session.Library is not { } library) return;
        try
        {
            var item = await library.Client.SummaryAsync(mediaId, CancellationToken.None);
            await PlayAsync(item, resume: true, positionSeconds is { } seconds ? (long)(seconds * 1000) : null);
        }
        catch (AureliaApiException failure)
        {
            library.Report(failure);
        }
    }

    /// <summary>The player while a title plays, else null.</summary>
    public PlaybackController? Player { get; private set; }

    /// <summary>Opens the player over the library for a title (a series plays its next episode).</summary>
    public async Task PlayAsync(Aurelia.Contracts.CatalogItemSummary item, bool resume, long? startAt = null)
    {
        if (Session.Library is not { } library || services.Engines is null) return;
        if (Player is { } running) await running.CloseAsync();
        var outbox = new ProgressOutbox(services.StateDirectory is { } state ? Path.Combine(state, "pending-progress.json") : null);
        var player = new PlaybackController(new PlaybackClient(Session.Api, library.Client), services.Engines, services.Settings, outbox,
            services.Time, action => Dispatcher.UIThread.Post(action), services.PlaybackSystem);
        Player = player;
        var view = new PlayerView(player, this);
        player.Closed += () => Dispatcher.UIThread.Post(() =>
        {
            if (Player != player) return;
            Player = null;
            PlayerHost.Content = null;
            PlayerHost.IsVisible = false;
            view.Dispose();
            if (WindowState == WindowState.FullScreen) WindowState = WindowState.Normal;
            _ = library.RefreshHomeAsync();
        });
        PlayerHost.Content = view;
        PlayerHost.IsVisible = true;
        await outbox.FlushAsync(player.Client, CancellationToken.None);
        await player.StartAsync(item, resume, startAt);
    }

    private ProfilePickerView ProfilePicker()
    {
        var model = new ProfilePickerModel(Session);
        var local = Flow.Mode == OperatingMode.Host && Session.Server is { LocallyManaged: true } ? Hosting : null;
        var view = local is null
            ? new ProfilePickerView(model, Session)
            : new ProfilePickerView(model, Session, () =>
            {
                local.BeginPinReset();
                Flow.Show(AppScreen.HostSetup);
            }, async () =>
            {
                hostStarted = false;
                await local.UseAnotherServerAsync();
            });
        _ = model.LoadAsync();
        return view;
    }
}
