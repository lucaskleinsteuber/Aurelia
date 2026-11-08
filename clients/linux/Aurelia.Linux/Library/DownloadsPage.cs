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
            if (Context.Navigator.Downloads is { } downloads)
            {
                downloads.Changed += OnDownloadsChanged;
                // Downloads made before artwork was kept get their poster and description now.
                var store = Context.Store;
                if (store.Catalog.Count > 0) _ = Task.Run(() => downloads.CompleteDetailsAsync(store.Client, store.Catalog));
            }
            Rebuild();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            if (Context.Navigator.Downloads is { } downloads) downloads.Changed -= OnDownloadsChanged;
        };
    }

    private readonly Dictionary<string, Avalonia.Media.Imaging.Bitmap?> posters = [];

    private void OnDownloadsChanged() => Dispatcher.UIThread.Post(Rebuild);

    /// <summary>The title's poster (or its series' poster) from this computer, decoded once per page.</summary>
    private Avalonia.Media.Imaging.Bitmap? Poster(OfflineDownloads downloads, OfflineTitle title)
    {
        if ((title.PosterFile ?? title.SeriesPosterFile) is not { } name) return null;
        var path = Path.Combine(downloads.Folder(title.Id), name);
        if (posters.TryGetValue(path, out var known)) return known;
        Avalonia.Media.Imaging.Bitmap? image = null;
        try
        {
            using var file = File.OpenRead(path);
            image = Avalonia.Media.Imaging.Bitmap.DecodeToWidth(file, 120);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or NotSupportedException)
        {
        }
        posters[path] = image;
        return image;
    }

    private Border PosterOf(OfflineDownloads downloads, OfflineTitle title)
    {
        Control content = Poster(downloads, title) is { } image
            ? new Image { Source = image, Stretch = Stretch.UniformToFill }
            : new PathIcon
            {
                Data = Application.Current?.FindResource(title.Kind == Aurelia.Contracts.MediaKind.Episode ? "IconTvShows" : "IconMovies") as Geometry,
                Width = 18,
                Height = 18,
                Foreground = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)),
            };
        return new Border
        {
            Width = 40,
            Height = 60,
            CornerRadius = new CornerRadius(6),
            ClipToBounds = true,
            Background = new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF)),
            Margin = new Thickness(0, 0, 14, 0),
            Child = content,
        };
    }

    protected override void OnStoreChanged()
    {
    }

    protected override Control Build()
    {
        var page = new StackPanel { Spacing = 18, Margin = new Thickness(0, 64, 0, 48) };
        page.Children.Add(PageTitle("Downloads").Also(t => t.Margin = Inset()));
        var downloads = Context.Navigator.Downloads;
        if (downloads is null) return page;
        var profile = Context.Store.Client.Profile.User.Id;
        var titles = downloads.For(Context.Store.Client.Server.ServerId, profile);
        if (titles.Count == 0 && downloads.Active.Count == 0 && downloads.Error is null)
        {
            page.Children.Add(EmptyDownloads());
            return page;
        }
        page.Children.Add(new TextBlock
        {
            Text = "These titles play even when the server is asleep or out of reach. Progress goes back to the server when it answers again.",
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 620,
            HorizontalAlignment = HorizontalAlignment.Left,
            Classes = { "subdued" },
            Margin = Inset(),
        });
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
        foreach (var title in titles) page.Children.Add(Row(downloads, title));
        return page;
    }

    /// <summary>No downloads yet: a symbol, one sentence and the three steps, centered on the page.</summary>
    private Border EmptyDownloads()
    {
        static Control Step(string number, string text) => new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 12,
            Children =
            {
                new Border
                {
                    Width = 26,
                    Height = 26,
                    CornerRadius = new CornerRadius(13),
                    Background = new SolidColorBrush(Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF)),
                    Child = new TextBlock { Text = number, FontWeight = FontWeight.SemiBold, FontSize = 13, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
                },
                new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center },
            },
        };
        return new Border
        {
            Classes = { "card" },
            Margin = new Thickness(Inset().Left, 40, Inset().Right, 0),
            Padding = new Thickness(36, 32),
            MaxWidth = 520,
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = new StackPanel
            {
                Spacing = 14,
                Children =
                {
                    new Border
                    {
                        Width = 64,
                        Height = 64,
                        CornerRadius = new CornerRadius(32),
                        HorizontalAlignment = HorizontalAlignment.Center,
                        Background = new SolidColorBrush(Color.FromArgb(0x1F, 0x0A, 0x84, 0xFF)),
                        Child = new PathIcon { Data = Application.Current?.FindResource("IconDownloads") as Geometry, Width = 30, Height = 30, Foreground = Application.Current?.FindResource("AureliaAccentBrush") as IBrush },
                    },
                    new TextBlock { Text = "No Downloads Yet", FontSize = 20, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center },
                    new TextBlock
                    {
                        Text = "Keep movies and episodes on this computer to watch them without the server.",
                        Classes = { "subdued" },
                        TextWrapping = TextWrapping.Wrap,
                        TextAlignment = TextAlignment.Center,
                        HorizontalAlignment = HorizontalAlignment.Center,
                    },
                    new StackPanel
                    {
                        Spacing = 10,
                        Margin = new Thickness(0, 8, 0, 0),
                        HorizontalAlignment = HorizontalAlignment.Center,
                        Children =
                        {
                            Step("1", "Open a movie or an episode."),
                            Step("2", "Choose Download in its menu."),
                            Step("3", "Watch it here, even offline."),
                        },
                    },
                },
            },
        };
    }

    private Border Row(OfflineDownloads downloads, OfflineTitle title)
    {
        var details = new List<string>();
        if (!string.IsNullOrEmpty(title.Subtitle)) details.Add(title.Subtitle);
        else if (title.Year is { } year) details.Add(year.ToString(System.Globalization.CultureInfo.InvariantCulture));
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
        row.Children.Add(PosterOf(downloads, title).Also(p => DockPanel.SetDock(p, Dock.Left)));
        row.Children.Add(new StackPanel
        {
            Spacing = 2,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                new TextBlock { Text = title.Title, FontWeight = FontWeight.SemiBold },
                new TextBlock { Text = string.Join(" · ", details), FontSize = 12, Classes = { "subdued" } },
            },
        });
        return new Border { Classes = { "card" }, Padding = new Thickness(16, 12), Margin = Inset(), Child = row };
    }
}
