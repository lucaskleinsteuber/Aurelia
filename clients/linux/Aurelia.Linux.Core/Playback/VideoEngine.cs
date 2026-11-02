namespace Aurelia.Linux.Core.Playback;

/// <summary>An audio or subtitle track the decoder offers.</summary>
public sealed record MediaTrack(int Id, string Name, string? Language = null, bool IsForced = false);

public sealed record PlaybackChapter(int Index, string Title, long PositionMilliseconds);

public enum EngineEnd
{
    Ended,
    Failed,
}

/// <summary>
/// The video decoder as the player needs it. The app uses VLC; tests use a simulated engine that
/// goes through the same player logic and views. Events may arrive on any thread.
/// </summary>
public interface IVideoEngine : IDisposable
{
    /// <summary>Position, length, playing state or tracks changed.</summary>
    event Action? Changed;

    event Action<EngineEnd>? Finished;

    /// <summary>Opens <paramref name="url"/> directly at <paramref name="startMilliseconds"/> and starts playing.</summary>
    void Open(Uri url, long startMilliseconds);

    AudioChangeResult TrySetDialogueBoost(DialogueBoost mode) => AudioChangeResult.Unavailable;

    void Play();

    void Pause();

    /// <summary>Stops reading and releases the title.</summary>
    void Unload();

    void Seek(long milliseconds);

    /// <summary>Adds a subtitle file the server offers next to the video (a sidecar).</summary>
    void AddSubtitle(Uri url);

    long Time { get; }

    long Length { get; }

    bool IsPlaying { get; }

    double Rate { get; set; }

    /// <summary>0 to 100.</summary>
    int Volume { get; set; }

    bool Muted { get; set; }

    IReadOnlyList<MediaTrack> AudioTracks { get; }

    IReadOnlyList<MediaTrack> SubtitleTracks { get; }

    int AudioTrack { get; set; }

    /// <summary>-1 turns subtitles off.</summary>
    int SubtitleTrack { get; set; }

    IReadOnlyList<PlaybackChapter> Chapters { get; }

    int Chapter { get; set; }
}

public interface IVideoEngineFactory
{
    /// <summary>Night mode is part of a player's audio chain, so it is chosen when the player is made.</summary>
    IVideoEngine Create(bool nightMode);

    IVideoEngine Create(AudioProcessing processing) => Create(processing.Leveling != VolumeLeveling.Off);
}
