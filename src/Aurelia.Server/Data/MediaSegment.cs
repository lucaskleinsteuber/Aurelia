using Aurelia.Contracts;

namespace Aurelia.Server.Data;

/// <summary>
/// Intro and credits timestamps of one episode, shared by all profiles. Only times are stored:
/// never audio, images or fingerprints.
/// </summary>
public sealed class MediaSegment
{
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;
    public long? IntroStartMilliseconds { get; set; }
    public long? IntroEndMilliseconds { get; set; }
    public MediaSegmentSource IntroSource { get; set; }
    public double IntroConfidence { get; set; }
    public long? CreditsStartMilliseconds { get; set; }
    public MediaSegmentSource CreditsSource { get; set; }
    public double CreditsConfidence { get; set; }

    /// <summary>The detection rules that produced these times; 0 asks for a new analysis.</summary>
    public int AnalysisVersion { get; set; }

    /// <summary>The file's size and modification time when it was analyzed; a changed file is analyzed again.</summary>
    public long? AnalyzedFileSize { get; set; }
    public DateTimeOffset? AnalyzedFileModifiedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}
