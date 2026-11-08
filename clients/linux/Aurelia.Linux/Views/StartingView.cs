using System.ComponentModel;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Avalonia.Controls;
using Avalonia.Layout;

namespace Aurelia.Linux.Views;

/// <summary>Shown while Aurelia reads its saved state and reaches its server, like the Mac app's start screen.</summary>
public sealed class StartingView : UserControl
{
    private readonly AppSession? session;
    private readonly TextBlock status = new() { Classes = { "subdued" }, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Button stopWaiting = new() { Content = "Stop Waiting", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Button watchOffline = new() { Content = "Watch Downloads Offline", Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Center, IsVisible = false };
    private readonly Func<bool>? canWatchOffline;

    /// <param name="offline">Opens the offline mode; offered while the server is looked for or woken, as on the Mac.</param>
    /// <param name="canWatchOffline">Asked at each status change: when Aurelia opens, the saved server is only known once it is being reached.</param>
    public StartingView(AppSession? session = null, Action? offline = null, Func<bool>? canWatchOffline = null)
    {
        this.session = session;
        this.canWatchOffline = offline is null ? null : canWatchOffline ?? (() => true);
        stopWaiting.Click += (_, _) => session?.StopWaiting();
        watchOffline.Click += (_, _) => offline?.Invoke();
        Content = ScreenParts.Backdrop(new StackPanel
        {
            Spacing = 22,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { ScreenParts.Symbol("IconAurelia", 46), status, new Aurelia.Linux.Controls.Spinner { HorizontalAlignment = HorizontalAlignment.Center }, watchOffline, stopWaiting },
        });
        Update();
        if (session is not null)
        {
            session.PropertyChanged += OnSessionChanged;
            DetachedFromVisualTree += (_, _) => session.PropertyChanged -= OnSessionChanged;
        }
    }

    internal string StatusText => status.Text ?? "";

    private void OnSessionChanged(object? sender, PropertyChangedEventArgs e) => Update();

    private void Update()
    {
        var name = session?.Server?.Name;
        status.Text = (session?.Status, name) switch
        {
            (ConnectionStatus.Connecting, { } server) => $"Connecting to {server}…",
            (ConnectionStatus.Waking, { } server) => $"Waking {server}…",
            (ConnectionStatus.Loading, { } server) => $"Loading from {server}…",
            _ => "Starting Aurelia…",
        };
        stopWaiting.IsVisible = session?.Status == ConnectionStatus.Waking;
        watchOffline.IsVisible = canWatchOffline?.Invoke() == true && session?.Status is ConnectionStatus.Connecting or ConnectionStatus.Waking;
    }
}
