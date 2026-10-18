using System.Globalization;

namespace Aurelia.Desktop.Core;

/// <summary>The first letter of a profile name for its round avatar.</summary>
public static class Initials
{
    public static string Of(string? name) =>
        string.IsNullOrWhiteSpace(name) ? "?" : StringInfo.GetNextTextElement(name.Trim()).ToUpper(CultureInfo.CurrentCulture);
}
