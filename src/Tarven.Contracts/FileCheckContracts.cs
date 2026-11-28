namespace Tarven.Contracts;

/// <summary>How thoroughly the file watch examines a file the first time ("file-checks-v1").</summary>
public enum FileCheckDepth
{
    /// <summary>Every byte is read once and a checksum is kept: finds unreadable places and later silent changes.</summary>
    Read,

    /// <summary>Also lets ffmpeg read every packet of every track: finds cut-off files and damaged packets.</summary>
    Container,

    /// <summary>Also decodes the picture and sound completely: finds damage inside packets. Slow on small computers.</summary>
    Decode,
}

/// <summary>What the file watch found in a file.</summary>
public enum FileCheckState
{
    Ok,

    /// <summary>A few errors right at the beginning, which many files have and which do not show.</summary>
    Notice,

    /// <summary>Damaged packets or pictures, or the file ends before its length.</summary>
    Damaged,

    /// <summary>The drive could not read part of the file.</summary>
    Unreadable,

    /// <summary>The checksum changed although size and modification time stayed the same.</summary>
    ChangedUnexpectedly,
}

/// <param name="Enabled">Whether files are examined in the background. Off until the owner turns it on.</param>
/// <param name="Depth">How thoroughly a new or changed file is examined.</param>
/// <param name="RecheckDays">After how many days every file's checksum is read again; 0 never.</param>
/// <param name="CanInspect">Whether ffmpeg is there for <see cref="FileCheckDepth.Container"/> and <see cref="FileCheckDepth.Decode"/>; without it only reading is possible.</param>
/// <param name="TotalCount">Files in the library that have a file (movies, episodes, extras, trailers).</param>
/// <param name="CheckedCount">Files examined in their current version.</param>
/// <param name="PendingCount">Files still to be examined, or whose checksum is due to be read again.</param>
/// <param name="ProblemCount">Files with a problem that was not set aside.</param>
/// <param name="CurrentTitle">The file being examined now, such as "Series · S01E02".</param>
/// <param name="CurrentStep">What is being done with it now.</param>
/// <param name="CurrentFraction">How far the current file is, from 0 to 1.</param>
/// <param name="EstimatedSecondsRemaining">Time left at this server's recent speed, once it is known.</param>
public sealed record FileCheckSettingsResponse(
    bool Enabled,
    FileCheckDepth Depth,
    int RecheckDays,
    bool CanInspect,
    int TotalCount,
    int CheckedCount,
    int PendingCount,
    int ProblemCount,
    bool Running,
    bool PausedForPlayback,
    string? CurrentTitle = null,
    string? CurrentStep = null,
    double? CurrentFraction = null,
    int? EstimatedSecondsRemaining = null,
    DateTimeOffset? LastCheckedAt = null);

/// <param name="Depth">Null keeps the current depth.</param>
/// <param name="RecheckDays">Null keeps the current rhythm; allowed are 0, 30, 90 and 180.</param>
public sealed record UpdateFileCheckSettingsRequest([property: System.Text.Json.Serialization.JsonRequired] bool Enabled, FileCheckDepth? Depth = null, int? RecheckDays = null);

/// <summary>A file the watch found a problem in, for Library Health.</summary>
/// <param name="ProblemAtSeconds">About where in the title the first problem is, when known.</param>
/// <param name="DurationSeconds">The title's length, when known.</param>
/// <param name="Detail">A short explanation; never a path.</param>
/// <param name="Ignored">Whether an administrator set it aside; it stays out of the problem count.</param>
public sealed record FileProblemSummary(
    Guid MediaId,
    string Title,
    MediaKind Kind,
    string FileName,
    string LibraryName,
    FileCheckState State,
    int ErrorCount,
    double? ProblemAtSeconds,
    double? DurationSeconds,
    string? Detail,
    FileCheckDepth Depth,
    DateTimeOffset CheckedAt,
    bool Ignored);

/// <summary>How a drive that holds a storage location is doing, as the drive reports it (SMART).</summary>
public enum DriveHealthState
{
    Good,
    Warning,
    Failing,

    /// <summary>The drive does not report its health here (USB enclosures, network shares, Docker).</summary>
    Unknown,
}

/// <param name="Name">The drive's model, or the volume's name.</param>
/// <param name="Libraries">The storage locations on this drive.</param>
/// <param name="TemperatureCelsius">The drive's temperature when it reports one.</param>
/// <param name="PowerOnHours">How long the drive has been running in all.</param>
/// <param name="BadSectors">Sectors the drive had to replace or could not read.</param>
/// <param name="Detail">A short explanation of the state.</param>
public sealed record DriveHealthSummary(
    string Name,
    IReadOnlyList<string> Libraries,
    DriveHealthState State,
    double? TemperatureCelsius,
    long? PowerOnHours,
    long? BadSectors,
    string? Detail);

/// <param name="CheckedAt">When the drives were last asked; values are what the drives last measured.</param>
public sealed record DriveHealthResponse(IReadOnlyList<DriveHealthSummary> Drives, DateTimeOffset? CheckedAt);
