using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Controls;

/// <summary>A search field with a magnifying glass at its start, like the Mac's search fields.</summary>
internal static class SearchField
{
    public static TextBox WithGlass(this TextBox box)
    {
        box.InnerLeftContent = new PathIcon
        {
            Data = Application.Current?.FindResource("IconSearch") as Geometry,
            Width = 14,
            Height = 14,
            Margin = new Thickness(12, 0, 0, 0),
            Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)),
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false,
        };
        box.Padding = new Thickness(8, 8, 12, 8);
        return box;
    }
}
