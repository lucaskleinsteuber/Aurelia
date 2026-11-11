using System.Globalization;
using System.Text.Json;

namespace Aurelia.Server.Services;

public sealed record ProbedVideo(
    int Index,
    string Codec,
    string? Profile,
    int Level,
    int Width,
    int Height,
    string? PixelFormat,
    int BitDepth,
    string? ColorTransfer = null,
    string? ColorPrimaries = null,
    string? ColorSpace = null,
    string? ColorRange = null)
{
    public bool IsHdr => ColorTransfer is "smpte2084" or "arib-std-b67";
}

public sealed record ProbedAudio(
    int Index,
    string Codec,
    string? Profile,
    int Channels,
    string? Language,
    string? Title,
    bool IsDefault);

public sealed record ProbedSubtitle(
    int Index,
    string Codec,
    string? Language,
    string? Title,
    bool IsDefault,
    bool IsForced);

/// <summary>A chapter mark from the file's header: where it begins and ends, and its name.</summary>
public sealed record ProbedChapter(double StartSeconds, double EndSeconds, string? Title);

/// <summary>
/// A description of a media file from its header: container, length and streams. It holds no
/// picture or sound, so it may stay in memory while the file is unchanged.
/// </summary>
public sealed record MediaProbeResult(
    string Container,
    double? DurationSeconds,
    ProbedVideo? Video,
    IReadOnlyList<ProbedAudio> Audio,
    IReadOnlyList<ProbedSubtitle>? Subtitles = null,
    long? BitRate = null,
    IReadOnlyList<ProbedChapter>? Chapters = null);

/// <summary>Reads a file's header with ffprobe; only the header is read, never the whole file.</summary>
public static class MediaProbe
{
    private static readonly HashSet<string> DisallowedContainers = new(StringComparer.OrdinalIgnoreCase)
    {
        "concat", "subfile", "lavfi", "sdp", "tty"
    };

    public static bool IsDisallowedContainer(string? formatName)
    {
        if (string.IsNullOrWhiteSpace(formatName)) return false;
        var formats = formatName.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        return formats.Any(f => DisallowedContainers.Contains(f));
    }

    public static IReadOnlyList<string> Arguments(string input) =>
    [
        "-hide_banner", "-loglevel", "error", "-protocol_whitelist", "file",
        "-show_entries", "stream=index,codec_name,codec_type,profile,level,width,height,pix_fmt,bits_per_raw_sample,channels,duration,color_transfer,color_primaries,color_space,color_range"
            + ":stream_disposition=attached_pic,default,forced:stream_tags=language,title:format=format_name,duration,start_time,bit_rate"
            + ":chapter=start_time,end_time:chapter_tags=title",
        "-of", "json", "file:" + input,
    ];

    public static MediaProbeResult Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var format = root.TryGetProperty("format", out var formatElement) ? formatElement : default;
        var container = Text(format, "format_name") ?? string.Empty;
        if (IsDisallowedContainer(container))
        {
            throw new JsonException("The title format is not an allowed media container.");
        }
        ProbedVideo? video = null;
        double? videoDuration = null;
        var audio = new List<ProbedAudio>();
        var subtitles = new List<ProbedSubtitle>();
        if (root.TryGetProperty("streams", out var streams) && streams.ValueKind == JsonValueKind.Array)
        {
            if (streams.GetArrayLength() > 128) throw new JsonException("The title contains too many streams.");
            foreach (var stream in streams.EnumerateArray())
            {
                var type = Text(stream, "codec_type");
                var codec = Text(stream, "codec_name")?.ToLowerInvariant();
                if (codec is null || !stream.TryGetProperty("index", out var indexElement) || !indexElement.TryGetInt32(out var index)) continue;
                // Cover pictures in MKV and MP4 are video streams too, but never the picture to play.
                if (type == "video" && video is null && Disposition(stream, "attached_pic") != 1
                    && codec is not ("png" or "bmp" or "gif" or "webp"))
                {
                    var pixelFormat = Text(stream, "pix_fmt");
                    video = new ProbedVideo(index, codec, Text(stream, "profile"), Integer(stream, "level") ?? 0,
                        Integer(stream, "width") ?? 0, Integer(stream, "height") ?? 0, pixelFormat, BitDepth(stream, pixelFormat),
                        Text(stream, "color_transfer")?.ToLowerInvariant(), Text(stream, "color_primaries")?.ToLowerInvariant(),
                        Text(stream, "color_space")?.ToLowerInvariant(), Text(stream, "color_range")?.ToLowerInvariant());
                    videoDuration = Number(stream, "duration");
                }
                else if (type == "audio")
                {
                    var language = Tag(stream, "language");
                    audio.Add(new ProbedAudio(index, codec, Text(stream, "profile"), Integer(stream, "channels") ?? 2,
                        language is null or "und" ? null : language, Tag(stream, "title"), Disposition(stream, "default") == 1));
                }
                else if (type == "subtitle")
                {
                    var language = Tag(stream, "language");
                    subtitles.Add(new ProbedSubtitle(index, codec, language is null or "und" ? null : language,
                        Tag(stream, "title"), Disposition(stream, "default") == 1, Disposition(stream, "forced") == 1));
                }
            }
        }

        var chapters = new List<ProbedChapter>();
        if (root.TryGetProperty("chapters", out var chapterList) && chapterList.ValueKind == JsonValueKind.Array)
        {
            foreach (var chapter in chapterList.EnumerateArray())
            {
                if (chapters.Count == 512) break;
                if (Number(chapter, "start_time") is { } chapterStart && Number(chapter, "end_time") is { } chapterEnd
                    && chapterStart >= 0 && chapterEnd > chapterStart)
                {
                    chapters.Add(new ProbedChapter(chapterStart, chapterEnd, Tag(chapter, "title")));
                }
            }
        }

        var duration = Number(format, "duration") is > 0 and var total ? total : videoDuration;
        return new MediaProbeResult(
            container,
            duration is > 0 ? duration : null,
            video,
            audio,
            subtitles,
            Number(format, "bit_rate") is > 0 and var rate ? (long)Math.Min(rate, long.MaxValue / 2) : null,
            chapters);
    }

    private static int BitDepth(JsonElement stream, string? pixelFormat)
    {
        if (Text(stream, "bits_per_raw_sample") is { } raw && int.TryParse(raw, CultureInfo.InvariantCulture, out var bits) && bits > 0)
            return bits;
        if (pixelFormat is null) return 8;
        if (pixelFormat.Contains("12", StringComparison.Ordinal)) return 12;
        if (pixelFormat.Contains("10", StringComparison.Ordinal) || pixelFormat.StartsWith("p010", StringComparison.Ordinal)) return 10;
        return 8;
    }

    private static string? Text(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString() is { Length: > 0 } text ? text : null,
            JsonValueKind.Number => value.GetRawText(),
            _ => null,
        };
    }

    private static int? Integer(JsonElement element, string name) =>
        Text(element, name) is { } text && int.TryParse(text, CultureInfo.InvariantCulture, out var value) ? value : null;

    private static double? Number(JsonElement element, string name) =>
        Text(element, name) is { } text && double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
            && double.IsFinite(value) ? value : null;

    private static int Disposition(JsonElement stream, string name) =>
        stream.TryGetProperty("disposition", out var disposition) ? Integer(disposition, name) ?? 0 : 0;

    private static string? Tag(JsonElement stream, string name)
    {
        if (!stream.TryGetProperty("tags", out var tags) || tags.ValueKind != JsonValueKind.Object) return null;
        foreach (var tag in tags.EnumerateObject())
            if (string.Equals(tag.Name, name, StringComparison.OrdinalIgnoreCase) && tag.Value.ValueKind == JsonValueKind.String)
            {
                var text = tag.Value.GetString()?.Trim();
                return text is { Length: > 0 } ? text[..Math.Min(text.Length, 256)] : null;
            }
        return null;
    }
}
