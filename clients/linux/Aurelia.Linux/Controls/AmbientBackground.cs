using Avalonia;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Styling;

namespace Aurelia.Linux.Controls;

/// <summary>
/// The calm, slowly drifting wash of color behind "Who's watching?" and the PIN, as on the Mac
/// (AureliaAmbientBackground): blue, teal and violet glows on the canvas color with a soft dark
/// vignette. It shows no titles before a profile is open. With Reduce Motion the glows stand still.
/// </summary>
public sealed class AmbientBackground : Panel, IDisposable
{
    private static readonly (Color Color, double Diameter, double X, double Y, double DriftX, double DriftY)[] Glows =
    [
        (Color.FromRgb(0x33, 0x42, 0x9E), 0.62, -0.30, -0.16, -0.22, -0.24),
        (Color.FromRgb(0x0D, 0x61, 0x70), 0.55, 0.22, 0.30, 0.30, 0.20),
        (Color.FromRgb(0x66, 0x29, 0x70), 0.48, 0.28, -0.20, 0.18, -0.30),
    ];

    private readonly bool animate;
    private readonly List<(Border Glow, TranslateTransform Move, int Index)> glows = [];
    private CancellationTokenSource? drifting;

    public AmbientBackground(bool animate = true)
    {
        this.animate = animate;
        IsHitTestVisible = false;
        ClipToBounds = true;
        Background = Application.Current?.FindResource("AureliaCanvasBrush") as IBrush ?? new SolidColorBrush(Color.Parse("#202326"));
        for (var index = 0; index < Glows.Length; index++)
        {
            var move = new TranslateTransform();
            var glow = new Border
            {
                RenderTransform = move,
                Background = new RadialGradientBrush
                {
                    GradientStops =
                    {
                        new GradientStop(Color.FromArgb(0x80, Glows[index].Color.R, Glows[index].Color.G, Glows[index].Color.B), 0),
                        new GradientStop(Color.FromArgb(0x40, Glows[index].Color.R, Glows[index].Color.G, Glows[index].Color.B), 0.45),
                        new GradientStop(Color.FromArgb(0, Glows[index].Color.R, Glows[index].Color.G, Glows[index].Color.B), 1),
                    },
                },
            };
            glows.Add((glow, move, index));
            Children.Add(glow);
        }
        Children.Add(new Border
        {
            Background = new RadialGradientBrush
            {
                GradientStops = { new GradientStop(Color.FromArgb(0, 0, 0, 0), 0.3), new GradientStop(Color.FromArgb(0x59, 0, 0, 0), 1) },
            },
        });
        SizeChanged += (_, _) => Place();
        AttachedToVisualTree += (_, _) => StartDrift();
        DetachedFromVisualTree += (_, _) => StopDrift();
    }

    /// <summary>Each glow is a circle as wide as part of the window's longer side, centered at its offset.</summary>
    private void Place()
    {
        var size = Math.Max(Bounds.Width, Bounds.Height);
        foreach (var (glow, move, index) in glows)
        {
            var spec = Glows[index];
            var diameter = size * spec.Diameter * 1.5;
            glow.Width = diameter;
            glow.Height = diameter;
            glow.HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center;
            glow.VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center;
            move.X = Bounds.Width * spec.X;
            move.Y = Bounds.Height * spec.Y;
        }
        StartDrift();
    }

    public void Dispose() => StopDrift();

    private void StopDrift()
    {
        drifting?.Cancel();
        drifting?.Dispose();
        drifting = null;
    }

    private void StartDrift()
    {
        StopDrift();
        if (!animate || Bounds.Width <= 0 || VisualRoot is null) return;
        drifting = new CancellationTokenSource();
        foreach (var (glow, _, index) in glows)
        {
            var spec = Glows[index];
            var animation = new Animation
            {
                Duration = TimeSpan.FromSeconds(16),
                IterationCount = IterationCount.Infinite,
                PlaybackDirection = PlaybackDirection.Alternate,
                Easing = new SineEaseInOut(),
                Children =
                {
                    new KeyFrame
                    {
                        Cue = new Cue(0),
                        Setters = { new Setter(TranslateTransform.XProperty, Bounds.Width * spec.X), new Setter(TranslateTransform.YProperty, Bounds.Height * spec.Y) },
                    },
                    new KeyFrame
                    {
                        Cue = new Cue(1),
                        Setters = { new Setter(TranslateTransform.XProperty, Bounds.Width * spec.DriftX), new Setter(TranslateTransform.YProperty, Bounds.Height * spec.DriftY) },
                    },
                },
            };
            _ = animation.RunAsync(glow, drifting.Token);
        }
    }
}
