using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Aurelia.Linux.Core.Playback;
using LibVLCSharp.Shared;
using MediaTrack = Aurelia.Linux.Core.Playback.MediaTrack;

namespace Aurelia.Linux.Playback;

/// <summary>
/// Creates VLC players with the Mac app's options. Linux uses the distribution's libVLC 3 (found
/// by LibVLCSharp); audio processing uses the same profiles as the Apple clients.
/// </summary>
public sealed partial class VlcEngineFactory : IVideoEngineFactory, IScrubPreviewDecoderFactory
{
    private static readonly string[] BaseOptions = ["--no-video-title-show", "--network-caching=500", "--no-metadata-network-access", "--no-play-and-pause"];

    private static readonly Lock Gate = new();
    private static bool initialized;
    private readonly Dictionary<VolumeLeveling, LibVLC> audioLibraries = [];
    private LibVLC? previews;

    public IScrubPreviewDecoder CreatePreviewDecoder()
    {
        lock (Gate)
        {
            if (!initialized)
            {
                LibVLCSharp.Shared.Core.Initialize();
                initialized = true;
            }
            return new VlcScrubPreviewDecoder(previews ??= new LibVLC([.. BaseOptions, "--no-audio", "--no-spu"]));
        }
    }

    public IVideoEngine Create(bool nightMode) => Create(new AudioProcessing(Leveling: nightMode ? VolumeLeveling.Standard : VolumeLeveling.Off));

    public IVideoEngine Create(AudioProcessing processing)
    {
        lock (Gate)
        {
            if (!initialized)
            {
                LibVLCSharp.Shared.Core.Initialize();
                initialized = true;
            }
            if (!audioLibraries.TryGetValue(processing.Leveling, out var library))
            {
                library = new LibVLC([.. BaseOptions, .. processing.Options]);
                audioLibraries.Add(processing.Leveling, library);
            }
            var available = library.AudioFilters.Select(filter => filter.Name).ToHashSet(StringComparer.Ordinal);
            if (processing.Filters.Any(filter => !available.Contains(filter)))
                throw new InvalidOperationException("Dialogue Boost or Volume Leveling is unavailable in this VLC installation. Install VLC’s equalizer and compressor filters, or turn these settings off.");
            var engine = new VlcVideoEngine(library, processing);
            if (!engine.ConfigureAudio(processing.Dialogue, recreateOutput: true))
            {
                engine.Dispose();
                throw new InvalidOperationException("The VLC equalizer could not apply Dialogue Boost.");
            }
            return engine;
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
    private readonly VolumeLeveling leveling;
    private Media? media;
    private PlaybackChapter[] chapterDescriptions = [];

    public VlcVideoEngine(LibVLC library, AudioProcessing? processing = null)
    {
        this.library = library;
        leveling = processing?.Leveling ?? VolumeLeveling.Off;
        player = new MediaPlayer(library);
        Frames.Attach(player);
        player.TimeChanged += (_, _) => Changed?.Invoke();
        player.LengthChanged += (_, _) => Changed?.Invoke();
        player.Playing += (_, _) => Changed?.Invoke();
        player.Paused += (_, _) => Changed?.Invoke();
        player.ESAdded += (_, _) => Changed?.Invoke();
        player.ESSelected += (_, _) => Changed?.Invoke();
        player.ChapterChanged += (_, _) => Changed?.Invoke();
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

    public IReadOnlyList<PlaybackChapter> Chapters
    {
        get
        {
            if (chapterDescriptions.Length == Math.Max(0, player.ChapterCount)) return chapterDescriptions;
            return chapterDescriptions = [.. player.FullChapterDescriptions(-1).Select((chapter, index) => new PlaybackChapter(index,
                string.IsNullOrWhiteSpace(chapter.Name) ? $"Chapter {index + 1}" : chapter.Name, Math.Max(0, chapter.TimeOffset)))];
        }
    }

    public int Chapter
    {
        get => player.Chapter;
        set => player.Chapter = value;
    }

    public void Open(Uri url, long startMilliseconds) => Open(url, startMilliseconds, paused: false);

    public void Open(Uri url, long startMilliseconds, bool paused)
    {
        chapterDescriptions = [];
        media?.Dispose();
        media = new Media(library, url);
        if (paused) media.AddOption(":start-paused");
        media.AddOption(":http-reconnect");
        media.AddOption(":avcodec-hw=vaapi_drm");
        if (url.IsLoopback) media.AddOption(":network-caching=300");
        if (startMilliseconds > 0) media.AddOption(":start-time=" + (startMilliseconds / 1000.0).ToString("0.000", CultureInfo.InvariantCulture));
        player.Play(media);
    }

    [LibraryImport("libvlccore.so.9", EntryPoint = "var_SetChecked", StringMarshalling = StringMarshalling.Utf8)]
    private static partial int SetPlayerString(nint player, string name, int type, nint value);

    public AudioChangeResult TrySetDialogueBoost(DialogueBoost mode)
    {
        if (mode != DialogueBoost.Off && !library.AudioFilters.Any(filter => filter.Name == "equalizer")) return AudioChangeResult.Unavailable;
        // The public EQ setter replaces the active output's whole filter list.
        // Reopen with both filters rather than silently losing compression.
        if (leveling != VolumeLeveling.Off) return AudioChangeResult.ReloadRequired;
        return ConfigureAudio(mode, recreateOutput: false) ? AudioChangeResult.Applied : AudioChangeResult.Unavailable;
    }

    internal bool ConfigureAudio(DialogueBoost mode, bool recreateOutput)
    {
        if (mode == DialogueBoost.Off)
        {
            if (!player.UnsetEqualizer()) return false;
        }
        else
        {
            if (!library.AudioFilters.Any(filter => filter.Name == "equalizer")) return false;
            using var equalizer = new Equalizer();
            if (equalizer.BandCount == 0) return false;
            var processing = new AudioProcessing(mode);
            if (!equalizer.SetPreamp(processing.Preamp)) return false;
            for (uint index = 0; index < equalizer.BandCount; index++)
            {
                var frequency = equalizer.BandFrequency(index);
                if (!float.IsFinite(frequency) || frequency <= 0 || !equalizer.SetAmp(processing.Gain(frequency), index)) return false;
            }
            if (!player.SetEqualizer(equalizer)) return false;
        }
        if (leveling == VolumeLeveling.Off) return true;
        // libVLC's equalizer setter replaces the player's audio-filter variable.
        // Restore the complete chain before opening a title. Live EQ is used only
        // with compression off, so it cannot erase another active filter.
        var chain = Marshal.StringToCoTaskMemUTF8(string.Join(':', new AudioProcessing(mode, leveling).Filters));
        try
        {
            if (SetPlayerString(player.NativeReference, "audio-filter", 0x0040, chain) != 0) return false;
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException) { return false; }
        finally { Marshal.FreeCoTaskMem(chain); }
        return !recreateOutput || (mode == DialogueBoost.Off && leveling == VolumeLeveling.Off) || player.SetAudioOutput("pulse");
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
