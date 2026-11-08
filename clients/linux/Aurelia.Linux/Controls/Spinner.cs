using Avalonia;
using Avalonia.Animation;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Media;
using Avalonia.Styling;

namespace Aurelia.Linux.Controls;

/// <summary>
/// The familiar turning ring that says something is loading, used everywhere instead of a
/// progress bar without progress.
/// </summary>
public sealed class Spinner : Panel
{
    private readonly Avalonia.Controls.Shapes.Path arc;

    public Spinner(double size = 28)
    {
        Width = size;
        Height = size;
        var radius = size / 2 - 2;
        var thickness = Math.Max(2, size / 10);
        // A faint full ring with a bright three-quarter arc turning on it.
        Children.Add(new Ellipse { Stroke = new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)), StrokeThickness = thickness, Margin = new Thickness(2) });
        arc = new Avalonia.Controls.Shapes.Path
        {
            Data = Geometry.Parse(FormattableString.Invariant(
                $"M {size / 2},{2} A {radius},{radius} 0 1 1 {2},{size / 2}")),
            Stroke = new SolidColorBrush(Color.FromArgb(0xE6, 0xFF, 0xFF, 0xFF)),
            StrokeThickness = thickness,
            StrokeLineCap = PenLineCap.Round,
            RenderTransformOrigin = RelativePoint.Center,
            RenderTransform = new RotateTransform(),
        };
        Children.Add(arc);
        Avalonia.Automation.AutomationProperties.SetName(this, "Loading");
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        if (!Motion.Enabled || arc.Styles.Count > 0) return;
        // A style animation turns while the spinner is shown and stops with it.
        arc.Styles.Add(new Style(selector => selector.OfType<Avalonia.Controls.Shapes.Path>())
        {
            Animations =
            {
                new Animation
                {
                    Duration = TimeSpan.FromSeconds(0.9),
                    IterationCount = IterationCount.Infinite,
                    Children =
                    {
                        new KeyFrame { Cue = new Cue(0), Setters = { new Setter(RotateTransform.AngleProperty, 0d) } },
                        new KeyFrame { Cue = new Cue(1), Setters = { new Setter(RotateTransform.AngleProperty, 360d) } },
                    },
                },
            },
        });
    }
}
