namespace Aurelia.Contracts;

// Live conversion for players that cannot open the original file, such as a web browser with an
// MKV. The server repackages (and only when needed re-encodes) while the title plays and sends
// fragmented MP4 straight into the response. Nothing converted is ever stored.

/// <summary>What the player can decode: codec families such as "h264", "hevc", "aac" or "ac3".</summary>
public sealed record LiveConversionRequest(
    IReadOnlyList<string> VideoCodecs,
    IReadOnlyList<string> AudioCodecs);

/// <param name="Video">"copy" repackages the picture unchanged; "h264" re-encodes it.</param>
/// <param name="VideoCodec">The MP4 codec string of the picture, such as "avc1.640028".</param>
/// <param name="DurationSeconds">The whole title, so a player's timeline shows all of it.</param>
/// <param name="AudioTrack">The stream index of the track to start with, or null without sound.</param>
public sealed record LiveConversionPlanResponse(
    string Video,
    string VideoCodec,
    int Width,
    int Height,
    double? DurationSeconds,
    IReadOnlyList<LiveAudioTrack> AudioTracks,
    int? AudioTrack,
    IReadOnlyList<LiveSubtitleTrack>? SubtitleTracks = null);

/// <param name="Index">The stream index in the file, sent back as the stream's audio parameter.</param>
/// <param name="Mode">"copy" keeps the sound unchanged; "aac" converts it to stereo AAC.</param>
/// <param name="Codec">The MP4 codec string the player receives, such as "mp4a.40.2" or "ac-3".</param>
public sealed record LiveAudioTrack(
    int Index,
    string Format,
    int Channels,
    string? Language,
    string? Title,
    bool IsDefault,
    string Mode,
    string Codec);

/// <summary>An embedded or sidecar subtitle track; bitmap formats are listed but cannot become WebVTT.</summary>
public sealed record LiveSubtitleTrack(
    int Index,
    string Format,
    string? Language,
    string? Title,
    bool IsDefault,
    bool IsForced,
    bool Supported,
    bool IsSidecar = false,
    bool IsSdh = false);
