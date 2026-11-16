using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Controls;

/// <summary>
/// The Close button of a view that covers the whole window (Movie Night, Wrapped): the round
/// button of the detail pages, at the top right below the window buttons, so it never sits on
/// the window's own close button.
/// </summary>
public static class OverlayClose
{
    public static Button Create(string label, Action close, IBrush? foreground = null)
    {
        var button = new Button
        {
            Classes = { "heroAction" },
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, WindowChrome.ClearTop, 24, 0),
            Content = new PathIcon { Data = Application.Current?.FindResource("IconWindowClose") as Geometry, Width = 14, Height = 14 },
        };
        if (foreground is not null) button.Foreground = foreground;
        AutomationProperties.SetName(button, label);
        ToolTip.SetTip(button, label + " (Esc)");
        button.Click += (_, _) => close();
        return button;
    }
}
