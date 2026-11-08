using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Controls;

/// <summary>One stop of the library tour: the control to light up (none: a centered note), a title and one sentence.</summary>
public sealed record TourStop(Func<Control?> Target, string Title, string Text);

/// <summary>
/// The library tour after setup: the window dims, one place stays lit with a short note beside it. Clicking the
/// lit place itself, or Next, moves on; Skip Tour ends it. Clicks pass through the lit place to the app.
/// </summary>
public sealed class SpotlightTour : Panel
{
    private const double Gap = 8;
    private readonly IReadOnlyList<TourStop> stops;
    private readonly Action finished;
    private readonly Avalonia.Controls.Shapes.Path dim = new() { Fill = new SolidColorBrush(Color.FromArgb(0xB8, 0x05, 0x06, 0x08)) };
    private readonly Border ring = new()
    {
        BorderBrush = new SolidColorBrush(Color.FromArgb(0xE6, 0xFF, 0xFF, 0xFF)),
        BorderThickness = new Thickness(2),
        CornerRadius = new CornerRadius(12),
        IsHitTestVisible = false,
    };
    private readonly Canvas layer = new();
    private readonly Border bubble = new()
    {
        Width = 320,
        Padding = new Thickness(18, 16),
        CornerRadius = new CornerRadius(14),
        Background = new SolidColorBrush(Color.FromArgb(0xF5, 0x24, 0x27, 0x2C)),
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)),
        BorderThickness = new Thickness(1),
        BoxShadow = new BoxShadows(new BoxShadow { Blur = 30, OffsetY = 10, Color = Color.FromArgb(0x80, 0, 0, 0) }),
    };
    private readonly TextBlock title = new() { FontSize = 16, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock text = new() { Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock counter = new() { Classes = { "subdued" }, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button next = new() { Content = "Next", Classes = { "primary" } };
    private Control? target;
    private int index = -1;

    public SpotlightTour(IReadOnlyList<TourStop> stops, Action finished)
    {
        this.stops = stops;
        this.finished = finished;
        AutomationProperties.SetName(this, "Library Tour");
        var skip = new Button { Content = "Skip Tour", Classes = { "link" } };
        skip.Click += (_, _) => End();
        next.Click += (_, _) => Advance();
        AutomationProperties.SetName(next, "Next Tour Step");
        bubble.Child = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                title,
                text,
                new DockPanel
                {
                    Margin = new Thickness(0, 6, 0, 0),
                    Children =
                    {
                        new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { skip, next } }.Also(p => DockPanel.SetDock(p, Dock.Right)),
                        counter,
                    },
                },
            },
        };
        layer.Children.Add(bubble);
        Children.Add(dim);
        Children.Add(ring);
        Children.Add(layer);
        SizeChanged += (_, _) => Place();
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) End();
            else if (e.Key is Key.Enter or Key.Right) Advance();
            else return;
            e.Handled = true;
        };
        Focusable = true;
        AttachedToVisualTree += (_, _) =>
        {
            Advance();
            Focus();
        };
    }

    public int Index => index;

    public TourStop? Current => index >= 0 && index < stops.Count ? stops[index] : null;

    public void Advance()
    {
        if (target is not null) target.RemoveHandler(PointerReleasedEvent, OnTargetUsed);
        index++;
        if (index >= stops.Count)
        {
            End();
            return;
        }
        var stop = stops[index];
        target = stop.Target();
        title.Text = stop.Title;
        text.Text = stop.Text;
        counter.Text = $"{index + 1} of {stops.Count}";
        next.Content = index == stops.Count - 1 ? "Done" : "Next";
        // Using the lit place counts as "Next", after the app handled the click.
        target?.AddHandler(PointerReleasedEvent, OnTargetUsed, RoutingStrategies.Bubble, handledEventsToo: true);
        Place();
        Motion.Appear(bubble, rise: 8, fromScale: 0.98);
    }

    public void End()
    {
        if (target is not null) target.RemoveHandler(PointerReleasedEvent, OnTargetUsed);
        target = null;
        if (Parent is Panel panel) panel.Children.Remove(this);
        finished();
    }

    private void OnTargetUsed(object? sender, PointerReleasedEventArgs e) =>
        Avalonia.Threading.Dispatcher.UIThread.Post(Advance, Avalonia.Threading.DispatcherPriority.Background);

    /// <summary>Cuts the lit place out of the dimming and puts the note beside it, inside the window.</summary>
    private void Place()
    {
        var size = Bounds.Size;
        if (size.Width <= 0) return;
        var whole = new RectangleGeometry(new Rect(size));
        Rect? lit = null;
        if (target is { IsEffectivelyVisible: true } shown && shown.TranslatePoint(new Point(0, 0), this) is { } origin)
            lit = new Rect(origin, shown.Bounds.Size).Inflate(Gap).Intersect(new Rect(size));
        if (lit is { Width: > 0, Height: > 0 } hole)
        {
            dim.Data = new GeometryGroup { FillRule = FillRule.EvenOdd, Children = { whole, new RectangleGeometry(hole, 12, 12) } };
            ring.IsVisible = true;
            ring.Margin = new Thickness(hole.X, hole.Y, 0, 0);
            ring.Width = hole.Width;
            ring.Height = hole.Height;
            ring.HorizontalAlignment = HorizontalAlignment.Left;
            ring.VerticalAlignment = VerticalAlignment.Top;
            var bubbleHeight = Math.Max(bubble.DesiredSize.Height, 150);
            double x, y;
            if (hole.Right + 16 + bubble.Width <= size.Width)
            {
                x = hole.Right + 16;
                y = hole.Y;
            }
            else if (hole.Bottom + 16 + bubbleHeight <= size.Height)
            {
                x = hole.X;
                y = hole.Bottom + 16;
            }
            else
            {
                x = hole.X - 16 - bubble.Width;
                y = hole.Y;
            }
            Canvas.SetLeft(bubble, Math.Clamp(x, 16, Math.Max(16, size.Width - bubble.Width - 16)));
            Canvas.SetTop(bubble, Math.Clamp(y, 16, Math.Max(16, size.Height - bubbleHeight - 16)));
        }
        else
        {
            dim.Data = whole;
            ring.IsVisible = false;
            Canvas.SetLeft(bubble, (size.Width - bubble.Width) / 2);
            Canvas.SetTop(bubble, Math.Max(16, (size.Height - 180) / 2));
        }
    }
}
