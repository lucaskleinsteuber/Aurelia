using System.Globalization;

namespace Aurelia.Server.Services;

/// <summary>
/// One sound track as plain 16 kHz mono PCM, for a device that writes subtitles from speech
/// (docs/CLIENT_PROTOCOL.md). Decoding sound alone is light work even for a small server. The
/// sound goes straight from ffmpeg into the response and is never stored.
/// </summary>
public static class LiveSpeechAudio
{
    public const int SampleRate = 16_000;
    public const string ContentType = "audio/L16;rate=16000;channels=1";

    /// <summary>
    /// A surround track's dialogue sits in its center channel; leaning on it keeps music and
    /// effects quieter for the recognizer. Stereo and mono are mixed down as they are.
    /// </summary>
    public static string Mix(int channels, bool centerMix) =>
        centerMix && channels >= 6 ? "pan=mono|c0=0.7*FC+0.15*FL+0.15*FR," : string.Empty;

    public static IReadOnlyList<string> Arguments(string input, ProbedAudio track, bool centerMix = true) =>
    [
        "-hide_banner", "-nostdin", "-loglevel", "error", "-protocol_whitelist", "file",
        "-i", "file:" + input, "-map", string.Create(CultureInfo.InvariantCulture, $"0:{track.Index}"),
        "-map_metadata", "-1", "-map_chapters", "-1", "-vn", "-sn", "-dn",
        "-af", Mix(track.Channels, centerMix) + string.Create(CultureInfo.InvariantCulture, $"aresample={SampleRate}"),
        "-ac", "1", "-ar", SampleRate.ToString(CultureInfo.InvariantCulture),
        "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1",
    ];

    /// <summary>The track to listen to: the requested one, else the default, else the first.</summary>
    public static ProbedAudio? Choose(IReadOnlyList<ProbedAudio> tracks, int? index) =>
        index is { } wanted
            ? tracks.FirstOrDefault(track => track.Index == wanted)
            : tracks.FirstOrDefault(track => track.IsDefault) ?? (tracks.Count > 0 ? tracks[0] : null);
}
