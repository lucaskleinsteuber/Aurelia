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

    protected LibraryPageBase(LibraryContext context)
    {
        Context = context;
        Content = scroller;
        AttachedToVisualTree += (_, _) => context.Store.Changed += OnStoreChanged;
        DetachedFromVisualTree += (_, _) => context.Store.Changed -= OnStoreChanged;
    }

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

    /// <summary>A calm message in place of content: empty, unavailable or not found.</summary>
    protected Control EmptyState(string title, string detail, Control? action = null)
    {
        var panel = new StackPanel
        {
            Spacing = 8,
            Margin = Inset(80),
            HorizontalAlignment = HorizontalAlignment.Left,
            MaxWidth = 560,
            Children =
            {
                new TextBlock { Text = title, FontSize = 20, FontWeight = FontWeight.SemiBold },
                new TextBlock { Text = detail, Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap },
            },
        };
        if (action is not null)
        {
            action.Margin = new Thickness(0, 10, 0, 0);
            action.HorizontalAlignment = HorizontalAlignment.Left;
            panel.Children.Add(action);
        }
        return panel;
    }

    /// <summary>A wrapping grid of cards, as the Mac's adaptive poster grid.</summary>
    protected WrapPanel Grid(IEnumerable<Control> cards) => new WrapPanel
    {
        Margin = Inset(),
        ItemSpacing = 22,
        LineSpacing = 26,
    }.Also(panel =>
    {
        foreach (var card in cards) panel.Children.Add(card);
    });

    protected Rail Shelf(string title, IEnumerable<Control> cards) => new(title, cards, Leading);
}
