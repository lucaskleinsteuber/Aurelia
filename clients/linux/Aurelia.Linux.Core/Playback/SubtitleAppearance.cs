namespace Aurelia.Linux.Core.Playback;

/// <summary>
/// How large subtitles are and what is behind them (Settings › Playback), as in the browser and
/// on the Mac. VLC draws them into the picture, so they are options of the VLC instance and apply
/// from the next title. Medium on a transparent background is VLC's own look and adds nothing.
/// </summary>
public sealed record SubtitleAppearance(string Size = SubtitleAppearance.Medium, string Background = SubtitleAppearance.Transparent)
{
    public const string Small = "small";
    public const string Medium = "medium";
    public const string Large = "large";
    public const string Transparent = "transparent";
    public const string SemiTransparent = "semiTransparent";
    public const string Solid = "solid";

    public static readonly (string Value, string Label)[] Sizes = [(Small, "Small"), (Medium, "Medium"), (Large, "Large")];
    public static readonly (string Value, string Label)[] Backgrounds =
        [(Transparent, "Transparent"), (SemiTransparent, "Semi-Transparent"), (Solid, "Solid Black")];

    public SubtitleAppearance Normalized() => new(
        Sizes.Any(choice => choice.Value == Size) ? Size : Medium,
        Backgrounds.Any(choice => choice.Value == Background) ? Background : Transparent);

    /// <summary>VLC's options for this look; none for VLC's own look.</summary>
    public IReadOnlyList<string> VlcOptions
    {
        get
        {
            var value = Normalized();
            if (value.Size == Medium && value.Background == Transparent) return [];
            var scale = value.Size switch { Small => 70, Large => 140, _ => 100 };
            var opacity = value.Background switch { SemiTransparent => 140, Solid => 255, _ => 0 };
            return [$"--sub-text-scale={scale}", $"--freetype-background-opacity={opacity}", "--freetype-background-color=0"];
        }
    }
}
