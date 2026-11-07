using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Controls;

/// <summary>
/// A cast or crew member without a photo: a quiet person symbol on a dark gradient, as on the Mac.
/// The colorful initials stay reserved for viewing profiles, so the two are never confused.
/// </summary>
public sealed class PersonPlaceholder : Border
{
    public PersonPlaceholder(double size)
    {
        Width = size;
        Height = size;
        CornerRadius = new CornerRadius(size / 2);
        ClipToBounds = true;
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF));
        BorderThickness = new Thickness(1);
        Background = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
            EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
            GradientStops = { new GradientStop(Color.Parse("#2C3034"), 0), new GradientStop(Color.Parse("#1B1E21"), 1) },
        };
        Child = new PathIcon
        {
            Data = Application.Current?.FindResource("IconPerson") as Geometry,
            Width = size * 0.42,
            Height = size * 0.42,
            Foreground = new SolidColorBrush(Color.FromArgb(0x8A, 0xFF, 0xFF, 0xFF)),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }
}
