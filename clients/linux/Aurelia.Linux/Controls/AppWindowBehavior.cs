using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;

namespace Aurelia.Linux.Controls;

/// <summary>
/// Window behavior for a window without a title bar: pressing on empty space near the top moves
/// the window, a double click there maximizes or restores it, and F11 switches full screen.
/// Controls such as buttons and lists keep their clicks, because they handle the press first.
/// </summary>
public static class AppWindowBehavior
{
    /// <summary>Height of the band at the top that moves the window, like a title bar.</summary>
    public const double DragBandHeight = 52;

    public static void Attach(Window window)
    {
        window.AddHandler(InputElement.PointerPressedEvent, (_, e) => OnPointerPressed(window, e), RoutingStrategies.Bubble);
        window.KeyDown += (_, e) =>
        {
            if (e.Key == Key.F11 && e.KeyModifiers == KeyModifiers.None)
            {
                ToggleFullScreen(window);
                e.Handled = true;
            }
            else if (e.Key == Key.Escape && window.WindowState == WindowState.FullScreen)
            {
                window.WindowState = WindowState.Normal;
                e.Handled = true;
            }
        };
    }

    public static void ToggleFullScreen(Window window) =>
        window.WindowState = window.WindowState == WindowState.FullScreen ? WindowState.Normal : WindowState.FullScreen;

    /// <summary>True when a press at this point should move the window rather than reach the content.</summary>
    public static bool IsInDragBand(Window window, Point point) =>
        window.WindowState != WindowState.FullScreen && point.Y >= 0 && point.Y < DragBandHeight;

    private static void OnPointerPressed(Window window, PointerPressedEventArgs e)
    {
        if (e.Handled || !e.GetCurrentPoint(window).Properties.IsLeftButtonPressed) return;
        if (!IsInDragBand(window, e.GetPosition(window))) return;
        e.Handled = true;
        if (e.ClickCount == 2)
        {
            window.WindowState = window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
            return;
        }
        window.BeginMoveDrag(e);
    }
}
