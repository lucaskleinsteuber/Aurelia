using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Library;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Library;

/// <summary>
/// Home, as on the Mac: the full-bleed hero (the server's recommendation) beneath the sidebar, then
/// Continue Watching (which resumes), three genre rows, Favorites, Collections and Recently Added.
/// </summary>
public sealed class HomePage(LibraryContext context) : LibraryPageBase(context)
{
    /// <summary>Start a Movie Night, or join the one someone else started.</summary>
    private Button MovieNightStrip()
    {
        var title = new TextBlock { Text = "Can't decide what to watch?", FontWeight = FontWeight.SemiBold, FontSize = 15 };
        var detail = new TextBlock { Text = "Start a Movie Night and let everyone swipe on their phone.", Classes = { "subdued" }, FontSize = 13 };
        MovieNightSummary? open = null;
        var cards = new Canvas { Width = 46, Height = 40, Margin = new Thickness(0, 0, 14, 0) };
        foreach (var (color, left, angle) in new[] { ("#FF4D5A", 0.0, -12.0), ("#3A3F44", 10.0, 0.0), ("#FFC93C", 20.0, 12.0) })
        {
            var card = new Border { Width = 22, Height = 32, CornerRadius = new CornerRadius(5), Background = new SolidColorBrush(Color.Parse(color)), RenderTransform = new RotateTransform(angle) };
            Canvas.SetLeft(card, left);
            Canvas.SetTop(card, 4);
            cards.Children.Add(card);
        }
        var strip = new Button
        {
            Classes = { "card" },
            Margin = Inset(),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = new Border
            {
                Background = new SolidColorBrush(Color.Parse("#282C2F")),
                CornerRadius = new CornerRadius(14),
                Padding = new Thickness(14),
                Child = new StackPanel { Orientation = Orientation.Horizontal, Children = { cards, new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center, Children = { title, detail } } } },
            },
        };
        Avalonia.Automation.AutomationProperties.SetName(strip, "Movie Night");
        strip.Click += (_, _) => _ = Context.Navigator.ShowMovieNightAsync(open);
        _ = Task.Run(async () =>
        {
            try { return await Context.Store.Client.MovieNightsAsync(CancellationToken.None); }
            catch (Exception failure) when (failure is Aurelia.Linux.Core.Api.AureliaApiException or HttpRequestException or TaskCanceledException) { return []; }
        }).ContinueWith(task => Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            if (task.Result is not { Count: > 0 } nights) return;
            var night = nights[0];
            open = night;
            title.Text = $"{night.HostName}'s Movie Night is on";
            detail.Text = "Join and start swiping.";
        }), TaskScheduler.Default);
        return strip;
    }

    public const double HeroHeight = 500;

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        Context.Store.PropertyChanged += OnStorePropertyChanged;
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        Context.Store.PropertyChanged -= OnStorePropertyChanged;
        base.OnDetachedFromVisualTree(e);
    }

    // A failed first load only sets IsLoading and Error and raises no Changed, so without this the
    // spinner stayed after the request had long given up.
    private void OnStorePropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (Context.Store.Home is null && e.PropertyName is nameof(LibraryStore.IsLoading) or nameof(LibraryStore.Error)) Rebuild();
    }

    protected override Control Build()
    {
        var store = Context.Store;
        if (store.Home is not { } home)
        {
            if (store.IsLoading) return new Aurelia.Linux.Controls.Spinner { Margin = Inset(160), HorizontalAlignment = HorizontalAlignment.Center };
            var retry = new Button { Content = "Try Again", Classes = { "primary" } };
            retry.Click += (_, _) => _ = store.RefreshAsync();
            return EmptyState("Server Unavailable", store.Error ?? "Aurelia could not load your library.", retry);
        }
        var prefs = store.Preferences;
        IReadOnlyList<CatalogItemSummary> Visible(IEnumerable<CatalogItemSummary> items) =>
            LibraryPresentation.Visible(items, keepWatched: false, prefs.ShowWatchedInRows, prefs.HideOfflineTitles);
        var page = new StackPanel { Spacing = 30, Margin = new Thickness(0, 0, 0, 48) };
        var hasContent = home.Recommendation is not null || home.ContinueWatching.Count > 0 || store.Catalog.Count > 0;
        if (!hasContent)
        {
            page.Children.Add(EmptyState("Your Library Is Ready",
                store.CanManageMedia ? "Add a folder with movies or TV shows on the server to fill it." : "Titles appear here once the server's owner adds media."));
            return page;
        }
        if (home.Recommendation is { } hero) page.Children.Add(Hero(hero));
        else page.Children.Add(new Panel { Height = 64 });
        if (store.Client.SupportsMovieNight) page.Children.Add(MovieNightStrip());
        var posterWidth = prefs.PosterWidth;
        if (home.ContinueWatching.Count > 0)
        {
            page.Children.Add(Section("Continue Watching",
                Shelf("Continue Watching", home.ContinueWatching, item => MediaCards.Landscape(Context, item, 320, "CONTINUE WATCHING", plays: true)),
                home.ContinueWatching.Count));
        }
        foreach (var row in LibraryPresentation.GenreRows(Visible(store.Catalog.Where(item => item.Kind is MediaKind.Movie or MediaKind.Series))))
        {
            page.Children.Add(Section(row.Title, Shelf(row.Title, row.Items, item => MediaCards.Poster(Context, item, posterWidth)), row.Items.Count));
        }
        var favorites = Visible(home.Favorites);
        if (favorites.Count > 0)
            page.Children.Add(Section("Favorites", Shelf("Favorites", favorites, item => MediaCards.Poster(Context, item, posterWidth)), favorites.Count));
        if (home.Collections.Count > 0)
            page.Children.Add(Section("Collections", Shelf("Collections", home.Collections, c => MediaCards.Collection(Context, c)), home.Collections.Count));
        var recent = Visible(home.RecentlyAdded);
        if (recent.Count > 0)
            page.Children.Add(Section("Recently Added", Shelf("Recently Added", recent, item => MediaCards.Poster(Context, item, posterWidth)), recent.Count));
        return page;
    }

    private Grid Hero(CatalogItemSummary item)
    {
        var resumes = LibraryPresentation.ProgressFraction(item) is not null;
        var open = new Button
        {
            Classes = { "primary" },
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                Children =
                {
                    new PathIcon { Data = Application.Current?.FindResource(resumes ? "IconPlay" : "IconArrowRight") as Geometry, Width = 14, Height = 14 },
                    new TextBlock { Text = resumes ? "Continue" : "Open", VerticalAlignment = VerticalAlignment.Center },
                },
            },
        };
        open.Click += (_, _) => Context.OpenDetail(item);
        var text = new StackPanel
        {
            Spacing = 12,
            MaxWidth = 660,
            Margin = new Thickness(Leading, 0, PagePadding, 48),
            VerticalAlignment = VerticalAlignment.Bottom,
            HorizontalAlignment = HorizontalAlignment.Left,
            Children =
            {
                new TextBlock { Text = LibraryPresentation.Eyebrow(item), Classes = { "eyebrow" }, Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)) },
                new TextBlock { Text = item.Title, Classes = { "heroTitle" }, TextWrapping = TextWrapping.Wrap, Foreground = Brushes.White },
                new TextBlock { Text = string.Join("  ·  ", item.Genres.Take(3)), FontWeight = FontWeight.SemiBold, Foreground = Brushes.White },
                new TextBlock { Text = item.Overview ?? "", TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.WordEllipsis, Foreground = new SolidColorBrush(Color.FromArgb(0xE6, 0xFF, 0xFF, 0xFF)), LineHeight = 21 },
                open,
            },
        };
        return new Grid
        {
            Height = HeroHeight,
            Children =
            {
                new ArtworkImage(Context.Store, LibraryPresentation.LandscapeArtwork(item), 1920),
                new Border { Background = HeroShade(0) },
                new Border { Background = HeroShade(1) },
                text,
            },
        };
    }

    /// <summary>Two shades keep the text legible: one from the left, one fading into the canvas below.</summary>
    internal static LinearGradientBrush HeroShade(int which) => which == 0
        ? new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0.5, RelativeUnit.Relative),
            EndPoint = new RelativePoint(0.75, 0.5, RelativeUnit.Relative),
            GradientStops = { new GradientStop(Color.FromArgb(0xB3, 0x10, 0x12, 0x15), 0), new GradientStop(Color.FromArgb(0, 0x10, 0x12, 0x15), 1) },
        }
        : new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0.5, 0.45, RelativeUnit.Relative),
            EndPoint = new RelativePoint(0.5, 1, RelativeUnit.Relative),
            GradientStops = { new GradientStop(Color.FromArgb(0, 32, 35, 38), 0), new GradientStop(Color.FromArgb(255, 32, 35, 38), 1) },
        };
}
