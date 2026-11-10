using System.Globalization;
using System.Text;

namespace Aurelia.Server.Services.Hls;

/// <summary>
/// The HLS playlists of a title: one master with a variant per quality and one video-on-demand
/// playlist per quality with segments of fixed length. Addresses are relative, so they work the
/// same through an app's loopback relay. Pure text, so tests compare it exactly.
/// </summary>
public static class HlsPlaylists
{
    /// <summary>The length of every segment but the last, in seconds.</summary>
    public const int SegmentSeconds = 4;

    /// <summary>The longest title that gets a playlist: 48 hours.</summary>
    public const double LongestSeconds = 48 * 3600;

    public const string ContentType = "application/vnd.apple.mpegurl";

    /// <summary>The master playlist: every quality, best first, with its peak and average rate, size and codecs.</summary>
    public static string Master(IReadOnlyList<StreamingStep> steps, int? audio)
    {
        ArgumentNullException.ThrowIfNull(steps);
        var text = new StringBuilder();
        text.Append("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n");
        foreach (var step in steps)
        {
            text.Append(CultureInfo.InvariantCulture,
                $"#EXT-X-STREAM-INF:BANDWIDTH={step.Bandwidth},AVERAGE-BANDWIDTH={(step.VideoKilobits + step.AudioKilobits) * 1000L},"
                + $"RESOLUTION={step.Width}x{step.Height},CODECS=\"{step.VideoCodec},{LiveConversionPlanner.ConvertedAudioCodec}\"\n");
            text.Append(step.Id).Append("/index.m3u8").Append(Query(audio)).Append('\n');
        }
        return text.ToString();
    }

    /// <summary>How many segments a title of this length has.</summary>
    public static int SegmentCount(double durationSeconds) =>
        durationSeconds > 0 ? (int)Math.Ceiling(Math.Min(durationSeconds, LongestSeconds) / SegmentSeconds - 0.0005) : 0;

    /// <summary>The video-on-demand playlist of one quality.</summary>
    public static string Media(double durationSeconds, int? audio)
    {
        var count = SegmentCount(durationSeconds);
        var query = Query(audio);
        var text = new StringBuilder(64 + count * 32);
        text.Append(CultureInfo.InvariantCulture,
            $"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:{SegmentSeconds}\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n");
        text.Append("#EXT-X-MAP:URI=\"init.mp4").Append(query).Append("\"\n");
        var total = Math.Min(durationSeconds, LongestSeconds);
        for (var index = 0; index < count; index++)
        {
            var length = Math.Min(SegmentSeconds, total - index * SegmentSeconds);
            text.Append(CultureInfo.InvariantCulture, $"#EXTINF:{length:0.000},\n{index}.m4s{query}\n");
        }
        text.Append("#EXT-X-ENDLIST\n");
        return text.ToString();
    }

    /// <summary>The segment a fragment starting at this title time belongs to; a frame early still counts.</summary>
    public static int SegmentFor(double seconds) => Math.Max(0, (int)Math.Floor((seconds + 0.05) / SegmentSeconds));

    private static string Query(int? audio) => audio is { } track ? "?audio=" + track.ToString(CultureInfo.InvariantCulture) : string.Empty;
}
