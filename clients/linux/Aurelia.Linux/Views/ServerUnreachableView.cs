using Aurelia.Linux.Core.Flow;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;

namespace Aurelia.Linux.Views;

/// <summary>The saved server did not answer: try again (which wakes it), or forget it and connect to another one.</summary>
public sealed class ServerUnreachableView : UserControl
{
    public ServerUnreachableView(AppSession session)
    {
        var name = session.Server?.Name ?? "Your server";
        var tryAgain = new Button { Content = "Try Again", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center };
        tryAgain.Click += async (_, _) => await session.ReachServerAsync();
        var forget = new Button { Content = "Use Another Server…", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        var confirm = new Button { Content = "Forget This Server", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center, IsVisible = false };
        forget.Click += (_, _) =>
        {
            forget.IsVisible = false;
            confirm.IsVisible = true;
        };
        confirm.Click += async (_, _) => await session.DisconnectAsync();
        var wakeable = session.Server?.WakeOnLanAddresses is { Count: > 0 };
        Content = ScreenParts.Backdrop(new StackPanel
        {
            Spacing = 16,
            Margin = new Thickness(40),
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                ScreenParts.Symbol("IconServer", 46),
                ScreenParts.Title("Server Not Answering"),
                ScreenParts.Detail(session.Message ?? (wakeable
                    ? $"{name} did not wake up. Check that it is plugged in and connected to your network."
                    : $"{name} did not respond. Check that it is turned on and connected to your network.")),
                tryAgain,
                forget,
                confirm,
            },
        });
    }
}
