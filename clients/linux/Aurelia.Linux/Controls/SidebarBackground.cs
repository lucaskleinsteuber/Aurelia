using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Media;

namespace Aurelia.Linux.Controls;

/// <summary>
/// A dark, blurred panel like the Apple TV app's sidebar: hero artwork and shelves that pass beneath
/// it stay softly visible while its labels stay legible. With <see cref="ReduceTransparency"/> it is
/// the opaque canvas.
/// </summary>
public sealed class SidebarBackground : Panel
{
    public static readonly StyledProperty<Visual?> SourceProperty =
        AvaloniaProperty.Register<SidebarBackground, Visual?>(nameof(Source));

    public static readonly StyledProperty<bool> ReduceTransparencyProperty =
        AvaloniaProperty.Register<SidebarBackground, bool>(nameof(ReduceTransparency));

    /// <summary>Canvas tint over the blur; keeps labels legible above bright artwork.</summary>
    public const double Tint = 0.66;

    public const double BlurRadius = 48;

    private readonly Rectangle blurred = new() { IsHitTestVisible = false };
    private readonly Rectangle tint = new() { IsHitTestVisible = false };
    private readonly Rectangle topShade = new() { IsHitTestVisible = false };

    public SidebarBackground()
    {
        ClipToBounds = true;
        IsHitTestVisible = false;
        // The blurred copy reaches past the right edge so the blur does not fade out at the border.
        blurred.Margin = new Thickness(0, 0, -BlurRadius * 2, 0);
        blurred.Effect = new BlurEffect { Radius = BlurRadius };
        Children.Add(blurred);
        Children.Add(tint);
        Children.Add(topShade);
        Update();
    }

    /// <summary>The page layer whose pixels sit beneath the sidebar; it must share the sidebar's top-left corner.</summary>
    public Visual? Source
    {
        get => GetValue(SourceProperty);
        set => SetValue(SourceProperty, value);
    }

    public bool ReduceTransparency
    {
        get => GetValue(ReduceTransparencyProperty);
        set => SetValue(ReduceTransparencyProperty, value);
    }

    /// <summary>True while the content beneath is drawn blurred (for tests and diagnostics).</summary>
    public bool ShowsBlur => blurred.IsVisible && blurred.Fill is VisualBrush;

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == SourceProperty || change.Property == ReduceTransparencyProperty) Update();
    }

    private void Update()
    {
        var canvas = Application.Current?.FindResource("AureliaCanvasColor") is Color color ? color : Color.FromRgb(32, 35, 38);
        if (ReduceTransparency || Source is null)
        {
            blurred.IsVisible = false;
            blurred.Fill = null;
            tint.Fill = new SolidColorBrush(canvas);
            topShade.Fill = null;
            return;
        }
        blurred.IsVisible = true;
        blurred.Fill = new VisualBrush(Source)
        {
            Stretch = Stretch.None,
            AlignmentX = AlignmentX.Left,
            AlignmentY = AlignmentY.Top,
            TileMode = TileMode.None,
        };
        tint.Fill = new SolidColorBrush(canvas, Tint);
        // Bright hero artwork sits at the top, so the tint deepens there.
        topShade.Fill = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0.5, 0, RelativeUnit.Relative),
            EndPoint = new RelativePoint(0.5, 1, RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(Color.FromArgb(128, canvas.R, canvas.G, canvas.B), 0),
                new GradientStop(Color.FromArgb(0, canvas.R, canvas.G, canvas.B), 0.6),
            },
        };
    }
}
