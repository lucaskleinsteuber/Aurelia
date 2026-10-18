namespace Aurelia.Desktop.Core;

/// <summary>An audio or subtitle track the decoder offers.</summary>
public sealed record MediaTrack(int Id, string Name);

public enum EngineEnd { Ended, Failed }

/// <summary>
/// The video decoder as the player needs it. The app uses VLC; tests use a scripted engine.
/// Events may arrive on any thread.
/// </summary>
public interface IVideoEngine : IDisposable
{
    event Action? Changed;
    event Action<EngineEnd>? Finished;

    /// <summary>Opens `url` directly at `startMilliseconds` and starts playing.</summary>
    void Open(Uri url, long startMilliseconds);
    void Play();
    void Pause();
    /// <summary>Stops reading and releases the title.</summary>
    void Unload();
    void Seek(long milliseconds);

    long Time { get; }
    long Length { get; }
    bool IsPlaying { get; }
    double Rate { get; set; }
    int Volume { get; set; }
    bool Muted { get; set; }
    IReadOnlyList<MediaTrack> AudioTracks { get; }
    IReadOnlyList<MediaTrack> SubtitleTracks { get; }
    int AudioTrack { get; set; }
    /// <summary>-1 turns subtitles off.</summary>
    int SubtitleTrack { get; set; }
}

public interface IVideoEngineFactory
{
    /// <summary>Night mode is part of a player's audio chain, so it is chosen when the player is made.</summary>
    IVideoEngine Create(bool nightMode);
}
