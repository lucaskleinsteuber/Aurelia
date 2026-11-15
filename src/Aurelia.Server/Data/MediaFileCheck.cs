using Aurelia.Contracts;

namespace Aurelia.Server.Data;

/// <summary>
/// What the file watch found in one title's file, in the file version (size and modification time)
/// it examined. Only the checksum, the finding and a short explanation without paths are stored;
/// the media file is only ever read.
/// </summary>
public sealed class MediaFileCheck
{
    public Guid MediaItemId { get; set; }
    public MediaItem MediaItem { get; set; } = null!;

    /// <summary>The file version that was examined; another version is examined again.</summary>
    public long FileSize { get; set; }
    public DateTimeOffset FileModifiedAt { get; set; }

    /// <summary>The SHA-256 of the whole file, read in full; null when the file could not be read to its end.</summary>
    public byte[]? Sha256 { get; set; }

    /// <summary>How thoroughly this version was examined.</summary>
    public FileCheckDepth Depth { get; set; }
    public FileCheckState State { get; set; }
    public int ErrorCount { get; set; }
    public long? ProblemAtMilliseconds { get; set; }
    public long? DurationMilliseconds { get; set; }
    public string? Detail { get; set; }

    /// <summary>Set aside by an administrator; a new file version clears it.</summary>
    public bool Ignored { get; set; }

    /// <summary>When this version was examined.</summary>
    public DateTimeOffset CheckedAt { get; set; }

    /// <summary>When the checksum was last read and compared.</summary>
    public DateTimeOffset VerifiedAt { get; set; }
}
