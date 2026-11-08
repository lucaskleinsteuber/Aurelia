using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Library;

/// <summary>
/// A horizontal shelf of cards, like the Mac app's rail: it scrolls sideways, shows paging arrows
/// while the pointer is over it or it has keyboard focus, and pages by whole cards. The arrow keys
/// page too.
/// </summary>
public sealed class Rail : Panel
{
    private readonly ScrollViewer scroller;
    private const double Spacing = 20;
    private readonly Panel row;
    private readonly Button previous;
    private readonly Button next;

    /// <summary>A rail of <paramref name="count"/> cards; beyond <see cref="LazyCards.Threshold"/> only those near the view are made.</summary>
    public Rail(string title, int count, Func<int, Control> card, double leadingInset)
    {
        if (count > LazyCards.Threshold) row = new LazyCards(count, card, wrap: false, Spacing);
        else
        {
            var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Spacing };
            for (var index = 0; index < count; index++) stack.Children.Add(card(index));
            row = stack;
        }
        Count = count;
        row.Margin = new Thickness(leadingInset, 6, 32, 10);
        scroller = new ScrollViewer
        {
            Content = row,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        AutomationProperties.SetName(this, title);
        previous = Arrow("IconChevronLeft", $"Previous {title}", HorizontalAlignment.Left, leadingInset - 34);
        next = Arrow("IconChevronRight", $"Next {title}", HorizontalAlignment.Right, 6);
        previous.Click += (_, _) => Page(forward: false);
        next.Click += (_, _) => Page(forward: true);
        Children.Add(scroller);
        Children.Add(previous);
        Children.Add(next);
        PointerEntered += (_, _) => UpdateArrows(visible: true);
        PointerExited += (_, _) => UpdateArrows(visible: IsKeyboardFocusWithin);
        scroller.ScrollChanged += (_, _) => UpdateArrows(visible: IsPointerOver || IsKeyboardFocusWithin);
        KeyDown += (_, e) =>
        {
            if (e.Key is Key.Left or Key.Right && e.KeyModifiers == KeyModifiers.None)
            {
                Page(forward: e.Key == Key.Right);
                e.Handled = true;
            }
        };
        UpdateArrows(visible: false);
    }

    public int Count { get; }

    public double Offset => scroller.Offset.X;

    /// <summary>Scrolls by the visible width, rounded down to whole cards.</summary>
    public void Page(bool forward)
    {
        var card = row is LazyCards lazy ? lazy.ItemSize.Width : row.Children.FirstOrDefault()?.Bounds.Width ?? 200;
        if (card <= 0) card = 200;
        var step = card + Spacing;
        var visible = Math.Max(step, scroller.Viewport.Width - 64);
        var cards = Math.Max(1, Math.Floor(visible / step));
        var target = scroller.Offset.X + (forward ? cards * step : -cards * step);
        var maximum = Math.Max(0, scroller.Extent.Width - scroller.Viewport.Width);
        scroller.Offset = new Vector(Math.Clamp(target, 0, maximum), 0);
    }

    private void UpdateArrows(bool visible)
    {
        var maximum = Math.Max(0, scroller.Extent.Width - scroller.Viewport.Width);
        previous.IsVisible = visible && scroller.Offset.X > 1;
        next.IsVisible = visible && scroller.Offset.X < maximum - 1;
    }

    private static Button Arrow(string icon, string label, HorizontalAlignment side, double inset)
    {
        var arrow = new Button
        {
            Classes = { "railArrow" },
            HorizontalAlignment = side,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = side == HorizontalAlignment.Left ? new Thickness(Math.Max(4, inset), 0, 0, 0) : new Thickness(0, 0, inset, 0),
            Content = new PathIcon { Data = Application.Current?.FindResource(icon) as Geometry, Width = 14, Height = 14 },
        };
        AutomationProperties.SetName(arrow, label);
        return arrow;
    }
}
