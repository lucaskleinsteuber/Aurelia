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

    public StartingView(AppSession? session = null)
    {
        this.session = session;
        stopWaiting.Click += (_, _) => session?.StopWaiting();
        Content = ScreenParts.Backdrop(new StackPanel
        {
            Spacing = 22,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { ScreenParts.Symbol("IconAurelia", 46), status, new ProgressBar { IsIndeterminate = true, Width = 120 }, stopWaiting },
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
    }
}
