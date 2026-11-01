using System.ComponentModel;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Settings;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Threading;

namespace Aurelia.Linux.Views;

public sealed partial class MainWindow : Window
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
        KeyBindings.Add(new KeyBinding { Gesture = new KeyGesture(Key.Q, KeyModifiers.Control), Command = new RelayCommand(Close) });
        ShowScreen();
        if (startSession) Opened += async (_, _) => await Session.StartAsync();
        Closed += (_, _) =>
        {
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
            AppScreen.HostSetup => new PreviewNoticeView(Flow, "Set Up This PC",
                "Hosting your library on this computer arrives in a later test build. Until then, connect to a server that runs elsewhere."),
            AppScreen.Connection => new ConnectionView(new ConnectionModel(Session, services.CreateDiscovery(), action => Dispatcher.UIThread.Post(action)), Flow),
            AppScreen.ServerUnreachable => new ServerUnreachableView(Session),
            AppScreen.ProfilePicker => ProfilePicker(),
            _ => shell ??= new LibraryShell { LeadingInset = Chrome.LeadingWidth, Session = Session },
        };
        ScreenHost.Content = screen;
    }

    private ProfilePickerView ProfilePicker()
    {
        var model = new ProfilePickerModel(Session);
        var view = new ProfilePickerView(model, Session);
        _ = model.LoadAsync();
        return view;
    }
}
