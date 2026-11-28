using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Tarven.Linux.Controls;

/// <summary>A folder or file name with a small drawn symbol in front, instead of an emoji the font may lack.</summary>
internal static class FileLabel
{
    public static StackPanel Create(string text, bool isDirectory, bool showFileIcon = false, string? textClass = null)
    {
        var label = new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        if (textClass is not null) label.Classes.Add(textClass);
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (isDirectory || showFileIcon)
        {
            panel.Children.Add(new PathIcon
            {
                Data = Application.Current?.FindResource(isDirectory ? "IconFolder" : "IconMovies") as Geometry,
                Width = 14,
                Height = 14,
                Opacity = 0.75,
                VerticalAlignment = VerticalAlignment.Center,
                Classes = { "fileGlyph" },
            });
        }
        panel.Children.Add(label);
        return panel;
    }
}
