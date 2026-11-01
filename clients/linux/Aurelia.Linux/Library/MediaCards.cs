using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Library;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Library;

/// <summary>The cards shown on shelves and grids, sized and labeled like the Mac app's.</summary>
internal static class MediaCards
{
    /// <summary>A poster (2:3) with its title and year below; badges for favorite, watched and offline.</summary>
    public static Button Poster(LibraryContext context, CatalogItemSummary item, double width)
    {
        var picture = new Grid
        {
            Width = width,
            Height = width * 1.5,
            Children =
            {
                Rounded(new ArtworkImage(context.Store, item.Poster ?? item.Backdrop, width), 12),
                Badges(item),
                ProgressBar(item, 10),
            },
        };
        var caption = new StackPanel
        {
            Spacing = 2,
            Width = width,
            Children =
            {
                new TextBlock { Text = item.Title, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis },
                new TextBlock { Text = Subtitle(item), Classes = { "subdued" }, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis },
            },
        };
        var card = Card(new StackPanel { Spacing = 8, Children = { picture, caption } }, item.Title);
        card.Click += (_, _) => context.OpenDetail(item);
        card.ContextMenu = MediaMenu.For(context, item);
        return card;
    }

    /// <summary>A landscape card (16:9) with the title over the picture: Continue Watching, episodes, extras.</summary>
    public static Button Landscape(LibraryContext context, CatalogItemSummary item, double width, string? eyebrow = null, bool plays = false)
    {
        var height = width * 9 / 16;
        var text = new StackPanel
        {
            Spacing = 2,
            Margin = new Thickness(16, 0, 16, 18),
            VerticalAlignment = VerticalAlignment.Bottom,
            Children =
            {
                new TextBlock { Text = eyebrow ?? LibraryPresentation.Eyebrow(item), Classes = { "eyebrow" }, Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)), FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis },
                new TextBlock { Text = item.Title, FontSize = 15, FontWeight = FontWeight.Bold, Foreground = Brushes.White, TextTrimming = TextTrimming.CharacterEllipsis },
                new TextBlock { Text = Subtitle(item), FontSize = 12, Foreground = new SolidColorBrush(Color.FromArgb(0xB3, 0xFF, 0xFF, 0xFF)) },
            },
        };
        var picture = new Grid
        {
            Width = width,
            Height = height,
            Children =
            {
                Rounded(new ArtworkImage(context.Store, LibraryPresentation.LandscapeArtwork(item), width), 18),
                Rounded(new Border { Background = BottomShade() }, 18),
                text,
                Badges(item),
                ProgressBar(item, 12),
            },
        };
        var card = Card(picture, item.Title);
        card.Click += (_, _) =>
        {
            if (plays && LibraryPresentation.IsPlayable(item)) context.Play(item, resume: true);
            else context.OpenDetail(item);
        };
        card.ContextMenu = MediaMenu.For(context, item);
        return card;
    }

    /// <summary>A collection (210 × 280) with its poster, name, size and a "Smart" badge for smart lists.</summary>
    public static Button Collection(LibraryContext context, CollectionSummary collection, double width = 210)
    {
        var poster = collection.Poster ?? (collection.Items.Count > 0 ? collection.Items[0].Poster : null);
        var picture = new Grid
        {
            Width = width,
            Height = width * 4 / 3,
            Children = { Rounded(new ArtworkImage(context.Store, poster, width), 18) },
        };
        if (collection.IsSmart)
        {
            picture.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0xB3, 0x14, 0x16, 0x1A)),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(8, 3),
                Margin = new Thickness(10),
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Child = new TextBlock { Text = "Smart", FontSize = 11, FontWeight = FontWeight.SemiBold, Foreground = Brushes.White },
            });
        }
        var count = collection.TotalCount > 0 ? collection.TotalCount : collection.Items.Count;
        var card = Card(new StackPanel
        {
            Spacing = 8,
            Children =
            {
                picture,
                new TextBlock { Text = collection.Name, Width = width, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis },
                new TextBlock { Text = count == 1 ? "1 title" : $"{count} titles", Classes = { "subdued" }, FontSize = 12 },
            },
        }, collection.Name);
        card.Click += (_, _) => context.OpenCollection(collection);
        return card;
    }

    /// <summary>A person from the cast or crew: a round photo with name and role.</summary>
    public static Button Person(LibraryContext context, CreditSummary credit, string role)
    {
        var photo = new Border
        {
            Width = 112,
            Height = 112,
            CornerRadius = new CornerRadius(56),
            ClipToBounds = true,
            Child = credit.Profile is not null
                ? new ArtworkImage(context.Store, credit.Profile, 112)
                : new ProfileAvatar(null, credit.Name, 112),
        };
        var card = Card(new StackPanel
        {
            Spacing = 6,
            Width = 120,
            Children =
            {
                photo.Also(p => p.HorizontalAlignment = HorizontalAlignment.Center),
                new TextBlock { Text = credit.Name, FontWeight = FontWeight.SemiBold, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxLines = 2 },
                new TextBlock { Text = role, Classes = { "subdued" }, FontSize = 12, TextAlignment = TextAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis },
            },
        }, credit.Name);
        card.Click += (_, _) => context.OpenPerson(credit.Name, credit.PersonKey);
        return card;
    }

    public static string Subtitle(CatalogItemSummary item)
    {
        if (item.Availability != MediaAvailability.Available && item.Kind != MediaKind.Series) return "Offline";
        return item.Year?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "";
    }

    private static Button Card(Control content, string name)
    {
        var button = new Button { Classes = { "card" }, Content = content };
        AutomationProperties.SetName(button, name);
        return button;
    }

    private static Border Rounded(Control child, double radius) => new() { CornerRadius = new CornerRadius(radius), ClipToBounds = true, Child = child };

    private static LinearGradientBrush BottomShade() => new()
    {
        StartPoint = new RelativePoint(0.5, 0.35, RelativeUnit.Relative),
        EndPoint = new RelativePoint(0.5, 1, RelativeUnit.Relative),
        GradientStops = { new GradientStop(Color.FromArgb(0, 0, 0, 0), 0), new GradientStop(Color.FromArgb(0xD9, 0, 0, 0), 1) },
    };

    private static StackPanel Badges(CatalogItemSummary item)
    {
        var badges = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(10), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
        if (item.IsFavorite) badges.Children.Add(Badge("IconFavorite", "Favorite"));
        if (item.WatchState == CatalogWatchState.Completed) badges.Children.Add(Badge("IconCheck", "Watched"));
        if (item.Availability != MediaAvailability.Available && item.Kind != MediaKind.Series) badges.Children.Add(Badge("IconOffline", "Offline"));
        return badges;
    }

    private static Border Badge(string icon, string label)
    {
        var badge = new Border
        {
            Width = 26,
            Height = 26,
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Color.FromArgb(0xB8, 0x14, 0x16, 0x1A)),
            Child = new PathIcon { Data = Application.Current?.FindResource(icon) as Geometry, Width = 13, Height = 13, Foreground = Brushes.White },
        };
        AutomationProperties.SetName(badge, label);
        return badge;
    }

    private static Control ProgressBar(CatalogItemSummary item, double inset)
    {
        if (LibraryPresentation.ProgressFraction(item) is not { } fraction) return new Panel();
        return new Grid
        {
            Height = 4,
            Margin = new Thickness(inset, 0, inset, inset),
            VerticalAlignment = VerticalAlignment.Bottom,
            ColumnDefinitions = new ColumnDefinitions($"{fraction.ToString(System.Globalization.CultureInfo.InvariantCulture)}*,{(1 - fraction).ToString(System.Globalization.CultureInfo.InvariantCulture)}*"),
            Children =
            {
                new Rectangle { Fill = Brushes.White, RadiusX = 2, RadiusY = 2 }.Also(r => Grid.SetColumn(r, 0)),
                new Rectangle { Fill = new SolidColorBrush(Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF)), RadiusX = 2, RadiusY = 2 }.Also(r => Grid.SetColumn(r, 1)),
            },
        };
    }
}
