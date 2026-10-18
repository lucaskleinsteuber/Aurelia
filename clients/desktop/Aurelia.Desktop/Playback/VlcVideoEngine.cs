using System.Globalization;
using Aurelia.Desktop.Core;
using LibVLCSharp.Shared;
using MediaTrack = Aurelia.Desktop.Core.MediaTrack;

namespace Aurelia.Desktop.Playback;

/// <summary>The decoder: VLC renders into <see cref="VideoFrames"/>; sound goes to the system output.</summary>
public sealed class VlcVideoEngine : IVideoEngine
{
    /// <summary>
    /// Night mode compresses the soundtrack like on the Mac and Apple TV: peaks above -24 dB are
    /// reduced 4:1 and the result raised by 12 dB, so loud scenes are calmer and speech clearer.
    /// </summary>
    public static readonly string[] NightModeOptions =
    [
        "--compressor-rms-peak=0.2", "--compressor-attack=15", "--compressor-release=300",
        "--compressor-threshold=-24", "--compressor-ratio=4", "--compressor-knee=6", "--compressor-makeup-gain=12",
    ];

    private readonly LibVLC library;
    private readonly MediaPlayer player;
    private readonly int networkCaching;
    private Media? media;
    private bool disposed;

    public VlcVideoEngine(bool nightMode, int networkCaching = 500, IEnumerable<string>? extraOptions = null, string? audioOutput = null)
    {
        VlcRuntime.EnsureInitialized();
        this.networkCaching = networkCaching;
        var options = new List<string> { "--no-video-title-show", "--no-snapshot-preview", "--quiet" };
        if (nightMode) options.AddRange(NightModeOptions);
        if (extraOptions is not null) options.AddRange(extraOptions);
        library = new LibVLC(enableDebugLogs: false, [.. options]);
        player = new MediaPlayer(library);
        // Without the filter, playback simply continues as it is.
        if (nightMode) NightModeActive = VlcAudioFilter.Enable(player, "compressor", audioOutput ?? VlcRuntime.AudioOutput);
        Frames = new VideoFrames();
        Frames.Attach(player);
        // VLC must never be called back from its own event thread (stopping there deadlocks), so
        // events are passed on from the thread pool; frequent clock updates are coalesced.
        player.TimeChanged += (_, _) => RaiseChanged();
        player.LengthChanged += (_, _) => RaiseChanged();
        player.Playing += (_, _) => RaiseChanged();
        player.Paused += (_, _) => RaiseChanged();
        player.Buffering += (_, _) => RaiseChanged();
        player.ESAdded += (_, _) => RaiseChanged();
        player.EndReached += (_, _) => ThreadPool.QueueUserWorkItem(_ => Finished?.Invoke(EngineEnd.Ended));
        player.EncounteredError += (_, _) => ThreadPool.QueueUserWorkItem(_ => Finished?.Invoke(EngineEnd.Failed));
    }

    public event Action? Changed;
    public event Action<EngineEnd>? Finished;
    private int changePending;

    public VideoFrames Frames { get; }
    public bool NightModeActive { get; }
    public long Time => player.Time;
    public long Length => player.Length;
    public bool IsPlaying => player.IsPlaying;
    public double Rate { get => player.Rate; set => player.SetRate((float)value); }
    public int Volume { get => player.Volume; set => player.Volume = Math.Clamp(value, 0, 200); }
    public bool Muted { get => player.Mute; set => player.Mute = value; }

    public IReadOnlyList<MediaTrack> AudioTracks =>
        [.. player.AudioTrackDescription.Where(track => track.Id >= 0).Select(track => new MediaTrack(track.Id, track.Name ?? $"Track {track.Id}"))];

    public IReadOnlyList<MediaTrack> SubtitleTracks =>
        [.. player.SpuDescription.Where(track => track.Id >= 0).Select(track => new MediaTrack(track.Id, track.Name ?? $"Track {track.Id}"))];

    public int AudioTrack { get => player.AudioTrack; set => player.SetAudioTrack(value); }
    public int SubtitleTrack { get => player.Spu; set => player.SetSpu(value); }

    public void Open(Uri url, long startMilliseconds)
    {
        var previous = media;
        var options = new List<string> { $":network-caching={networkCaching}" };
        if (startMilliseconds > 0)
            options.Add(":start-time=" + (startMilliseconds / 1000.0).ToString("0.000", CultureInfo.InvariantCulture));
        media = new Media(library, url, [.. options]);
        player.Media = media;
        player.Play();
        previous?.Dispose();
    }

    private void RaiseChanged()
    {
        if (Interlocked.Exchange(ref changePending, 1) == 1) return;
        ThreadPool.QueueUserWorkItem(_ =>
        {
            Interlocked.Exchange(ref changePending, 0);
            if (!disposed) Changed?.Invoke();
        });
    }

    public void Play() => player.SetPause(false);
    public void Pause() => player.SetPause(true);
    public void Unload() => player.Stop();
    public void Seek(long milliseconds) => player.Time = Math.Max(0, milliseconds);

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        player.Stop();
        player.Dispose();
        media?.Dispose();
        library.Dispose();
        Frames.Dispose();
    }
}

/// <summary>Makes VLC decoders; a server on this computer needs less prebuffering.</summary>
public sealed class VlcVideoEngineFactory(bool localServer) : IVideoEngineFactory
{
    public IVideoEngine Create(bool nightMode) => new VlcVideoEngine(nightMode, localServer ? 300 : 500);
}
