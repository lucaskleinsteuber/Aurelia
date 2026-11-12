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
/// <param name="CanAnalyze">Whether the server examines the title: an episode of a series, or a movie (since 2.11.0).</param>
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
/// <param name="UsePictures">Whether credits are also looked for in pictures (since 2.10.0).</param>
/// <param name="TotalCount">Episodes the server can compare: examined or still to examine.</param>
/// <param name="CurrentTitle">The episode being examined now, such as "Series · S01E02".</param>
/// <param name="CurrentStep">What is being done with it now.</param>
/// <param name="EstimatedSecondsRemaining">Time left at this server's recent speed, once it is known.</param>
/// <param name="MovieCount">Movies the server examines for credits (since 2.11.0; the counts above are episodes).</param>
/// <param name="MoviesWithCredits">Movies with a credits time.</param>
/// <param name="MoviesPendingCount">Movies still to be examined.</param>
public sealed record MediaSegmentSettingsResponse(
    bool Available,
    bool Enabled,
    int PendingCount,
    int AnalyzedCount,
    int NoResultCount,
    bool Running,
    bool PausedForPlayback,
    bool UsePictures = true,
    int TotalCount = 0,
    string? CurrentTitle = null,
    string? CurrentStep = null,
    int? EstimatedSecondsRemaining = null,
    int MovieCount = 0,
    int MoviesWithCredits = 0,
    int MoviesPendingCount = 0);

/// <param name="UsePictures">Null keeps the current choice.</param>
public sealed record UpdateMediaSegmentSettingsRequest(bool Enabled, bool? UsePictures = null);

/// <summary>One series' detection state for the owner's overview.</summary>
public sealed record MediaSegmentSeriesStatus(
    Guid SeriesId,
    string Title,
    int EpisodeCount,
    int WithIntro,
    int WithCredits,
    int PendingCount);

/// <summary>Examines a series, one of its seasons, or with no series the whole library again.</summary>
/// <param name="Movies">Without a series: only movies (true), only episodes (false), or both (null; since 2.11.0).</param>
public sealed record ReanalyzeMediaSegmentsRequest(Guid? SeriesId = null, int? SeasonNumber = null, bool? Movies = null);
