using System.Globalization;
using System.Text.RegularExpressions;

namespace Aurelia.Linux.Core.Management;

/// <summary>Words for Settings › Server › Performance, as in the Mac app and the browser.</summary>
public static partial class PerformanceText
{
    /// <summary>"12 ms" or "1.4 s".</summary>
    public static string Duration(double milliseconds) =>
        milliseconds >= 1000
            ? (milliseconds / 1000).ToString("0.0", CultureInfo.InvariantCulture) + " s"
            : Math.Round(milliseconds).ToString(CultureInfo.InvariantCulture) + " ms";

    /// <summary>"/catalog/items/‹mediaId›" for "/api/v1/catalog/items/{mediaId:guid}".</summary>
    public static string Route(string route)
    {
        ArgumentNullException.ThrowIfNull(route);
        var text = route.StartsWith("/api/v1", StringComparison.Ordinal) ? route[7..] : route;
        text = Parameter().Replace(text, match => "‹" + match.Groups[1].Value + "›");
        return text.Length == 0 ? "/" : text;
    }

    [GeneratedRegex(@"\{\*{0,2}([A-Za-z0-9_]+)(?::[^}]*)?\}")]
    private static partial Regex Parameter();
}
