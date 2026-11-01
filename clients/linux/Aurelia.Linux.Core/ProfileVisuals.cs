namespace Aurelia.Linux.Core;

/// <summary>Profile pictures: the initial on a gradient whose colors come from the profile's id, as on the Mac.</summary>
public static class ProfileVisuals
{
    /// <summary>Top and bottom gradient colors as #RRGGBB, in the Mac app's order.</summary>
    public static readonly (string Top, string Bottom)[] Palettes =
    [
        ("#5C9EFF", "#215CDB"),
        ("#BD7DFF", "#7038D1"),
        ("#FF8C99", "#D63D66"),
        ("#FFB85C", "#E66B24"),
        ("#5CD6CC", "#1A858F"),
        ("#80DB7A", "#2E8F4D"),
        ("#8C99FF", "#474DCC"),
    ];

    /// <summary>The sum of the id's sixteen bytes picks the palette, so every client shows the same color.</summary>
    public static int PaletteIndex(Guid? id) => id is { } value ? value.ToByteArray().Sum(b => b) % Palettes.Length : 0;

    public static string Initial(string? name) =>
        name?.Trim() is { Length: > 0 } trimmed ? char.ToUpperInvariant(trimmed[0]).ToString() : "?";
}
