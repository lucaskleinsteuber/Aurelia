namespace Aurelia.Contracts;

/// <summary>Where a title's intro and credits times came from.</summary>
public enum MediaSegmentSource
{
    /// <summary>The title was examined and has no intro or credits to skip.</summary>
    None,
    Chapters,
    Detected,
    Manual,
}

/// <summary>
/// Intro and credits times for one playable title. Only these timestamps are stored; no audio,
/// images or fingerprints are kept.
/// </summary>
public sealed record MediaSegmentsResponse(
    Guid MediaId, bool Analyzed, long? IntroStartMilliseconds, long? IntroEndMilliseconds,
    long? CreditsStartMilliseconds, MediaSegmentSource Source, int AnalysisVersion);

public sealed record SetMediaSegmentsRequest(
    long? IntroStartMilliseconds, long? IntroEndMilliseconds, long? CreditsStartMilliseconds,
    MediaSegmentSource Source, int AnalysisVersion);

public sealed record MediaSegmentAnalysisItem(Guid MediaId, int? EpisodeNumber, bool NeedsAnalysis);

/// <summary>A season (or a single movie) whose titles are compared with each other.</summary>
public sealed record MediaSegmentAnalysisGroup(
    Guid? SeriesId, int? SeasonNumber, IReadOnlyList<MediaSegmentAnalysisItem> Items);

public sealed record MediaSegmentAnalysisQueueResponse(IReadOnlyList<MediaSegmentAnalysisGroup> Groups);
