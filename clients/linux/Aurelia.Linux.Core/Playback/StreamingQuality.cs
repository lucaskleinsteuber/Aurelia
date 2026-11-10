namespace Aurelia.Linux.Core.Playback;

/// <summary>
/// Which stream the player opens: the original file, or the server's adaptive HLS stream,
/// converted live in memory, in the best quality the connection carries or up to a fixed size.
/// </summary>
public enum StreamingQuality { Original, Automatic, UpTo1080p, UpTo720p, UpTo480p }

public static class StreamingQualities
{
    public static readonly StreamingQuality[] All = Enum.GetValues<StreamingQuality>();

    public static string Title(StreamingQuality quality) => quality switch
    {
        StreamingQuality.Automatic => "Automatic",
        StreamingQuality.UpTo1080p => "Up to 1080p",
        StreamingQuality.UpTo720p => "Up to 720p",
        StreamingQuality.UpTo480p => "Up to 480p",
        _ => "Original",
    };

    /// <summary>The tallest picture VLC may pick from the master playlist, or null for any.</summary>
    public static int? MaximumHeight(StreamingQuality quality) => quality switch
    {
        StreamingQuality.UpTo1080p => 1080,
        StreamingQuality.UpTo720p => 720,
        StreamingQuality.UpTo480p => 480,
        _ => null,
    };

    /// <summary>What plays when the server can or cannot stream adaptively.</summary>
    public static StreamingQuality Effective(StreamingQuality quality, bool serverSupports) =>
        serverSupports && Enum.IsDefined(quality) ? quality : StreamingQuality.Original;

    /// <summary>The relay's stream itself, or its HLS master playlist below it.</summary>
    public static Uri PlaybackUrl(StreamingQuality quality, Uri stream) =>
        quality == StreamingQuality.Original ? stream : new Uri(stream.AbsoluteUri.TrimEnd('/') + "/hls/master.m3u8");

    /// <summary>VLC's options for the HLS stream: more buffer, and a fixed quality caps the size and keeps to the best below it.</summary>
    public static IReadOnlyList<string> VlcOptions(StreamingQuality quality)
    {
        if (quality == StreamingQuality.Original) return [];
        List<string> options = [":network-caching=1500"];
        if (MaximumHeight(quality) is { } height)
        {
            options.Add(":adaptive-maxheight=" + height.ToString(System.Globalization.CultureInfo.InvariantCulture));
            options.Add(":adaptive-logic=highest");
        }
        return options;
    }
}
