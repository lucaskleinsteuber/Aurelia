using Aurelia.Linux.Core.Playback;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace Aurelia.Linux.Library;

/// <summary>Downloads: titles kept on this computer to watch without the server, and the ones loading now.</summary>
public sealed class DownloadsPage : LibraryPageBase
{
    public DownloadsPage(LibraryContext context) : base(context)
    {
        AttachedToVisualTree += (_, _) =>
        {
            if (Context.Navigator.Downloads is { } downloads) downloads.Changed += OnDownloadsChanged;
            Rebuild();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            if (Context.Navigator.Downloads is { } downloads) downloads.Changed -= OnDownloadsChanged;
        };
    }

    private void OnDownloadsChanged() => Dispatcher.UIThread.Post(Rebuild);

    protected override void OnStoreChanged()
    {
    }

    protected override Control Build()
    {
        var page = new StackPanel { Spacing = 18, Margin = new Thickness(0, 64, 0, 48) };
        page.Children.Add(PageTitle("Downloads").Also(t => t.Margin = Inset()));
        var downloads = Context.Navigator.Downloads;
        page.Children.Add(new TextBlock
        {
            Text = "Titles on this computer play even when the server is asleep or out of reach. Progress goes back to the server when it answers again.",
            TextWrapping = TextWrapping.Wrap,
            Classes = { "subdued" },
            Margin = Inset(),
        });
        if (downloads is null) return page;
        if (downloads.TotalBytes > 0)
            page.Children.Add(new TextBlock { Text = $"{Management.AdminScope.Bytes(downloads.TotalBytes)} used on this computer", FontSize = 12, Classes = { "subdued" }, Margin = Inset() });
        if (downloads.Error is { } error)
            page.Children.Add(new TextBlock { Text = error, TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(Color.Parse("#FFB36B")), Margin = Inset() });
        foreach (var (id, share) in downloads.Active)
        {
            var cancel = new Button { Content = "Cancel", Classes = { "chip" } };
            cancel.Click += (_, _) => downloads.Cancel(id);
            page.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 12,
                Margin = Inset(),
                Children =
                {
                    new TextBlock { Text = downloads.ActiveName(id) ?? "Downloading", MaxWidth = 260, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center },
                    new ProgressBar { Minimum = 0, Maximum = 1, Value = share, Width = 260, VerticalAlignment = VerticalAlignment.Center },
                    new TextBlock { Text = $"{(int)(share * 100)} %", VerticalAlignment = VerticalAlignment.Center, Classes = { "subdued" } },
                    cancel,
                },
            });
        }
        var profile = Context.Store.Client.Profile.User.Id;
        var titles = downloads.For(Context.Store.Client.Server.ServerId, profile);
        if (titles.Count == 0 && downloads.Active.Count == 0)
        {
            page.Children.Add(EmptyState("No Downloads", "Choose Download in a movie's or episode's menu to keep it on this computer."));
            return page;
        }
        foreach (var title in titles) page.Children.Add(Row(downloads, title));
        return page;
    }

    private Border Row(OfflineDownloads downloads, OfflineTitle title)
    {
        var details = new List<string>();
        if (!string.IsNullOrEmpty(title.Subtitle)) details.Add(title.Subtitle);
        details.Add(Management.AdminScope.Bytes(title.Bytes));
        if (title.IsCompleted) details.Add("Watched");
        else if (title.PositionMilliseconds > 0 && title.DurationMilliseconds > 0) details.Add($"{title.PositionMilliseconds * 100 / title.DurationMilliseconds} % watched");
        if (title.ProgressDirty) details.Add("Progress not yet on the server");
        var play = new Button { Content = title.PositionMilliseconds > 0 && !title.IsCompleted ? "Resume" : "Play", Classes = { "primary" } };
        AutomationProperties.SetName(play, "Play " + title.Title);
        play.Click += (_, _) => Context.Navigator.PlayOffline(title);
        var remove = new Button { Content = "Remove", Classes = { "chip" } };
        AutomationProperties.SetName(remove, "Remove Download " + title.Title);
        remove.Click += async (_, _) =>
        {
            if (await Context.Navigator.ConfirmAsync($"Remove {title.Title}?", "The copy on this computer is deleted. The title stays on the server.", "Remove Download", destructive: true))
                downloads.Remove(title.Id);
        };
        var row = new DockPanel { LastChildFill = true };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center, Children = { play, remove } };
        DockPanel.SetDock(buttons, Dock.Right);
        row.Children.Add(buttons);
        row.Children.Add(new StackPanel
        {
            Spacing = 2,
            Children =
            {
                new TextBlock { Text = title.Title, FontWeight = FontWeight.SemiBold },
                new TextBlock { Text = string.Join(" · ", details), FontSize = 12, Classes = { "subdued" } },
            },
        });
        return new Border { Classes = { "card" }, Padding = new Thickness(16, 12), Margin = Inset(), Child = row };
    }
}
