using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Playback;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;

namespace Aurelia.Linux.Views;

/// <summary>The saved server did not answer: try again (which wakes it), or forget it and connect to another one.</summary>
public sealed class ServerUnreachableView : UserControl
{
    public ServerUnreachableView(AppSession session, IReadOnlyList<OfflineTitle>? downloads = null, Action<OfflineTitle>? play = null, Action? offline = null)
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
        // As on the Mac: the downloads on this computer, without the server.
        var watchOffline = new Button { Content = "Watch Downloads Offline", Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Center, IsVisible = offline is not null };
        watchOffline.Click += (_, _) => offline?.Invoke();
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
                watchOffline,
                forget,
                confirm,
                Downloads(downloads, play),
            },
        });
    }

    /// <summary>"Watch a Download": the open profile's own downloads, which play without the server.</summary>
    private static StackPanel Downloads(IReadOnlyList<OfflineTitle>? downloads, Action<OfflineTitle>? play)
    {
        var list = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, IsVisible = downloads is { Count: > 0 } && play is not null };
        if (!list.IsVisible) return list;
        list.Children.Add(new TextBlock { Text = "Watch a Download", FontWeight = Avalonia.Media.FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
        foreach (var title in downloads!)
        {
            var button = new Button
            {
                Content = string.IsNullOrEmpty(title.Subtitle) ? title.Title : $"{title.Title} · {title.Subtitle}",
                Classes = { "chip" },
                HorizontalAlignment = HorizontalAlignment.Center,
            };
            Avalonia.Automation.AutomationProperties.SetName(button, "Play " + title.Title);
            button.Click += (_, _) => play!(title);
            list.Children.Add(button);
        }
        return list;
    }
}
