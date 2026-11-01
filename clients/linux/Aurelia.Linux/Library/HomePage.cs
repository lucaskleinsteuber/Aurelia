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
    public const double HeroHeight = 500;

    protected override Control Build()
    {
        var store = Context.Store;
        if (store.Home is not { } home)
        {
            return store.IsLoading
                ? new ProgressBar { IsIndeterminate = true, Width = 160, Margin = Inset(140), HorizontalAlignment = HorizontalAlignment.Left }
                : EmptyState("Server Unavailable", store.Error ?? "Aurelia could not load your library.");
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
        var posterWidth = prefs.PosterWidth;
        if (home.ContinueWatching.Count > 0)
        {
            page.Children.Add(Section("Continue Watching",
                Shelf("Continue Watching", home.ContinueWatching.Select(item => MediaCards.Landscape(Context, item, 320, "CONTINUE WATCHING", plays: true))),
                home.ContinueWatching.Count));
        }
        foreach (var row in LibraryPresentation.GenreRows(Visible(store.Catalog.Where(item => item.Kind is MediaKind.Movie or MediaKind.Series))))
        {
            page.Children.Add(Section(row.Title, Shelf(row.Title, row.Items.Select(item => MediaCards.Poster(Context, item, posterWidth))), row.Items.Count));
        }
        var favorites = Visible(home.Favorites);
        if (favorites.Count > 0)
            page.Children.Add(Section("Favorites", Shelf("Favorites", favorites.Select(item => MediaCards.Poster(Context, item, posterWidth))), favorites.Count));
        if (home.Collections.Count > 0)
            page.Children.Add(Section("Collections", Shelf("Collections", home.Collections.Select(c => MediaCards.Collection(Context, c))), home.Collections.Count));
        var recent = Visible(home.RecentlyAdded);
        if (recent.Count > 0)
            page.Children.Add(Section("Recently Added", Shelf("Recently Added", recent.Select(item => MediaCards.Poster(Context, item, posterWidth))), recent.Count));
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
