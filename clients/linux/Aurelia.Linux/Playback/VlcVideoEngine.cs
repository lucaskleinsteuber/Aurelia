using System.Globalization;
using System.Text.RegularExpressions;
using Aurelia.Linux.Core.Playback;
using LibVLCSharp.Shared;
using MediaTrack = Aurelia.Linux.Core.Playback.MediaTrack;

namespace Aurelia.Linux.Playback;

/// <summary>
/// Creates VLC players with the Mac app's options. Linux uses the distribution's libVLC 3 (found
/// by LibVLCSharp); Night Mode adds VLC's compressor with the Mac app's settings.
/// </summary>
public sealed partial class VlcEngineFactory : IVideoEngineFactory
{
    private static readonly string[] BaseOptions = ["--no-video-title-show", "--network-caching=500", "--no-metadata-network-access", "--no-play-and-pause"];

    private static readonly string[] NightOptions =
    [
        "--audio-filter=compressor", "--compressor-rms-peak=0.2", "--compressor-attack=15", "--compressor-release=300",
        "--compressor-threshold=-24", "--compressor-ratio=4", "--compressor-knee=6", "--compressor-makeup-gain=12",
    ];

    private static readonly Lock Gate = new();
    private static bool initialized;
    private LibVLC? normal;
    private LibVLC? night;

    public IVideoEngine Create(bool nightMode)
    {
        lock (Gate)
        {
            if (!initialized)
            {
                LibVLCSharp.Shared.Core.Initialize();
                initialized = true;
            }
            var library = nightMode
                ? night ??= new LibVLC([.. BaseOptions, .. NightOptions])
                : normal ??= new LibVLC(BaseOptions);
            return new VlcVideoEngine(library);
        }
    }
}

/// <summary>
/// One VLC media player whose frames go to <see cref="Frames"/>, so Aurelia draws them and its
/// controls can sit on top on Wayland and X11 alike. Hardware decoding uses VA-API through DRM,
/// which needs no VLC window; VLC decodes in software where that is not available.
/// </summary>
public sealed partial class VlcVideoEngine : IVideoEngine
{
    private readonly LibVLC library;
    private readonly MediaPlayer player;
    private Media? media;

    public VlcVideoEngine(LibVLC library)
    {
        this.library = library;
        player = new MediaPlayer(library);
        Frames.Attach(player);
        player.TimeChanged += (_, _) => Changed?.Invoke();
        player.LengthChanged += (_, _) => Changed?.Invoke();
        player.Playing += (_, _) => Changed?.Invoke();
        player.Paused += (_, _) => Changed?.Invoke();
        player.ESAdded += (_, _) => Changed?.Invoke();
        player.ESSelected += (_, _) => Changed?.Invoke();
        player.EndReached += (_, _) => Finished?.Invoke(EngineEnd.Ended);
        player.EncounteredError += (_, _) => Finished?.Invoke(EngineEnd.Failed);
    }

    public event Action? Changed;

    public event Action<EngineEnd>? Finished;

    public VideoFrames Frames { get; } = new();

    public long Time => player.Time;

    public long Length => player.Length;

    public bool IsPlaying => player.IsPlaying;

    public double Rate
    {
        get => player.Rate;
        set => player.SetRate((float)value);
    }

    public int Volume
    {
        get => player.Volume;
        set => player.Volume = Math.Clamp(value, 0, 100);
    }

    public bool Muted
    {
        get => player.Mute;
        set => player.Mute = value;
    }

    public IReadOnlyList<MediaTrack> AudioTracks =>
        [.. player.AudioTrackDescription.Where(track => track.Id >= 0).Select(track => Track(track.Id, track.Name))];

    public IReadOnlyList<MediaTrack> SubtitleTracks =>
        [.. player.SpuDescription.Where(track => track.Id >= 0).Select(track => Track(track.Id, track.Name))];

    public int AudioTrack
    {
        get => player.AudioTrack;
        set => player.SetAudioTrack(value);
    }

    public int SubtitleTrack
    {
        get => player.Spu;
        set => player.SetSpu(value);
    }

    public void Open(Uri url, long startMilliseconds)
    {
        media?.Dispose();
        media = new Media(library, url);
        media.AddOption(":http-reconnect");
        media.AddOption(":avcodec-hw=vaapi_drm");
        if (url.IsLoopback) media.AddOption(":network-caching=300");
        if (startMilliseconds > 0) media.AddOption(":start-time=" + (startMilliseconds / 1000.0).ToString("0.000", CultureInfo.InvariantCulture));
        player.Play(media);
    }

    public void Play() => player.SetPause(false);

    public void Pause() => player.SetPause(true);

    public void Unload() => player.Stop();

    public void Seek(long milliseconds) => player.Time = milliseconds;

    public void AddSubtitle(Uri url) => player.AddSlave(MediaSlaveType.Subtitle, url.ToString(), select: false);

    public void Dispose()
    {
        player.Stop();
        player.Dispose();
        media?.Dispose();
        Frames.Dispose();
    }

    /// <summary>VLC names tracks like "Track 1 - [English]" or "Commentary - [eng]"; the bracket holds the language.</summary>
    internal static MediaTrack Track(int id, string? name)
    {
        var text = name ?? $"Track {id}";
        var language = LanguagePattern().Match(text) is { Success: true } match ? match.Groups[1].Value : null;
        var forced = text.Contains("forced", StringComparison.OrdinalIgnoreCase);
        return new MediaTrack(id, text, language, forced);
    }

    [GeneratedRegex(@"\[([A-Za-z]{2,3}|[A-Za-z]+)\]")]
    private static partial Regex LanguagePattern();
}
