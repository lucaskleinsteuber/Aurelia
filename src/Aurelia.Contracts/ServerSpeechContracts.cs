namespace Aurelia.Contracts;

/// <summary>A speech model the server can download for its recognizer (whisper.cpp).</summary>
/// <param name="Name">"base", "small" or "medium".</param>
/// <param name="Bytes">Its size on disk once downloaded.</param>
public sealed record SpeechModelChoice(string Name, string Label, long Bytes, string Description);

/// <summary>The model download in progress.</summary>
public sealed record SpeechModelDownload(string Name, long ReceivedBytes, long TotalBytes);

/// <summary>
/// Settings › Server › Speech Recognition for the owner ("server-speech-v1"). Without a recognizer
/// (<see cref="Available"/> false) or a model, subtitles from speech aren't offered by the server.
/// </summary>
/// <param name="Available">Whether whisper.cpp is installed beside the server.</param>
/// <param name="Model">The downloaded model's name, or null.</param>
/// <param name="ModelBytes">The downloaded model's size, 0 without one.</param>
public sealed record ServerSpeechSettings(
    bool Available,
    string? Model,
    long ModelBytes,
    SpeechModelDownload? Downloading,
    string? DownloadError,
    IReadOnlyList<SpeechModelChoice> Models,
    IReadOnlyList<SpeechJobStatus> Jobs);

public sealed record DownloadSpeechModelRequest(string Name);

/// <summary>What a speech job does: write subtitles from speech, or move existing ones onto it.</summary>
public enum SpeechJobKind
{
    Create,
    Sync,
}

public enum SpeechJobState
{
    Waiting,
    Listening,
    Saving,
    /// <summary>Saved; <see cref="SpeechJobStatus.SubtitleId"/> names the new subtitles.</summary>
    Done,
    /// <summary>Syncing found the subtitles already fit; nothing was saved.</summary>
    AlreadyInSync,
    Failed,
    Cancelled,
}

/// <summary>
/// One title's speech job.
/// </summary>
/// <param name="Language">The spoken language (two letters) the subtitles are written in.</param>
/// <param name="SubtitleIndex">For syncing: the subtitle track (as in the stream's list) that is moved.</param>
/// <param name="Progress">Share of the sound heard, 0 to 1.</param>
/// <param name="Message">What happened, such as "Moved 2.4 s later. Fits 88 % of the speech (was 31 %)."</param>
public sealed record SpeechJobStatus(
    Guid MediaId,
    string Title,
    SpeechJobKind Kind,
    string Language,
    int? SubtitleIndex,
    SpeechJobState State,
    double Progress,
    bool PausedForPlayback,
    string? Message,
    Guid? SubtitleId);

/// <summary>A title's speech state: whether the server can listen, and its job if it has one.</summary>
public sealed record MediaSpeechResponse(bool Available, bool ModelReady, SpeechJobStatus? Job);

/// <param name="AudioIndex">The sound track to listen to; null takes the default one.</param>
public sealed record StartSpeechJobRequest(SpeechJobKind Kind, string Language, int? AudioIndex = null, int? SubtitleIndex = null);
