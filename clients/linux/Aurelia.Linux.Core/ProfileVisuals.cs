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

    /// <summary>The named palettes of built-in pictures (<see cref="Aurelia.Contracts.ProfilePictures.Palettes"/>), the seven above plus red.</summary>
    public static (string Top, string Bottom) NamedPalette(string name) => name switch
    {
        "blue" => Palettes[0],
        "purple" => Palettes[1],
        "pink" => Palettes[2],
        "orange" => Palettes[3],
        "teal" => Palettes[4],
        "green" => Palettes[5],
        "indigo" => Palettes[6],
        "red" => ("#FF7A6B", "#C9302C"),
        _ => Palettes[0],
    };

    /// <summary>The symbol and palette of a built-in picture key, or null for a photo or no picture.</summary>
    public static (string Symbol, string Palette)? Builtin(string? key) =>
        Aurelia.Contracts.ProfilePictures.IsBuiltin(key) && key!.Split(':') is [var symbol, var palette] ? (symbol, palette) : null;

    /// <summary>The name a profile shows: its display name, or its sign-in name before one was chosen.</summary>
    public static string ShownName(Aurelia.Contracts.UserSummary user) => user.DisplayName ?? user.Username;

    public static string Initial(string? name) =>
        name?.Trim() is { Length: > 0 } trimmed ? char.ToUpperInvariant(trimmed[0]).ToString() : "?";
}
