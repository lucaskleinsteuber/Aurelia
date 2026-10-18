using System.Globalization;
using Avalonia.Data.Converters;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Design;

/// <summary>Shows a profile's first letter in its round avatar.</summary>
public sealed class InitialsConverter : IValueConverter
{
    public static readonly InitialsConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => Initials.Of(value as string);

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
