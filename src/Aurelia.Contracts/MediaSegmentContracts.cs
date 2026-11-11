namespace Aurelia.Contracts;

/// <summary>Where an intro or credits time came from.</summary>
public enum MediaSegmentSource
{
    /// <summary>Nothing certain was found, or the title was not examined yet.</summary>
    None,
    Chapters,
    Detected,
    Manual,
}

/// <summary>
/// Intro and credits times of the title being played, in milliseconds from its start. Sent with
/// the playback ticket ("media-segments-v2"); a missing value means there is nothing to skip.
/// </summary>
public sealed record MediaSegmentsDto(
    long? IntroStartMilliseconds,
    long? IntroEndMilliseconds,
    long? CreditsStartMilliseconds);

/// <summary>
/// One title's intro and credits times with their origin. Only these timestamps are stored; no
/// audio, images or fingerprints are kept.
/// </summary>
/// <param name="Analyzed">Whether the server has examined this title in its current file version.</param>
/// <param name="CanAnalyze">Whether the title is an episode the server compares with its season.</param>
public sealed record MediaSegmentsResponse(
    Guid MediaId,
    bool Analyzed,
    bool CanAnalyze,
    long? IntroStartMilliseconds,
    long? IntroEndMilliseconds,
    MediaSegmentSource IntroSource,
    double IntroConfidence,
    long? CreditsStartMilliseconds,
    MediaSegmentSource CreditsSource,
    double CreditsConfidence);

/// <summary>Times set by hand. A part that differs from what is stored becomes a manual correction.</summary>
public sealed record SetMediaSegmentsRequest(
    long? IntroStartMilliseconds,
    long? IntroEndMilliseconds,
    long? CreditsStartMilliseconds);

/// <param name="Available">Whether the server has an ffmpeg that can read sound.</param>
/// <param name="Enabled">Whether episodes are examined in the background.</param>
/// <param name="PendingCount">Episodes still to be examined.</param>
/// <param name="AnalyzedCount">Episodes with an intro or credits time.</param>
/// <param name="NoResultCount">Episodes examined without a certain result.</param>
public sealed record MediaSegmentSettingsResponse(
    bool Available,
    bool Enabled,
    int PendingCount,
    int AnalyzedCount,
    int NoResultCount,
    bool Running,
    bool PausedForPlayback);

public sealed record UpdateMediaSegmentSettingsRequest(bool Enabled);

/// <summary>Examines a series, one of its seasons, or with no series the whole library again.</summary>
public sealed record ReanalyzeMediaSegmentsRequest(Guid? SeriesId = null, int? SeasonNumber = null);
