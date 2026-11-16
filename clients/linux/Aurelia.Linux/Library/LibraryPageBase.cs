using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Library;

/// <summary>
/// A library page: it scrolls vertically, runs full height beneath the sidebar and starts its
/// content beside it. Pages rebuild their content when the library changes.
/// </summary>
public abstract class LibraryPageBase : UserControl
{
    public static readonly StyledProperty<double> SidebarOverlapProperty =
        AvaloniaProperty.Register<LibraryPageBase, double>(nameof(SidebarOverlap));

    protected const double PagePadding = 32;
    private readonly ScrollViewer scroller = new()
    {
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };

    /// <summary>The library's revision this page was last built from.</summary>
    private long builtRevision = -1;

    protected LibraryPageBase(LibraryContext context)
    {
        Context = context;
        Content = scroller;
        AttachedToVisualTree += (_, _) =>
        {
            context.Store.Changed += OnStoreChanged;
            // A page hears about changes only while it is shown. One built before its data arrived
            // (Home right after the PIN, while the window still showed the profiles) or left while
            // the library changed would otherwise keep showing a spinner or old rows.
            if (IsStale) Rebuild();
        };
        DetachedFromVisualTree += (_, _) => context.Store.Changed -= OnStoreChanged;
    }

    /// <summary>Whether the library changed since this page was built.</summary>
    protected virtual bool IsStale => builtRevision != -1 && builtRevision != Context.Store.Revision;

    public LibraryContext Context { get; }

    /// <summary>How far the sidebar reaches over the page; content starts beside it.</summary>
    public double SidebarOverlap
    {
        get => GetValue(SidebarOverlapProperty);
        set => SetValue(SidebarOverlapProperty, value);
    }

    /// <summary>Left edge of the content.</summary>
    protected double Leading => SidebarOverlap + PagePadding;

    protected Thickness Inset(double top = 0, double bottom = 0) => new(Leading, top, PagePadding, bottom);

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == SidebarOverlapProperty) Rebuild();
    }

    /// <summary>Builds the page content again from the current data.</summary>
    public void Rebuild()
    {
        var offset = scroller.Offset;
        builtRevision = Context.Store.Revision;
        scroller.Content = Build();
        scroller.Offset = offset;
    }

    protected abstract Control Build();

    protected virtual void OnStoreChanged() => Rebuild();

    protected static TextBlock PageTitle(string text) => new() { Text = text, Classes = { "pageTitle" } };

    protected static TextBlock SectionTitle(string text) => new() { Text = text, Classes = { "sectionTitle" } };

    protected StackPanel Section(string title, Control content, int? count = null) => new()
    {
        Spacing = 10,
        Children =
        {
            new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                Margin = Inset(),
                Children =
                {
                    SectionTitle(title),
                    new TextBlock { Text = count?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "", Classes = { "subdued" }, FontSize = 12, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 3) },
                },
            },
            content,
        },
    };

    /// <summary>
    /// A calm message in place of content: empty, unavailable or not found. Every page shows it the
    /// same way, centered with a symbol, as Downloads and the Mac do; pages showed it as loose
    /// left-aligned text before (audit Linux D3).
    /// </summary>
    protected Control EmptyState(string title, string detail, Control? action = null, string? icon = null)
    {
        var panel = new StackPanel
        {
            Spacing = 10,
            Margin = Inset(72),
            HorizontalAlignment = HorizontalAlignment.Center,
            MaxWidth = 460,
            Children =
            {
                new Border
                {
                    Width = 64,
                    Height = 64,
                    CornerRadius = new CornerRadius(32),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Margin = new Thickness(0, 0, 0, 4),
                    Background = new SolidColorBrush(Color.FromArgb(0x1F, 0x0A, 0x84, 0xFF)),
                    Child = new PathIcon
                    {
                        Data = Application.Current?.FindResource(icon ?? EmptyIcon(title)) as Geometry,
                        Width = 28,
                        Height = 28,
                        Foreground = Application.Current?.FindResource("AureliaAccentBrush") as IBrush,
                    },
                },
                new TextBlock { Text = title, FontSize = 20, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = detail, Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center },
            },
        };
        if (action is not null)
        {
            action.Margin = new Thickness(0, 10, 0, 0);
            action.HorizontalAlignment = HorizontalAlignment.Center;
            panel.Children.Add(action);
        }
        return panel;
    }

    /// <summary>The symbol of an empty state, from what is missing.</summary>
    internal static string EmptyIcon(string title) => title switch
    {
        _ when title.Contains("Watchlist", StringComparison.Ordinal) => "IconWatchlist",
        _ when title.Contains("Collection", StringComparison.Ordinal) => "IconCollections",
        _ when title.Contains("People", StringComparison.Ordinal) || title.Contains("No One", StringComparison.Ordinal) => "IconPeople",
        _ when title.Contains("Wish", StringComparison.Ordinal) => "IconWishes",
        _ when title.Contains("Activity", StringComparison.Ordinal) => "IconHistory",
        _ when title.Contains("Results", StringComparison.Ordinal) => "IconSearch",
        _ when title.Contains("Unavailable", StringComparison.Ordinal) || title.Contains("Not Found", StringComparison.Ordinal) || title.StartsWith("Couldn", StringComparison.Ordinal) => "IconOffline",
        _ => "IconLibrary",
    };

    /// <summary>A wrapping grid of cards, as the Mac's adaptive poster grid.</summary>
    /// <summary>A wrapping grid of cards; a long one makes only the cards near the view (see <see cref="LazyCards"/>).</summary>
    protected Panel Grid<T>(IReadOnlyList<T> items, Func<T, Control> card) => items.Count > LazyCards.Threshold
        ? new LazyCards(items.Count, index => card(items[index]), wrap: true, spacing: 22, lineSpacing: 26) { Margin = Inset() }
        : new WrapPanel
        {
            Margin = Inset(),
            ItemSpacing = 22,
            LineSpacing = 26,
        }.Also(panel =>
        {
            foreach (var each in items) panel.Children.Add(card(each));
        });

    // Each rail's sideways position by title, so a rebuild after a library change keeps where you were.
    private readonly Dictionary<string, double> railOffsets = [];

    protected Rail Shelf<T>(string title, IReadOnlyList<T> items, Func<T, Control> card) =>
        new(title, items.Count, index => card(items[index]), Leading, railOffsets.GetValueOrDefault(title), offset => railOffsets[title] = offset);
}
