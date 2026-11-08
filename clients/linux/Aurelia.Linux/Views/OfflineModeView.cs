using System.ComponentModel;
using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Playback;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Aurelia.Linux.Views;

/// <summary>
/// The offline mode, as on the Mac: whose downloads to show (a card's PIN opens it), then a small
/// library of that profile's downloads: the title to continue, Continue Watching, movies and each
/// series with its episodes. No settings, management or server requests; Connect to Server leaves it.
/// </summary>
public sealed class OfflineModeView : UserControl
{
    private readonly OfflineModeModel model;
    private readonly OfflineDownloads downloads;
    private readonly Action<OfflineTitle, OfflineSession> play;
    private readonly Func<Task> connect;
    private readonly Dictionary<string, Bitmap?> pictures = [];
    private OfflineProfileCard? entering;

    public OfflineModeView(OfflineModeModel model, OfflineDownloads downloads, Action<OfflineTitle, OfflineSession> play, Func<Task> connect)
    {
        this.model = model;
        this.downloads = downloads;
        this.play = play;
        this.connect = connect;
        model.PropertyChanged += OnModelChanged;
        downloads.Changed += OnDownloadsChanged;
        DetachedFromVisualTree += (_, _) =>
        {
            model.PropertyChanged -= OnModelChanged;
            downloads.Changed -= OnDownloadsChanged;
            foreach (var picture in pictures.Values) picture?.Dispose();
        };
        Build();
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(OfflineModeModel.Session) or nameof(OfflineModeModel.Titles)) Build();
    }

    private void OnDownloadsChanged() => Dispatcher.UIThread.Post(model.Refresh);

    private void Build() => Content = model.Session is { } open ? Downloads(open) : Profiles();

    private Button ConnectButton(string classes)
    {
        var button = new Button { Content = "Connect to Server", Classes = { classes }, HorizontalAlignment = HorizontalAlignment.Center };
        button.Click += async (_, _) => await connect();
        return button;
    }

    // ── Choosing whose downloads to show ────────────────────────────────────────────────────────

    private Panel Profiles()
    {
        var page = new StackPanel { Spacing = 22, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(40) };
        if (entering is { } card)
        {
            page.Children.Add(PinEntry(card));
            return ScreenParts.Backdrop(page);
        }
        page.Children.Add(ScreenParts.Title("Watch Downloads Offline"));
        page.Children.Add(ScreenParts.Detail($"Without {model.ServerName}, Aurelia shows what is downloaded on this computer. Choose whose downloads to watch."));
        var tiles = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center, ItemSpacing = 28, LineSpacing = 28 };
        foreach (var choice in model.Choices) tiles.Children.Add(Tile(choice));
        page.Children.Add(tiles);
        page.Children.Add(ConnectButton("link"));
        return ScreenParts.Backdrop(page);
    }

    private Button Tile(OfflineProfileChoice choice)
    {
        var card = choice.Card;
        var name = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 5,
            HorizontalAlignment = HorizontalAlignment.Center,
            Children = { new TextBlock { Text = card?.Name ?? "Profile", FontSize = 16, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap, MaxWidth = 130, TextAlignment = TextAlignment.Center } },
        };
        if (card is { PinProtected: true })
            name.Children.Add(ScreenParts.Symbol("IconLock", 11, new SolidColorBrush(Color.FromArgb(0xA6, 0xFF, 0xFF, 0xFF))).Also(l => l.VerticalAlignment = VerticalAlignment.Center));
        var tile = new StackPanel
        {
            Spacing = 12,
            Children = { new ProfileAvatar(choice.UserId, card?.Name ?? "?", 96, card?.PictureKey, card?.PictureRevision ?? 0).Also(a => a.HorizontalAlignment = HorizontalAlignment.Center), name },
        };
        if (card is null)
        {
            tile.Children.Add(new TextBlock
            {
                Text = "Open this profile once while the server answers.",
                Classes = { "subdued" },
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                MaxWidth = 150,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
        }
        var button = new Button { Classes = { "profile" }, IsEnabled = card is not null, VerticalAlignment = VerticalAlignment.Top, Content = tile };
        AutomationProperties.SetName(button, card?.Name ?? "Profile without offline access");
        button.Click += (_, _) =>
        {
            if (card is null) return;
            if (!card.PinProtected)
            {
                model.OpenProfile(card, null);
                return;
            }
            entering = card;
            Build();
        };
        return button;
    }

    private StackPanel PinEntry(OfflineProfileCard card)
    {
        var error = new TextBlock { Foreground = new SolidColorBrush(Color.Parse("#FFA94D")), HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 420 };
        var pin = new TextBox { PasswordChar = '•', MaxLength = 8, FontSize = 20, Classes = { "pinField" }, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(pin, "PIN");
        // The capsule is the field; the theme's own focused box inside it must not show.
        pin.TemplateApplied += (_, e) =>
        {
            if (e.NameScope.Find<Border>("PART_BorderElement") is { } box)
            {
                box.Background = Brushes.Transparent;
                box.BorderBrush = Brushes.Transparent;
                box.BorderThickness = new Thickness(0);
            }
        };
        var unlock = new Button { Classes = { "pinArrow" }, IsEnabled = false, Content = new PathIcon { Data = Application.Current?.FindResource("IconArrowRight") as Geometry, Width = 15, Height = 15 } };
        AutomationProperties.SetName(unlock, "Open Profile");
        var capsule = new Border
        {
            Classes = { "pinCapsule" },
            Width = 280,
            Height = 52,
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = new Grid
            {
                ColumnDefinitions = new ColumnDefinitions("44,*,44"),
                Children = { pin.Also(p => Grid.SetColumn(p, 1)), unlock.Also(u => Grid.SetColumn(u, 2)) },
            },
        };
        pin.GotFocus += (_, _) => capsule.Classes.Set("focused", true);
        pin.LostFocus += (_, _) => capsule.Classes.Set("focused", false);
        pin.PropertyChanged += (_, e) =>
        {
            if (e.Property == TextBox.TextProperty) unlock.IsEnabled = !string.IsNullOrEmpty(pin.Text);
        };
        void Submit()
        {
            var entered = pin.Text ?? "";
            pin.Text = "";
            if (model.OpenProfile(card, entered))
            {
                entering = null;
                return;
            }
            error.Text = model.LockedUntil is { } until && until > DateTimeOffset.UtcNow
                ? $"Too many wrong PINs. Try again in {Math.Max(1, (int)Math.Ceiling((until - DateTimeOffset.UtcNow).TotalSeconds))} seconds."
                : "PIN is incorrect.";
        }
        unlock.Click += (_, _) => Submit();
        pin.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                Submit();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape)
            {
                entering = null;
                Build();
                e.Handled = true;
            }
        };
        var back = new Button { Classes = { "profileAvatar" }, HorizontalAlignment = HorizontalAlignment.Center, Content = new ProfileAvatar(card.UserId, card.Name, 96, card.PictureKey, card.PictureRevision) };
        AutomationProperties.SetName(back, "Choose Another Profile");
        back.Click += (_, _) =>
        {
            entering = null;
            Build();
        };
        Dispatcher.UIThread.Post(() => pin.Focus());
        return new StackPanel
        {
            Spacing = 22,
            HorizontalAlignment = HorizontalAlignment.Center,
            Children =
            {
                back,
                new StackPanel
                {
                    Spacing = 6,
                    Children =
                    {
                        new TextBlock { Text = card.Name, FontSize = 22, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center },
                        new TextBlock { Text = "Enter your PIN", Classes = { "subdued" }, FontSize = 14, HorizontalAlignment = HorizontalAlignment.Center },
                    },
                },
                capsule,
                error,
            },
        };
    }

    // ── One profile's downloads ─────────────────────────────────────────────────────────────────

    private DockPanel Downloads(OfflineSession open)
    {
        var layout = new OfflineLibraryLayout(model.Titles);
        var switchProfile = new Button { Content = "Switch Profile", Classes = { "chip" }, IsVisible = model.Choices.Count(c => c.Card is not null) > 1 };
        switchProfile.Click += (_, _) => model.ChooseOtherProfile();
        var bar = new DockPanel
        {
            Margin = new Thickness(32, 18, 140, 10),
            LastChildFill = false,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 10,
                    Children =
                    {
                        new ProfileAvatar(open.UserId, open.Name, 32, open.PictureKey, open.PictureRevision),
                        new StackPanel
                        {
                            VerticalAlignment = VerticalAlignment.Center,
                            Children =
                            {
                                new TextBlock { Text = open.Name, FontWeight = FontWeight.SemiBold },
                                new TextBlock { Text = "Offline · Downloads on this computer", FontSize = 12, Classes = { "subdued" } },
                            },
                        },
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Left)),
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { switchProfile, ConnectButton("chip") } }.Also(p => DockPanel.SetDock(p, Dock.Right)),
            },
        };
        var page = new StackPanel { Spacing = 30, Margin = new Thickness(0, 0, 0, 48) };
        if (layout.Featured is null)
        {
            page.Children.Add(new StackPanel
            {
                Spacing = 8,
                Margin = new Thickness(32, 80, 32, 0),
                HorizontalAlignment = HorizontalAlignment.Center,
                Children =
                {
                    new TextBlock { Text = "No Downloads", FontSize = 20, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center },
                    new TextBlock { Text = "This profile has nothing downloaded on this computer.", Classes = { "subdued" }, HorizontalAlignment = HorizontalAlignment.Center },
                },
            });
        }
        else
        {
            page.Children.Add(Hero(layout.Featured, open));
            if (layout.ContinueWatching.Count > 0) page.Children.Add(Section("Continue Watching", layout.ContinueWatching.Select(t => Card(t, open, landscape: true))));
            if (layout.Movies.Count > 0) page.Children.Add(Section("Movies", layout.Movies.Select(t => Card(t, open, landscape: false))));
            foreach (var series in layout.SeriesList) page.Children.Add(Section(series.Title, series.Episodes.Select(t => Card(t, open, landscape: true))));
        }
        var panel = new DockPanel();
        panel.Children.Add(bar.Also(b => DockPanel.SetDock(b, Dock.Top)));
        panel.Children.Add(new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = page });
        return panel;
    }

    private Grid Hero(OfflineTitle title, OfflineSession open)
    {
        var resumes = OfflineLibraryLayout.IsInProgress(title);
        var button = new Button
        {
            Classes = { "primary" },
            HorizontalAlignment = HorizontalAlignment.Left,
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                Children =
                {
                    new PathIcon { Data = Application.Current?.FindResource("IconPlay") as Geometry, Width = 14, Height = 14 },
                    new TextBlock { Text = resumes ? "Continue" : "Play", VerticalAlignment = VerticalAlignment.Center },
                },
            },
        };
        AutomationProperties.SetName(button, "Play " + title.Title);
        button.Click += (_, _) => play(title, open);
        var heading = title.Kind == MediaKind.Episode ? OfflineLibraryLayout.SeriesName(title) : title.Title;
        var detail = string.Join("  ·  ", new[]
        {
            title.Kind == MediaKind.Episode ? string.Join(" ", new[] { OfflineLibraryLayout.EpisodeLabel(title), title.Title }.Where(p => p is not null)) : null,
            title.Year?.ToString(System.Globalization.CultureInfo.InvariantCulture),
            title.Genres is { Count: > 0 } genres ? string.Join(", ", genres.Take(3)) : null,
        }.Where(part => !string.IsNullOrEmpty(part)));
        var text = new StackPanel
        {
            Spacing = 12,
            MaxWidth = 660,
            Margin = new Thickness(32, 0, 32, 40),
            VerticalAlignment = VerticalAlignment.Bottom,
            HorizontalAlignment = HorizontalAlignment.Left,
            Children =
            {
                new TextBlock { Text = resumes ? "CONTINUE WATCHING" : "DOWNLOADED", Classes = { "eyebrow" }, Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)) },
                new TextBlock { Text = heading, Classes = { "heroTitle" }, TextWrapping = TextWrapping.Wrap, Foreground = Brushes.White },
            },
        };
        if (detail.Length > 0) text.Children.Add(new TextBlock { Text = detail, FontWeight = FontWeight.SemiBold, Foreground = Brushes.White });
        if (!string.IsNullOrEmpty(title.Overview))
            text.Children.Add(new TextBlock { Text = title.Overview, TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.WordEllipsis, Foreground = new SolidColorBrush(Color.FromArgb(0xE6, 0xFF, 0xFF, 0xFF)) });
        text.Children.Add(button);
        var hero = new Grid { Height = 440 };
        if (Picture(title, title.BackdropFile ?? title.PosterFile ?? title.SeriesPosterFile, 1600) is { } backdrop)
            hero.Children.Add(new Image { Source = backdrop, Stretch = Stretch.UniformToFill });
        else
            hero.Children.Add(new Border { Background = ProfileAvatar.Gradient(("#2B3440", "#20232A")) });
        hero.Children.Add(new Border { Background = Aurelia.Linux.Library.HomePage.HeroShade(0) });
        hero.Children.Add(new Border { Background = Aurelia.Linux.Library.HomePage.HeroShade(1) });
        hero.Children.Add(text);
        return hero;
    }

    private static StackPanel Section(string title, IEnumerable<Control> cards)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, Margin = new Thickness(32, 0) };
        foreach (var card in cards) row.Children.Add(card);
        return new StackPanel
        {
            Spacing = 12,
            Children =
            {
                new TextBlock { Text = title, Classes = { "sectionTitle" }, Margin = new Thickness(32, 0) },
                new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = row },
            },
        };
    }

    private Button Card(OfflineTitle title, OfflineSession open, bool landscape)
    {
        var (width, height) = landscape ? (288.0, 162.0) : (160.0, 240.0);
        var file = landscape ? title.BackdropFile ?? title.PosterFile ?? title.SeriesPosterFile : title.PosterFile ?? title.SeriesPosterFile ?? title.BackdropFile;
        var artwork = new Grid { Width = width, Height = height };
        if (Picture(title, file, (int)width * 2) is { } image) artwork.Children.Add(new Image { Source = image, Stretch = Stretch.UniformToFill });
        else
        {
            artwork.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF)) });
            artwork.Children.Add(new PathIcon
            {
                Data = Application.Current?.FindResource(title.Kind == MediaKind.Episode ? "IconTvShows" : "IconMovies") as Geometry,
                Width = 28,
                Height = 28,
                Foreground = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)),
            });
        }
        if (title.DurationMilliseconds > 0 && OfflineLibraryLayout.IsInProgress(title))
        {
            artwork.Children.Add(new ProgressBar
            {
                Minimum = 0,
                Maximum = 1,
                Value = Math.Min(1, (double)title.PositionMilliseconds / title.DurationMilliseconds),
                Height = 4,
                MinHeight = 4,
                // White on a faint track, as on the library's cards.
                Foreground = Brushes.White,
                Background = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
                VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(10, 0, 10, 10),
            });
        }
        var subtitle = title.Kind == MediaKind.Episode
            ? OfflineLibraryLayout.EpisodeLabel(title) ?? title.Subtitle ?? ""
            : title.Year?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? title.Subtitle ?? "";
        var button = new Button
        {
            Classes = { "plain" },
            Padding = new Thickness(0),
            Width = width,
            Content = new StackPanel
            {
                Spacing = 6,
                Children =
                {
                    new Border { CornerRadius = new CornerRadius(10), ClipToBounds = true, Child = artwork },
                    new TextBlock { Text = title.Title, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis },
                    new TextBlock { Text = subtitle, FontSize = 12, Classes = { "subdued" }, TextTrimming = TextTrimming.CharacterEllipsis },
                },
            },
        };
        AutomationProperties.SetName(button, "Play " + title.Title);
        button.Click += (_, _) => play(title, open);
        return button;
    }

    /// <summary>A download's picture from this computer, decoded once for this view.</summary>
    private Bitmap? Picture(OfflineTitle title, string? name, int width)
    {
        if (name is null) return null;
        var path = Path.Combine(downloads.Folder(title.Id), name);
        var key = $"{path}@{width}";
        if (pictures.TryGetValue(key, out var known)) return known;
        Bitmap? image = null;
        try
        {
            using var file = File.OpenRead(path);
            image = Bitmap.DecodeToWidth(file, width);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or NotSupportedException)
        {
        }
        pictures[key] = image;
        return image;
    }
}
