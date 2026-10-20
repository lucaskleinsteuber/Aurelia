using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Chrome;
using Avalonia.Input;
using Avalonia.Media;

namespace Aurelia.Desktop.Views;

/// <summary>
/// The window's content reaches up under its title bar, as in the Mac app: no light Windows title
/// strip, the system's own window buttons stay, and a transparent area along the top moves the window.
/// Content below it is told how much room the title bar takes (on a Mac the window buttons sit on the left).
/// </summary>
internal static class TitleBar
{
    public static void Extend(Window window, Panel root, Action<double> inset)
    {
        window.ExtendClientAreaToDecorationsHint = true;
        window.ExtendClientAreaTitleBarHeightHint = -1;
        var drag = new Border { Background = Brushes.Transparent, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top, Height = 0, ZIndex = 1000 };
        WindowDecorationProperties.SetElementRole(drag, WindowDecorationsElementRole.TitleBar);
        root.Children.Add(drag);
        void Apply()
        {
            var top = window.IsExtendedIntoWindowDecorations && window.WindowState != WindowState.FullScreen ? window.WindowDecorationMargin.Top : 0;
            drag.Height = top;
            inset(top);
        }
        window.PropertyChanged += (_, e) =>
        {
            if (e.Property == Window.WindowDecorationMarginProperty || e.Property == Window.IsExtendedIntoWindowDecorationsProperty
                || e.Property == Window.WindowStateProperty)
                Apply();
        };
        window.Opened += (_, _) => Apply();
    }
}
