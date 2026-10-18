using Aurelia.Contracts;

namespace Aurelia.Server.Data;

/// <summary>Intro and credits timestamps for one playable title, shared by all profiles.</summary>
public sealed class MediaSegment
{
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;
    public long? IntroStartMilliseconds { get; set; }
    public long? IntroEndMilliseconds { get; set; }
    public long? CreditsStartMilliseconds { get; set; }
    public MediaSegmentSource Source { get; set; }
    public int AnalysisVersion { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}
