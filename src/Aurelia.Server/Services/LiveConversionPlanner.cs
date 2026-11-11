using System.Globalization;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public enum LiveVideoEncoder
{
    /// <summary>The software encoder of a Linux distribution's ffmpeg.</summary>
    Libx264,
    /// <summary>Apple's hardware encoder in the Mac app's own ffmpeg.</summary>
    VideoToolbox,
    /// <summary>An Nvidia graphics card's encoder.</summary>
    Nvenc,
    /// <summary>Intel Quick Sync through oneVPL.</summary>
    Qsv,
    /// <summary>The VA-API encoder of Intel and AMD graphics on Linux.</summary>
    Vaapi,
}

/// <param name="Start">Seconds into the title; the output keeps the title's own timestamps.</param>
/// <param name="Encoder">Null repackages the picture unchanged.</param>
/// <param name="Hardware">The chip for a hardware <paramref name="Encoder"/>: its device and whether it decodes too.</param>
/// <param name="Step">The size and bitrate to convert to; null keeps the 1080p limit of a plain live stream.</param>
/// <param name="SegmentSeconds">Forces a key frame every so many seconds of title time, for segments of that length.</param>
public sealed record LiveStreamOptions(
    double Start,
    ProbedVideo Video,
    LiveVideoEncoder? Encoder,
    ProbedAudio? Audio,
    bool CopyAudio,
    HdrToneMapping ToneMapping = HdrToneMapping.Unavailable,
    HardwareEncoder? Hardware = null,
    StreamingStep? Step = null,
    int? SegmentSeconds = null);

/// <summary>
/// Decides how a title reaches a player that cannot open the original: the picture is only
/// repackaged when the player decodes it, and re-encoded to H.264 (at most 1080p) otherwise;
/// sound the player cannot decode becomes stereo AAC. All of it is pure, so tests can check
/// every decision without ffmpeg.
/// </summary>
public static class LiveConversionPlanner
{
    public const int MaximumWidth = 1920;
    public const int MaximumHeight = 1080;
    public const string ConvertedVideoCodec = "avc1.640029";
    public const string ConvertedAudioCodec = "mp4a.40.2";

    /// <summary>Picture formats a fragmented MP4 can carry for a browser.</summary>
    public static readonly IReadOnlySet<string> CopyableVideo = new HashSet<string>(["h264", "hevc", "av1", "vp9"], StringComparer.Ordinal);

    /// <summary>Sound formats a fragmented MP4 can carry for a browser.</summary>
    public static readonly IReadOnlySet<string> CopyableAudio = new HashSet<string>(["aac", "mp3", "ac3", "eac3", "opus", "flac"], StringComparer.Ordinal);

    /// <returns>Null when the picture can neither be repackaged nor converted.</returns>
    public static LiveConversionPlanResponse? Plan(MediaProbeResult probe, LiveConversionRequest request, bool canEncodeVideo,
        HdrToneMapping toneMapping = HdrToneMapping.Unavailable)
        => Plan(probe, request, canEncodeVideo, () => toneMapping);

    public static LiveConversionPlanResponse? Plan(MediaProbeResult probe, LiveConversionRequest request, bool canEncodeVideo,
        Func<HdrToneMapping> resolveToneMapping,
        IReadOnlyList<DiscoveredSidecarSubtitle>? sidecars = null)
    {
        if (probe.Video is not { Width: > 0, Height: > 0 } video) return null;
        var videoCodecs = Normalize(request.VideoCodecs);
        var audioCodecs = Normalize(request.AudioCodecs);
        var copy = CanCopyVideo(video, videoCodecs);
        if (!copy && !canEncodeVideo) return null;
        if (!copy && video.IsHdr && resolveToneMapping() == HdrToneMapping.Unavailable) throw LiveHdr.Unsupported();
        var (width, height) = copy ? (video.Width, video.Height) : Fit(video.Width, video.Height);
        var tracks = probe.Audio.Select(track =>
        {
            var copyAudio = CanCopyAudio(track, audioCodecs);
            return new LiveAudioTrack(track.Index, track.Codec, track.Channels, track.Language, track.Title, track.IsDefault,
                copyAudio ? "copy" : "aac", copyAudio ? AudioCodec(track) : ConvertedAudioCodec);
        }).ToList();
        var first = tracks.FirstOrDefault(track => track.IsDefault) ?? tracks.FirstOrDefault();

        var subtitleTracks = (probe.Subtitles ?? []).Select(track => new LiveSubtitleTrack(
            track.Index, track.Codec, track.Language, track.Title, track.IsDefault, track.IsForced,
            LiveSubtitles.CanConvert(track.Codec), IsSidecar: false)).ToList();

        if (sidecars is not null)
        {
            for (var i = 0; i < sidecars.Count; i++)
            {
                var sc = sidecars[i];
                subtitleTracks.Add(new LiveSubtitleTrack(
                    1000 + i, sc.Format, sc.Language, sc.Title, sc.IsDefault, sc.IsForced, sc.Supported,
                    IsSidecar: true, IsSdh: sc.IsSdh));
            }
        }

        return new LiveConversionPlanResponse(
            copy ? "copy" : "h264",
            copy ? VideoCodec(video) : ConvertedVideoCodec,
            width,
            height,
            probe.DurationSeconds,
            tracks,
            first?.Index,
            subtitleTracks);
    }

    public static bool CanCopyVideo(ProbedVideo video, IReadOnlySet<string> playerCodecs)
    {
        if (!CopyableVideo.Contains(video.Codec) || !playerCodecs.Contains(video.Codec)) return false;
        // Browsers decode 4:2:0 pictures only, and H.264 only with 8 bits.
        if (video.PixelFormat is { } format && !format.StartsWith("yuv420p", StringComparison.Ordinal)
            && !format.StartsWith("yuvj420p", StringComparison.Ordinal) && !format.StartsWith("nv12", StringComparison.Ordinal)
            && !format.StartsWith("p010", StringComparison.Ordinal)) return false;
        return video.Codec == "h264" ? video.BitDepth <= 8 : video.BitDepth <= 10;
    }

    public static bool CanCopyAudio(ProbedAudio audio, IReadOnlySet<string> playerCodecs) =>
        CopyableAudio.Contains(audio.Codec) && playerCodecs.Contains(audio.Codec);

    /// <summary>The largest size within 1920 × 1080 with the same shape, in even numbers.</summary>
    public static (int Width, int Height) Fit(int width, int height) => Fit(width, height, MaximumWidth, MaximumHeight);

    /// <summary>The largest size within the box with the same shape, in even numbers; never larger than the original.</summary>
    public static (int Width, int Height) Fit(int width, int height, int maximumWidth, int maximumHeight)
    {
        var scale = Math.Min(1.0, Math.Min((double)maximumWidth / width, (double)maximumHeight / height));
        return (Math.Max(2, (int)Math.Round(width * scale / 2) * 2), Math.Max(2, (int)Math.Round(height * scale / 2) * 2));
    }

    /// <summary>The RFC 6381 codec string a browser's MediaSource expects for a repackaged picture.</summary>
    public static string VideoCodec(ProbedVideo video)
    {
        switch (video.Codec)
        {
            case "h264":
                var profile = video.Profile switch
                {
                    "Constrained Baseline" => "42E0",
                    "Baseline" => "4200",
                    "Main" => "4D40",
                    "Extended" => "5800",
                    "High 10" or "High 10 Intra" => "6E00",
                    "High 4:2:2" or "High 4:2:2 Intra" => "7A00",
                    "High 4:4:4 Predictive" or "High 4:4:4 Intra" => "F400",
                    _ => "6400",
                };
                return $"avc1.{profile}{Math.Clamp(video.Level > 0 ? video.Level : 40, 1, 255):X2}";
            case "hevc":
                var main10 = video.Profile == "Main 10" || video.BitDepth == 10;
                return $"hvc1.{(main10 ? "2.4" : "1.6")}.L{(video.Level > 0 ? video.Level : 120).ToString(CultureInfo.InvariantCulture)}.B0";
            case "av1":
                var av1Profile = video.Profile switch { "High" => 1, "Professional" => 2, _ => 0 };
                return $"av01.{av1Profile}.{Math.Clamp(video.Level >= 0 ? video.Level : 8, 0, 31):D2}M.{(video.BitDepth >= 10 ? 10 : 8):D2}";
            case "vp9":
                var vp9Profile = video.Profile switch { "Profile 1" => 1, "Profile 2" => 2, "Profile 3" => 3, _ => video.BitDepth >= 10 ? 2 : 0 };
                return $"vp09.{vp9Profile:D2}.{(video.Level > 0 ? video.Level : 40):D2}.{(video.BitDepth >= 10 ? 10 : 8):D2}";
            default:
                return ConvertedVideoCodec;
        }
    }

    /// <summary>The RFC 6381 codec string of a sound track that is kept unchanged.</summary>
    public static string AudioCodec(ProbedAudio audio) => audio.Codec switch
    {
        "aac" => audio.Profile switch { "HE-AAC" => "mp4a.40.5", "HE-AACv2" => "mp4a.40.29", _ => ConvertedAudioCodec },
        "mp3" => "mp4a.6B",
        "ac3" => "ac-3",
        "eac3" => "ec-3",
        "opus" => "opus",
        "flac" => "flac",
        _ => ConvertedAudioCodec,
    };

    /// <summary>
    /// ffmpeg's arguments for one live stream: a fixed list, never a shell command. The output is
    /// fragmented MP4 on standard output; nothing is written anywhere else.
    /// </summary>
    public static IReadOnlyList<string> Arguments(string input, LiveStreamOptions options)
    {
        var arguments = new List<string>
        {
            "-hide_banner", "-nostdin", "-loglevel", "error", "-protocol_whitelist", "file",
        };
        if (options.Encoder is { } chosen && HardwareEncoding.IsHardware(chosen) && chosen != LiveVideoEncoder.VideoToolbox)
        {
            var hardware = options.Hardware is { } chip && chip.Kind == chosen
                ? chip
                : throw new InvalidOperationException("A hardware encoder needs its chip.");
            arguments.AddRange(HardwareEncoding.DeviceArguments(hardware, decode: true));
        }
        if (options.Start > 0) arguments.AddRange(["-ss", Seconds(options.Start)]);
        // The output keeps the file's own timestamps, so a stream started at a later point still
        // reports the real position in the title.
        // Normalize a container's nonzero start as well: resumed fragments and WebVTT use title time.
        arguments.AddRange(["-copyts", "-start_at_zero", "-fflags", "+genpts", "-i", "file:" + input]);
        arguments.AddRange(["-map", $"0:{options.Video.Index}"]);
        if (options.Audio is { } audio) arguments.AddRange(["-map", $"0:{audio.Index}"]);
        arguments.AddRange(["-map_metadata", "-1", "-map_chapters", "-1"]);

        switch (options.Encoder)
        {
            case null:
                arguments.AddRange(["-c:v", "copy"]);
                // Safari only plays HEVC in MP4 under the hvc1 name.
                if (options.Video.Codec == "hevc") arguments.AddRange(["-tag:v", "hvc1"]);
                break;
            case { } kind:
                // A plain live stream keeps its former rates: x264 up to 8 Mbit/s, a chip at 6 Mbit/s.
                var kilobits = options.Step?.VideoKilobits ?? (kind == LiveVideoEncoder.Libx264 ? 8000 : 6000);
                arguments.AddRange(HardwareEncoding.EncoderArguments(kind, kilobits));
                if (kind == LiveVideoEncoder.Libx264) arguments.AddRange(["-level:v", options.Step?.LevelName ?? "4.1"]);
                AddPicture(arguments, options, kind);
                break;
        }

        if (options.Audio is { } track)
        {
            if (options.CopyAudio)
            {
                arguments.AddRange(["-c:a", "copy"]);
                if (track.Codec is "opus" or "flac") arguments.AddRange(["-strict", "experimental"]);
            }
            else arguments.AddRange(["-c:a", "aac", "-ac", "2", "-b:a", ((options.Step?.AudioKilobits ?? 192) + "k")]);
        }

        // A stream from a later point marks its first fragment as discontinuous, so the fragment
        // carries its real time in the title instead of starting again at zero.
        arguments.AddRange([
            "-sn", "-dn", "-f", "mp4", "-movflags",
            options.Start > 0
                ? "frag_keyframe+delay_moov+default_base_moof+frag_discont+skip_trailer"
                : "frag_keyframe+empty_moov+default_base_moof+skip_trailer",
            "pipe:1",
        ]);
        return arguments;
    }

    private static void AddPicture(List<string> arguments, LiveStreamOptions options, LiveVideoEncoder kind)
    {
        var (width, height) = options.Step is { } step ? (step.Width, step.Height) : (MaximumWidth, MaximumHeight);
        arguments.AddRange(["-vf", HardwareEncoding.UploadFilter(kind, LiveHdr.PictureFilter(options.Video, options.ToneMapping, width, height))]);
        if (options.SegmentSeconds is { } seconds and > 0)
        {
            // A key frame where each segment begins. ffmpeg counts t from the first frame it
            // encodes, which is a segment's start, so every further segment is n_forced × length on.
            arguments.AddRange([
                "-force_key_frames", $"expr:gte(t,n_forced*{seconds.ToString(CultureInfo.InvariantCulture)})",
                "-g", "600",
            ]);
            if (kind == LiveVideoEncoder.Libx264) arguments.AddRange(["-sc_threshold", "0"]);
        }
        // A key frame every two seconds or so keeps fragments small, so playback starts soon.
        else arguments.AddRange(["-g", "48"]);
        if (options.Video.IsHdr) arguments.AddRange([
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
        ]);
    }

    private static string Seconds(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);

    private static HashSet<string> Normalize(IReadOnlyList<string>? codecs) =>
        new((codecs ?? []).Where(codec => !string.IsNullOrWhiteSpace(codec)).Select(codec => codec.Trim().ToLowerInvariant()), StringComparer.Ordinal);
}
