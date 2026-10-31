using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Views;

/// <summary>Pieces shared by the full-window screens before the library: backdrop, symbol and headings.</summary>
internal static class ScreenParts
{
    public static Panel Backdrop(Control content) => new()
    {
        Background = Application.Current?.FindResource("AureliaBackdropBrush") as IBrush,
        Children = { content },
    };

    public static PathIcon Symbol(string resource, double size, IBrush? foreground = null) => new()
    {
        Data = Application.Current?.FindResource(resource) as Geometry,
        Width = size,
        Height = size,
        Foreground = foreground ?? new SolidColorBrush(Color.FromArgb(0xDB, 0xFF, 0xFF, 0xFF)),
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    public static TextBlock Title(string text) => new()
    {
        Text = text,
        Classes = { "pageTitle" },
        HorizontalAlignment = HorizontalAlignment.Center,
        TextAlignment = TextAlignment.Center,
        TextWrapping = TextWrapping.Wrap,
    };

    public static TextBlock Detail(string text) => new()
    {
        Text = text,
        Classes = { "subdued" },
        FontSize = 15,
        HorizontalAlignment = HorizontalAlignment.Center,
        TextAlignment = TextAlignment.Center,
        TextWrapping = TextWrapping.Wrap,
        MaxWidth = 520,
    };
}
