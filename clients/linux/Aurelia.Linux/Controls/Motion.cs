using Avalonia;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Transformation;
using Avalonia.Threading;

namespace Aurelia.Linux.Controls;

/// <summary>
/// Short, quiet motion that makes pages, sheets and menus feel immediate: what appears fades in
/// and settles from a few points away within a fraction of a second, while its content is still
/// arriving. Nothing waits for an animation to finish.
/// </summary>
public static class Motion
{
    public static readonly TimeSpan Quick = TimeSpan.FromMilliseconds(170);

    /// <summary>Set by tests and screenshots so every frame shows the finished state.</summary>
    public static bool Enabled { get; set; } = true;

    /// <summary>Fades <paramref name="control"/> in and lets it settle upward by <paramref name="rise"/> points.</summary>
    public static void Appear(Control control, double rise = 10, double fromScale = 1)
    {
        if (!Enabled)
        {
            control.Opacity = 1;
            return;
        }
        var easing = new CubicEaseOut();
        control.Transitions =
        [
            new DoubleTransition { Property = Visual.OpacityProperty, Duration = Quick, Easing = easing },
            new TransformOperationsTransition { Property = Visual.RenderTransformProperty, Duration = Quick, Easing = easing },
        ];
        // Start state without animating to it.
        var transitions = control.Transitions;
        control.Transitions = null;
        control.Opacity = 0;
        control.RenderTransform = TransformOperations.Parse(Start(rise, fromScale));
        control.Transitions = transitions;
        Dispatcher.UIThread.Post(() =>
        {
            control.Opacity = 1;
            control.RenderTransform = TransformOperations.Parse("translateY(0px) scale(1)");
        }, DispatcherPriority.Render);
    }

    private static string Start(double rise, double scale) =>
        FormattableString.Invariant($"translateY({rise}px) scale({scale})");
}
