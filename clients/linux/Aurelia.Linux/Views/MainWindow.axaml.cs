using System.ComponentModel;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Flow;
using Avalonia.Controls;
using Avalonia.Input;

namespace Aurelia.Linux.Views;

public sealed partial class MainWindow : Window
{
    private readonly AppServices services;
    private LibraryShell? shell;

    public MainWindow() : this(AppServices.CreateDefault())
    {
    }

    public MainWindow(AppServices services)
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
        Flow.PropertyChanged += OnFlowChanged;
        KeyBindings.Add(new KeyBinding { Gesture = new KeyGesture(Key.Q, KeyModifiers.Control), Command = new RelayCommand(Close) });
        ShowScreen();
        Opened += (_, _) => Flow.FinishStarting();
    }

    public AppFlow Flow { get; }

    internal LibraryShell? Shell => shell;

    internal Control? CurrentScreen => ScreenHost.Content as Control;

    private void OnFlowChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppFlow.Screen)) ShowScreen();
    }

    private void ShowScreen()
    {
        Control screen = Flow.Screen switch
        {
            AppScreen.Starting => new StartingView(),
            AppScreen.Welcome => new WelcomeView(Flow),
            AppScreen.HostSetup => new PreviewNoticeView(Flow, "Set Up This PC",
                "Hosting your library on this computer arrives in a later test build. Until then, connect to a server that runs elsewhere."),
            AppScreen.Connection => new PreviewNoticeView(Flow, "Connect to a Server",
                "Finding and pairing with your server arrives in the next test build."),
            _ => shell ??= new LibraryShell { LeadingInset = Chrome.LeadingWidth },
        };
        ScreenHost.Content = screen;
    }
}
