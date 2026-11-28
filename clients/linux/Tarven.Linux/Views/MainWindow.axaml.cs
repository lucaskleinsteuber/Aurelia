using System.ComponentModel;
using Tarven.Linux.Controls;
using Tarven.Linux.Core;
using Tarven.Linux.Core.Api;
using Tarven.Linux.Core.Connection;
using Tarven.Linux.Core.Flow;
using Tarven.Linux.Core.Hosting;
using Tarven.Linux.Core.Platform;
using Tarven.Linux.Hosting;
using Tarven.Linux.Library;
using Tarven.Linux.Core.Library;
using Tarven.Linux.Core.Playback;
using Tarven.Linux.Playback;
using Tarven.Linux.Core.Settings;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Threading;

namespace Tarven.Linux.Views;

public sealed partial class MainWindow : Window, IPlayOnTarget, IDisposable
{
    private readonly AppServices services;
    private LibraryShell? shell;
    private LibraryStore? observedLibrary;
    private readonly OfflineProfileStore offlineCards;

    public MainWindow() : this(AppServices.CreateDefault())
    {
    }

    public MainWindow(AppServices services, bool startSession = true)
    {
        this.services = services;
        InitializeComponent();
        if (OperatingSystem.IsLinux())
        {
            // Wayland: Tarven extends into the window and the toolkit draws only the resize border.
            // X11: the window manager keeps a thin border for resizing and drops its title bar.
            ExtendClientAreaToDecorationsHint = true;
            WindowDecorations = WindowDecorations.BorderOnly;
        }
        Title = AppInfo.DisplayName;
        Chrome.Attach(this, services.ButtonLayout);
        Controls.Motion.ReduceMotion = () => Session?.Preferences.ReduceMotion == true;
        AppWindowBehavior.Attach(this);
        Flow = new AppFlow(services.Settings);
        RestorePlacement();
        discovery = new DiscoveryCache(services.CreateDiscovery());
        var api = new TarvenApi(services.Transport);
        var wishPosters = new WishPosterCache(services.ArtworkDirectory is { } dir
            ? Path.Combine(Path.GetDirectoryName(dir) ?? dir, "wish-posters")
            : null);
        Session = new AppSession(Flow, api, services.Credentials,
            new ServerWakeUp(api, services.WakeOnLan, () => discovery.Latest, services.Time), services.DeviceName, services.Time,
            new GeneralPreferences(services.Settings), new ArtworkCache(services.ArtworkDirectory), wishPosters);
        Flow.PropertyChanged += OnFlowChanged;
        Flow.Guide.PropertyChanged += OnGuideChanged;
        // Profile photos come from the connected server, with this computer's device credential,
        // and are kept beside the artwork cache so a known photo shows in the first frame.
        if (services.ArtworkDirectory is { } artwork) ProfileAvatar.PhotoFolder = Path.Combine(Path.GetDirectoryName(artwork) ?? artwork, "profile-photos");
        ProfileAvatar.PhotoSource = (id, revision, cancellation) => Session.Server is { } server
            ? Session.Api.ProfilePhotoAsync(server, id, revision, cancellation)
            : Task.FromException<byte[]>(new InvalidOperationException("No server is connected."));
        Session.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppSession.IsResting)) SyncRestView();
            if (e.PropertyName != nameof(AppSession.Library)) return;
            AttachWishNotifications(Session.Library);
            StartPlayOn();
        };
        // The offline mode remembers each profile that opens with the server (with only a PIN check
        // value), and forgets a server's profiles when this computer leaves it.
        offlineCards = new OfflineProfileStore(services.Downloads is { } kept ? Path.Combine(kept.Root, "offline-profiles.json") : null);
        Session.ProfileUnlocked += (profile, pin) =>
        {
            if (services.Downloads is null || Session.Server is not { } server) return;
            var now = services.Time.GetUtcNow();
            _ = Task.Run(() => offlineCards.Remember(OfflineProfileCard.Make(server.ServerId, profile, pin, now)));
        };
        Session.ServerForgotten += serverId => offlineCards.Forget(serverId);
        KeyBindings.Add(new KeyBinding { Gesture = new KeyGesture(Key.Q, KeyModifiers.Control), Command = new RelayCommand(Quit) });
        Closing += (_, e) =>
        {
            SavePlacement();
            // With "Also when Tarven is closed", closing only hides the window; the server keeps running.
            if (quitting || !KeepsRunning) return;
            e.Cancel = true;
            Hide();
            Tray().IsVisible = true;
        };
        KeyBindings.Add(new KeyBinding { Gesture = new KeyGesture(Key.OemComma, KeyModifiers.Control), Command = new RelayCommand(() => OpenSettings()) });
        AddHandler(PointerMovedEvent, (_, _) => NoteUse(wake: IsActive), Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        AddHandler(PointerPressedEvent, (_, _) => NoteUse(wake: true), Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        AddHandler(KeyDownEvent, (_, _) => NoteUse(wake: true), Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        AddHandler(GotFocusEvent, (_, _) => NoteUse(wake: true), Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        PropertyChanged += (_, change) =>
        {
            if (change.Property == IsActiveProperty && IsActive) NoteUse(wake: true);
        };
        Activated += (_, _) => OnWindowActivated();
        Deactivated += (_, _) => lastUse = services.Time.GetUtcNow();
        restCheck = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        restCheck.Tick += (_, _) =>
        {
            CheckRest();
            if (services.Updater is { } updater) _ = updater.CheckAsync(userInitiated: false);
        };
        restCheck.Start();
        // Video frames are decoded at most at the largest screen's size; a 4K title on a smaller
        // screen would otherwise be converted and copied at full size only to be scaled down.
        Opened += (_, _) => VideoFrames.ScreenLimit = LargestScreenSide();
        ShowScreen();
        if (startSession) Opened += async (_, _) =>
        {
            await Session.StartAsync(StartHostingAsync);
            if (services.Updater is { } updater) await updater.CheckAsync(userInitiated: false);
        };
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
        if (e.PropertyName == nameof(AppFlow.Mode) && Flow.Mode == OperatingMode.Client) _ = DisableBackgroundHostingAsync();
    }

    private async Task DisableBackgroundHostingAsync()
    {
        var current = HostingSettings.Read(services.Settings);
        HostingSettings.Write(services.Settings, current with { KeepRunning = false, StartAtSignIn = false });
        try
        {
            if (services.HostingSystem is { } system) await system.ConfigureBackgroundAsync(false, false);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or InvalidOperationException or Tmds.DBus.Protocol.DBusExceptionBase)
        {
            Session.Message = "Automatic background startup could not be removed. Tarven will ignore the old login entry in client mode.";
        }
    }

    /// <summary>"Skip Assistant" removes the step bar at once; the end of setup swaps the last page for the library.</summary>
    private void OnGuideChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SetupGuide.IsGuiding) && !Flow.Guide.IsGuiding)
        {
            if (ScreenHost.Content is Panel { Tag: "guided" } guided && guided.Children.Count > 1) guided.Children.RemoveAt(1);
            if (Flow.Screen == AppScreen.Library && ScreenHost.Content is SetupFinishView) ShowScreen();
        }
        if (e.PropertyName == nameof(SetupGuide.TourPending) && Flow.Guide.TourPending) StartTourIfReady();
    }

    /// <summary>The step of the guided setup a screen belongs to, or null for screens outside it.</summary>
    internal SetupStep? StepFor(AppScreen screen) => screen switch
    {
        AppScreen.Welcome => SetupStep.Choose,
        AppScreen.HostSetup => SetupStep.Secure,
        AppScreen.Connection => SetupStep.Connect,
        AppScreen.ProfilePicker => Flow.Mode == OperatingMode.Host ? SetupStep.Pin : SetupStep.Profile,
        AppScreen.InitialLibrarySetup => SetupStep.Media,
        _ => null,
    };

    /// <summary>The last page's "Start Watching": the library opens and the tour starts.</summary>
    private void FinishSetup(bool openDevices)
    {
        Flow.Guide.Finish();
        if (ScreenHost.Content is SetupFinishView) ShowScreen();
        if (openDevices) OpenSettings(Settings.SettingsCategory.ProfilesAndDevices);
    }

    private void StartTourIfReady()
    {
        if (!Flow.Guide.TourPending || shell is null || Flow.Screen != AppScreen.Library || ScreenHost.Content != shell) return;
        // After the window settles, so the tour finds the posters on the page.
        Dispatcher.UIThread.Post(() =>
        {
            if (shell is null || !Flow.Guide.TourPending) return;
            Flow.Guide.TourShown();
            shell.StartTour(() => shell?.Focus());
        }, DispatcherPriority.Background);
    }

    /// <summary>Settings › About › Show Introduction: the explanation again, over the window.</summary>
    public void ShowIntroduction()
    {
        IntroHost.Content = new IntroductionView(Flow, replay: true, closed: () =>
        {
            IntroHost.Content = null;
            IntroHost.IsVisible = false;
        });
        IntroHost.IsVisible = true;
    }

    private void ShowScreen()
    {
        if (Flow.Screen != AppScreen.Library) shell = null;
        var guiding = Flow.Guide.IsGuiding;
        Control screen = Flow.Screen switch
        {
            AppScreen.Starting => new StartingView(Session, Session.EnterOffline, () => CanOfferOffline),
            AppScreen.Introduction => new IntroductionView(Flow),
            AppScreen.Welcome => new WelcomeView(Flow),
            AppScreen.HostSetup => HostSetup(),
            AppScreen.Connection => Connection(),
            AppScreen.InitialLibrarySetup => new InitialLibrarySetupView(Session),
            AppScreen.ServerUnreachable => new ServerUnreachableView(Session, Session.OfflineTitlesForOpenProfile(services.Downloads), PlayOffline,
                CanOfferOffline ? Session.EnterOffline : null),
            AppScreen.Offline => OfflineScreen(),
            AppScreen.ProfilePicker => ProfilePicker(),
            _ when guiding => new SetupFinishView(Session, Flow, FinishSetup),
            _ => shell ??= NewShell(),
        };
        ScreenHost.Content = guiding && StepFor(Flow.Screen) is { } step
            ? new Panel { Tag = "guided", Children = { screen, new SetupStepBar(Flow, step) } }
            : screen;
        StartTourIfReady();
    }

    private HostSetupModel? hosting;
    private HostingTray? tray;
    private readonly DiscoveryCache discovery;
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

    /// <summary>
    /// Starts the version just installed and quits this one; the new one waits until this one has
    /// ended (audit Linux S2: "Quit and reopen" was left to the person).
    /// </summary>
    public void RestartAfterUpdate() => Restart(edition: null);

    /// <summary>
    /// Quits and opens Tarven again; the new process waits until this one has quit, so it never meets
    /// this instance and hands over to it.
    /// </summary>
    private void Restart(string? edition)
    {
        if (Environment.ProcessPath is { Length: > 0 } program)
        {
            var start = new System.Diagnostics.ProcessStartInfo(program) { UseShellExecute = false };
            if (edition is not null) start.Environment["TARVEN_EDITION"] = edition;
            start.ArgumentList.Add("--after-quit");
            start.ArgumentList.Add(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture));
            try
            {
                System.Diagnostics.Process.Start(start)?.Dispose();
            }
            catch (Exception failure) when (failure is System.ComponentModel.Win32Exception or IOException or InvalidOperationException)
            {
                // Quitting still works; the person opens Tarven again.
            }
        }
        Quit();
    }

    /// <summary>Quits Tarven and stops this computer's server.</summary>
    // The size the window had while neither maximized nor full screen, kept as it changes.
    private Avalonia.Size normalSize;

    private void RestorePlacement()
    {
        normalSize = new Avalonia.Size(Width, Height);
        if (Core.Settings.WindowPlacement.Read(services.Settings) is { } saved)
        {
            Width = saved.Width;
            Height = saved.Height;
            normalSize = new Avalonia.Size(saved.Width, saved.Height);
            if (saved.Maximized) WindowState = WindowState.Maximized;
        }
        PropertyChanged += (_, change) =>
        {
            if (change.Property == ClientSizeProperty && WindowState == WindowState.Normal) normalSize = ClientSize;
        };
    }

    private void SavePlacement() =>
        new Core.Settings.WindowPlacement(normalSize.Width, normalSize.Height, WindowState == WindowState.Maximized).Save(services.Settings);

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
        awake = await (services.HostingSystem?.KeepAwakeAsync("Tarven Server runs on this computer") ?? Task.FromResult<IDisposable?>(null))
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
            hosting = new HostSetupModel(host, Session, Flow, services.Credentials, action => Dispatcher.UIThread.Post(action), () => discovery.Latest);
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
            return new PreviewNoticeView(Flow, "Set Up This PC", "The server that comes with Tarven is missing. Install Tarven again, or connect to a server that runs elsewhere.");
        }
        if (!hostStarted) _ = StartHostingAsync();
        return new HostSetupView(model, async otherHere =>
        {
            if (otherHere)
            {
                // Another Tarven Server runs on this computer: pair with it like with any server.
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
        var created = new LibraryShell { LeadingInset = Chrome.LeadingWidth, Session = Session, Engines = services.Engines };
        // Settings, the player and other layers over the library keep their own keys.
        created.IsCovered = () => settings is not null || Player is not null;
        if (Remote is not null) created.AttachRemote(Remote);
        created.PlayRequested += (item, resume) => _ = PlayAsync(item, resume);
        created.PlayCollectionRequested += (playlist, target, resume) => _ = PlayAsync(target, resume, playlist: playlist);
        created.HostWindow = this;
        // Progress watched offline goes back to the server once a profile is open again.
        if (services.Downloads is { } offline && Session.Library is { } opened)
            _ = Task.Run(() => offline.SyncProgressAsync(new PlaybackClient(Session.Api, opened.Client)));
        created.SettingsRequested += () => OpenSettings();
        return created;
    }

    private CancellationTokenSource? playOn;
    private readonly DispatcherTimer restCheck;
    private DateTimeOffset lastUse = DateTimeOffset.UtcNow;
    private Settings.SettingsView? settings;

    /// <summary>Settings shown over the library, if open.</summary>
    public Settings.SettingsView? OpenSettingsView => settings;

    /// <summary>Opens Settings inside the window, or switches the open Settings to <paramref name="category"/>.</summary>
    public Settings.SettingsView OpenSettings(Settings.SettingsCategory category = Settings.SettingsCategory.General)
    {
        if (settings is { } open)
        {
            open.Category = category;
            return open;
        }
        var created = new Settings.SettingsView(Session, shell, services, category) { InstallUpdate = InstallUpdateAsync, QuitAfterUpdate = Quit, RestartAfterUpdate = RestartAfterUpdate };
        settings = created;
        created.Closed += (_, _) =>
        {
            if (!ReferenceEquals(settings, created)) return;
            settings = null;
            SettingsHost.Content = null;
            SettingsHost.IsVisible = false;
            shell?.Focus();
        };
        created.IntroductionRequested += ShowIntroduction;
        created.TourRequested += Flow.Guide.RequestTour;
        created.ResetRequested += () => _ = ResetTestEditionAsync();
        created.HostingChanged += () =>
        {
            _ = UpdateKeepAwakeAsync();
            if (tray is not null && !KeepsRunning && IsVisible) tray.IsVisible = false;
        };
        SettingsHost.Content = created;
        SettingsHost.IsVisible = true;
        Controls.Motion.Appear(created, rise: 10, fromScale: 0.99);
        Avalonia.Threading.Dispatcher.UIThread.Post(() => created.Focus());
        return created;
    }

    private async Task<bool> InstallUpdateAsync()
    {
        if (services.Updater is not { } updater) return false;
        var restartHost = hosting?.Host.State is LocalServerState.Running or LocalServerState.SetupRequired;
        var stopped = false;
        var installed = await updater.InstallAsync(async () =>
        {
            if (Player is { } player) await player.CloseAsync();
            if (restartHost && hosting is not null)
            {
                await hosting.Host.StopAsync();
                stopped = true;
            }
        });
        if (!installed && stopped && hosting is not null) await hosting.StartAsync();
        return installed;
    }

    internal void OnWindowActivated()
    {
        NoteUse(wake: true);
        // A server this PC hosts that stopped for being unused starts again when Tarven is opened.
        if (hosting?.Host is { State: LocalServerState.Idle } idle) _ = idle.StartAsync();
    }

    private void NoteUse(bool wake = true)
    {
        lastUse = services.Time.GetUtcNow();
        if (wake && Session.IsResting) _ = LeaveRestAsync();
    }

    private void SyncRestView()
    {
        if (Session.IsResting)
        {
            RestHost.Content ??= RestView();
            RestHost.IsVisible = true;
        }
        else
        {
            RestHost.IsVisible = false;
            RestHost.Content = null;
        }
    }

    /// <summary>Lets a remote power-saving server rest when nothing plays and nobody used Tarven for the chosen minutes.</summary>
    internal void CheckRest()
    {
        var prefs = Session.Preferences;
        var withoutUse = services.Time.GetUtcNow() - lastUse;
        if (Session.IsResting || Session.Library is null) return;
        if (!Core.Settings.GeneralPreferences.ShouldRest(prefs.RestsWhenUnused, prefs.RestMinutes, withoutUse, Player is not null,
            Session.ConnectedElsewhere, Session.Server?.PowerSavingEnabled == true))
        {
            return;
        }
        playOn?.Cancel();
        Session.Rest();
        SyncRestView();
    }

    public async Task LeaveRestAsync()
    {
        lastUse = services.Time.GetUtcNow();
        RestHost.IsVisible = false;
        RestHost.Content = null;
        await Session.LeaveRestAsync();
    }

    private Panel RestView()
    {
        var name = Session.Server?.Name ?? "your server";
        var minutes = Session.Preferences.RestMinutes;
        var resume = new Button { Content = "Continue", Classes = { "primary" }, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center };
        resume.Click += async (_, _) => await LeaveRestAsync();
        return ScreenParts.Backdrop(new StackPanel
        {
            Spacing = 14,
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
            Children =
            {
                ScreenParts.Symbol("IconSleep", 46),
                ScreenParts.Title("Tarven Is Resting"),
                ScreenParts.Detail($"Nothing played and no one used Tarven for {minutes} minutes, so it let go of {name}. The server can save power now."),
                ScreenParts.Detail("Switching back to Tarven, clicking or pressing any key continues automatically."),
                resume,
            },
        });
    }

    public void Dispose()
    {
        if (observedLibrary is not null)
        {
            observedLibrary.WishNotificationRequested -= OnWishNotificationRequested;
            observedLibrary = null;
        }
        restCheck.Stop();
        services.Updater?.Dispose();
        playOn?.Cancel();
        playOn?.Dispose();
        playOn = null;
        Remote?.Dispose();
        // The server runs only while Tarven does, unless it keeps running in the background.
        if (hosting is not null) _ = hosting.Host.DisposeAsync().AsTask();
        awake?.Dispose();
        awake = null;
        tray?.Dispose();
        tray = null;
    }

    /// <summary>Remote control of another device in the household, for the open profile.</summary>
    public RemotePlayback? Remote { get; private set; }

    /// <summary>Play On while a profile is open: announce this computer and follow commands from other devices.</summary>
    private void AttachWishNotifications(LibraryStore? library)
    {
        if (observedLibrary is not null) observedLibrary.WishNotificationRequested -= OnWishNotificationRequested;
        observedLibrary = library;
        if (library is not null) library.WishNotificationRequested += OnWishNotificationRequested;
    }

    private void OnWishNotificationRequested(WishNotificationEvent notification)
    {
        if (services.Notifications is { } notifier) _ = notifier.NotifyAsync(notification);
    }

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
        catch (TarvenApiException failure)
        {
            library.Report(failure);
        }
    }

    // MARK: Offline downloads

    /// <summary>Downloads on this computer.</summary>
    public OfflineDownloads? Downloads => services.Downloads;

    /// <summary>Downloads a movie or episode to watch without the server.</summary>
    public void Download(Tarven.Contracts.CatalogItemSummary item) => DownloadAll([item]);

    /// <summary>
    /// Downloads titles one after another, such as a whole season: the quality is chosen once for
    /// all, and each episode gets the nearest quality the server offers for it, or its original.
    /// </summary>
    public void DownloadAll(IReadOnlyList<Tarven.Contracts.CatalogItemSummary> items)
    {
        if (services.Downloads is not { } downloads || Session.Library is not { } library) return;
        var wanted = items.Where(item => item.Kind is Tarven.Contracts.MediaKind.Movie or Tarven.Contracts.MediaKind.Episode
            && downloads.Find(item.Id) is null && !downloads.Active.ContainsKey(item.Id)).ToList();
        if (wanted.Count == 0) return;
        var client = new PlaybackClient(Session.Api, library.Client);
        var preference = PlaybackPreferences.Load(services.Settings).DownloadQuality;
        if (!library.Client.Supports(Tarven.Contracts.ServerFeatures.ConvertedDownloads) || preference == ConvertedDownloads.Original)
        {
            Enqueue(downloads, client, library, wanted, null, null);
            return;
        }
        _ = ChooseDownloadAsync(downloads, client, library, wanted, preference);
    }

    /// <summary>The original or a smaller copy the server converts: as set, or asked for now.</summary>
    private async Task ChooseDownloadAsync(OfflineDownloads downloads, PlaybackClient client, LibraryStore library,
        List<Tarven.Contracts.CatalogItemSummary> items, string preference)
    {
        var first = items[0];
        Tarven.Contracts.DownloadOptionsResponse? options = null;
        try { options = await client.DownloadOptionsAsync(first.Id, CancellationToken.None); }
        catch (Exception failure) when (failure is TarvenApiException or HttpRequestException) { }
        var choice = ConvertedDownloads.Resolve(preference, options);
        string? quality = choice.Quality;
        if (choice.Kind == DownloadChoiceKind.Ask && options is not null && shell?.SheetHost is { } sheets)
        {
            var title = items.Count == 1 ? first.Title : $"{first.ParentTitle ?? first.Title} · {items.Count} Episodes";
            var sheet = new DownloadQualitySheet(title, options, sheets);
            if (!await sheets.ShowAsync(sheet)) return;
            quality = sheet.Quality;
            if (sheet.Remember)
                (PlaybackPreferences.Load(services.Settings) with { DownloadQuality = quality ?? ConvertedDownloads.Original }).Save(services.Settings);
        }
        else if (choice.Kind != DownloadChoiceKind.Converted)
        {
            quality = null;
        }
        Enqueue(downloads, client, library, items, quality, options);
    }

    /// <summary>
    /// Hands the titles to the downloads in their order. Each waits for the one before it; the
    /// Downloads page shows them as waiting until their turn.
    /// </summary>
    private static void Enqueue(OfflineDownloads downloads, PlaybackClient client, LibraryStore library,
        List<Tarven.Contracts.CatalogItemSummary> items, string? quality, Tarven.Contracts.DownloadOptionsResponse? firstOptions) =>
        _ = Task.Run(async () =>
        {
            for (var index = 0; index < items.Count; index++)
            {
                var item = items[index];
                var chosen = quality;
                var options = index == 0 ? firstOptions : null;
                if (quality is not null && index > 0)
                {
                    try { options = await client.DownloadOptionsAsync(item.Id, CancellationToken.None); }
                    catch (Exception failure) when (failure is TarvenApiException or HttpRequestException) { options = null; }
                    var own = ConvertedDownloads.Resolve(quality, options);
                    chosen = own.Kind == DownloadChoiceKind.Converted ? own.Quality : null;
                }
                var expected = options?.Qualities.FirstOrDefault(each => each.Id == chosen)?.EstimatedBytes;
                // Not awaited: the download registers itself now and then waits for its turn.
                _ = downloads.DownloadAsync(client, item, DownloadSubtitle(item), SeriesOf(library, item), chosen,
                    chosen is null ? null : options?.AudioTrack, expected);
            }
        });

    private static string? DownloadSubtitle(Tarven.Contracts.CatalogItemSummary item) => item.Kind == Tarven.Contracts.MediaKind.Episode
        ? string.Join(" · ", new[] { item.ParentTitle, item.SeasonNumber is { } season ? $"S{season} E{item.EpisodeNumber}" : null }.Where(part => part is not null))
        : item.Year?.ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>The series poster goes along, so an episode looks like its series on the Downloads page.</summary>
    private static Tarven.Contracts.CatalogItemSummary? SeriesOf(LibraryStore library, Tarven.Contracts.CatalogItemSummary item) =>
        item.ParentId is { } parent ? library.Catalog.FirstOrDefault(each => each.Id == parent) : null;

    /// <summary>
    /// Tarven Test's Reset App Data: stops its own test server, erases the test edition's folders and keyring
    /// entry, and starts Tarven Test again from the beginning.
    /// </summary>
    private async Task ResetTestEditionAsync()
    {
        var paths = AppPaths.FromEnvironment();
        if (!TestEdition.MayErase(paths, AppInfo.IsTestEdition)) return;
        if (hosting is not null) await hosting.Host.StopAsync();
        await TestEdition.EraseAsync(paths, services.Credentials, AppInfo.IsTestEdition, CancellationToken.None);
        Restart(edition: "test");
    }

    /// <summary>The longest side of the largest connected screen in device pixels; 0 when unknown.</summary>
    private int LargestScreenSide()
    {
        try
        {
            return Screens.All.Count == 0 ? 0 : Screens.All.Max(screen => Math.Max(screen.Bounds.Width, screen.Bounds.Height));
        }
        catch (Exception error) when (error is InvalidOperationException or NotSupportedException)
        {
            return 0;
        }
    }

    public void PlayOffline(OfflineTitle title) => _ = PlayOfflineAsync(title, null);

    /// <summary>The offline mode is offered for a server on another computer when downloads of it are here.</summary>
    private bool CanOfferOffline => Flow.Mode == OperatingMode.Client && OfflineModeModel.CanOffer(services.Downloads, Session.Server?.ServerId);

    private Control OfflineScreen()
    {
        if (services.Downloads is not { } downloads || Session.Server is not { } server)
            return new ServerUnreachableView(Session);
        // A profile open already keeps going; otherwise its card opens it.
        var mine = Session.OfflineTitlesForOpenProfile(downloads);
        var open = mine.Count > 0 && Session.Profile is { } profile
            ? new OfflineSession(server.ServerId, profile.User.Id, Core.ProfileVisuals.ShownName(profile.User), profile.User.PictureKey, profile.User.PictureRevision)
            : null;
        var model = new OfflineModeModel(downloads, offlineCards, server.ServerId, server.Name, services.Time, open);
        return new OfflineModeView(model, downloads, (title, session) =>
        {
            var client = Session.OfflineClient() is { } own && own.Profile.User.Id == session.UserId
                ? own
                : OfflineClientFor(server, session);
            _ = PlayOfflineAsync(title, client);
        }, Session.LeaveOfflineAsync);
    }

    /// <summary>A client for a profile opened offline: it has no session on the server, so nothing it asks there succeeds.</summary>
    private LibraryClient OfflineClientFor(StoredServer server, OfflineSession session)
    {
        var now = services.Time.GetUtcNow();
        var user = new Tarven.Contracts.UserSummary(session.UserId, session.Name, Tarven.Contracts.UserRole.User, now);
        return new LibraryClient(Session.Api, server, new ProfileSession(user, Guid.Empty, "offline", now), Session.Capabilities);
    }

    private async Task PlayOfflineAsync(OfflineTitle title, LibraryClient? offlineClient)
    {
        // The open profile's own downloads also play while the server does not answer.
        if (services.Downloads is not { } downloads || (offlineClient ?? Session.OfflineClient()) is not { } client || services.Engines is null) return;
        if (client.Profile.User.Id != title.UserId || client.Server.ServerId != title.ServerId) return;
        if (Player is { } running) await running.CloseAsync();
        var outbox = new ProgressOutbox(null);
        var player = new PlaybackController(new PlaybackClient(Session.Api, client), services.Engines, services.Settings, outbox,
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
        });
        PlayerHost.Content = view;
        PlayerHost.IsVisible = true;
        await player.StartOfflineAsync(title, downloads);
    }

    /// <summary>The player while a title plays, else null.</summary>
    public PlaybackController? Player { get; private set; }

    /// <summary>Opens the player over the library for a title (a series plays its next episode).</summary>
    public async Task PlayAsync(Tarven.Contracts.CatalogItemSummary item, bool resume, long? startAt = null, IReadOnlyList<Tarven.Contracts.CatalogItemSummary>? playlist = null)
    {
        if (Session.Library is not { } library || services.Engines is null) return;
        if (Player is { } running) await running.CloseAsync();
        var outbox = new ProgressOutbox(services.StateDirectory is { } state ? Path.Combine(state, "pending-progress.json") : null);
        var player = new PlaybackController(new PlaybackClient(Session.Api, library.Client), services.Engines, services.Settings, outbox,
            services.Time, action => Dispatcher.UIThread.Post(action), services.PlaybackSystem);
        Player = player;
        var view = new PlayerView(player, this) { Store = library };
        // Watch Now on a suggestion: the closed player hands over to the suggested title.
        player.SuggestionChosen += next => Dispatcher.UIThread.Post(() => _ = PlayAsync(next, resume: false));
        player.Closed += () => Dispatcher.UIThread.Post(() =>
        {
            if (Player != player) return;
            Player = null;
            PlayerHost.Content = null;
            PlayerHost.IsVisible = false;
            view.Dispose();
            if (WindowState == WindowState.FullScreen) WindowState = WindowState.Normal;
            // Screen time closed the whole profile: after the good-night screen, "Who's watching?".
            if (player.GoodNightEndsProfile) _ = Session.SwitchProfileAsync();
            else _ = library.RefreshHomeAsync();
        });
        PlayerHost.Content = view;
        PlayerHost.IsVisible = true;
        await outbox.FlushAsync(player.Client, CancellationToken.None);
        Task StartChosen() => playlist is { Count: > 0 }
            ? player.StartQueueAsync(playlist, item, resume, startAt)
            : player.StartAsync(item, resume, startAt);
        // Cinema mode: an ad, trailers and the curtain before a film that starts from its beginning.
        var preShow = await CinemaPreShow.PrepareAsync(player.Client, services.Engines, services.Time, action => Dispatcher.UIThread.Post(action),
            item, resume, startAt, PlaybackPreferences.Load(services.Settings), services.Settings);
        if (preShow is null || Player != player)
        {
            await StartChosen();
            return;
        }
        var started = false;
        Task StartFilm()
        {
            if (started) return Task.CompletedTask;
            started = true;
            return StartChosen();
        }
        var curtain = new CinemaView(preShow, () => _ = player.CloseAsync());
        void FilmMoving(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
        {
            if (e.PropertyName == nameof(PlaybackController.State) && player.State == PlayerState.Playing) preShow.FilmStarted();
        }
        player.PropertyChanged += FilmMoving;
        player.Closed += preShow.Stop;
        preShow.Feature = StartFilm;
        PlayerHost.Content = new Grid { Children = { view, curtain } };
        curtain.Focus();
        await preShow.RunAsync();
        player.PropertyChanged -= FilmMoving;
        if (Player == player)
        {
            PlayerHost.Content = view;
            await StartFilm();
        }
        curtain.Dispose();
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
        view.SettingsRequested += () => OpenSettings();
        _ = model.LoadAsync();
        return view;
    }
}
