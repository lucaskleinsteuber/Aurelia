using Aurelia.Linux.Core;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Controls;

/// <summary>A round profile picture with the profile's initial on its gradient.</summary>
public sealed class ProfileAvatar : Border
{
    public ProfileAvatar(Guid? id, string name, double size)
    {
        var (top, bottom) = ProfileVisuals.Palettes[ProfileVisuals.PaletteIndex(id)];
        Width = size;
        Height = size;
        CornerRadius = new CornerRadius(size / 2);
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF));
        BorderThickness = new Thickness(1);
        Background = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0.5, 0, RelativeUnit.Relative),
            EndPoint = new RelativePoint(0.5, 1, RelativeUnit.Relative),
            GradientStops = { new GradientStop(Color.Parse(top), 0), new GradientStop(Color.Parse(bottom), 1) },
        };
        Child = new TextBlock
        {
            Text = ProfileVisuals.Initial(name),
            FontSize = size * 0.42,
            FontWeight = FontWeight.SemiBold,
            Foreground = Brushes.White,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }
}
