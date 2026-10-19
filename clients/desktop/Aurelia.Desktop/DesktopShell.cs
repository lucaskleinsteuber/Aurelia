using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Platform;
using Avalonia.Threading;
using Aurelia.Desktop.Core;
using Aurelia.Desktop.Views;

namespace Aurelia.Desktop;

/// <summary>
/// The running app around its one window: an icon in the notification area while this computer's
/// server runs, the window opened again from there or by a second start, and Quit Aurelia, which
/// stops the server cleanly.
/// </summary>
internal sealed class DesktopShell : IDisposable
{
    private readonly MainWindow window;
    private readonly Action shutdown;
    private readonly TrayIcon tray;
    private readonly NativeMenuItem status;
    private bool ended;

    public DesktopShell(Application app, IClassicDesktopStyleApplicationLifetime desktop)
        : this(app, new MainWindow(), () => desktop.Shutdown())
    {
        desktop.MainWindow = window;
        desktop.ShutdownRequested += (_, e) =>
        {
            // Quit from the macOS menu stops the server first. On Windows this only comes with signing
            // out or shutting down, which must not wait; the server's lifeline ends it with the app.
            if (ended || OperatingSystem.IsWindows()) return;
            e.Cancel = true;
            _ = QuitAsync();
        };
        desktop.Exit += (_, _) => Dispose();
    }

    internal DesktopShell(Application app, MainWindow window, Action shutdown)
    {
        this.window = window;
        this.shutdown = shutdown;
        window.Closed += (_, _) => End();
        status = new NativeMenuItem("Aurelia Server is stopped") { IsEnabled = false };
        var open = new NativeMenuItem("Open Aurelia");
        open.Click += (_, _) => Open();
        var quit = new NativeMenuItem("Quit Aurelia");
        quit.Click += async (_, _) => await QuitAsync();
        tray = new TrayIcon
        {
            Icon = new WindowIcon(AssetLoader.Open(new Uri("avares://Aurelia/Assets/aurelia.ico"))),
            ToolTipText = "Aurelia",
            Menu = new NativeMenu { Items = { open, status, new NativeMenuItemSeparator(), quit } },
            IsVisible = false,
        };
        tray.Clicked += (_, _) => Open();
        TrayIcon.SetIcons(app, new TrayIcons { tray });
        if (window.HostFlow?.Host is { } server) server.Changed += () => Dispatcher.UIThread.Post(UpdateTray);
        UpdateTray();
    }

    internal bool ShowsTrayIcon => tray.IsVisible;
    internal string TrayStatus => status.Header ?? "";
    internal bool HasEnded => ended;

    /// <summary>Opens the window, or at sign-in (background) only starts this computer's server.</summary>
    public async Task StartAsync(bool background)
    {
        if (!background)
        {
            window.Show();
            return;
        }
        if (!window.HostsThisComputer)
        {
            // Aurelia connects to a server elsewhere: nothing to run until the person opens it.
            End();
            return;
        }
        await window.StartAsync();
    }

    public void Open()
    {
        if (ended) return;
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    public async Task QuitAsync()
    {
        if (ended) return;
        await window.QuitAsync();
        End();
    }

    /// <summary>A later start asks to open the window, or the installer asks to quit; answered once done.</summary>
    public Task HandleAsync(StartRequest request)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Dispatcher.UIThread.Post(async () =>
        {
            try
            {
                if (request == StartRequest.Quit) await QuitAsync();
                else Open();
            }
            finally { done.TrySetResult(); }
        });
        return done.Task;
    }

    private void UpdateTray()
    {
        var server = window.HostFlow?.Host;
        tray.IsVisible = !ended && server is not null && server.State != LocalServerState.Stopped;
        var text = window.Hosting?.StatusText ?? "Aurelia";
        status.Header = text;
        tray.ToolTipText = text;
    }

    public void Dispose() => tray.Dispose();

    private void End()
    {
        if (ended) return;
        ended = true;
        tray.IsVisible = false;
        // A moment for the reply to the installer, then the app ends.
        DispatcherTimer.RunOnce(shutdown, TimeSpan.FromMilliseconds(200));
    }
}
