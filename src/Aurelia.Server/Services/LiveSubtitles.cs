namespace Aurelia.Server.Services;

/// <summary>Text-only subtitle conversion. The complete track keeps the title's normalized timeline.</summary>
public static class LiveSubtitles
{
    public const int MaximumBytes = 8 * 1024 * 1024;

    public static bool CanConvert(string codec) => codec is "subrip" or "srt" or "ass" or "ssa" or "mov_text" or "webvtt" or "text";

    public static IReadOnlyList<string> Arguments(string input, int index) =>
    [
        "-hide_banner", "-nostdin", "-loglevel", "error", "-protocol_whitelist", "file",
        "-copyts", "-start_at_zero", "-i", "file:" + input, "-map", $"0:{index}",
        "-map_metadata", "-1", "-map_chapters", "-1", "-vn", "-an", "-dn", "-c:s", "webvtt", "-f", "webvtt", "pipe:1",
    ];
}
