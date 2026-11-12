using Aurelia.Contracts;

namespace Aurelia.Server.Data;

/// <summary>A children's profile's screen time rules (see <see cref="ScreenTimeRules"/>).</summary>
public sealed class ScreenTimeRule
{
    public Guid UserId { get; set; }
    public ServerUser User { get; set; } = null!;
    public bool Enabled { get; set; }
    public ScreenTimeLockScope LockScope { get; set; }
    public ScreenTimeEnding Ending { get; set; }
    public int MaxOvertimeMinutes { get; set; }
    public string? SchoolBedtime { get; set; }
    public string SchoolWakeTime { get; set; } = "07:00";
    public int? SchoolLimitMinutes { get; set; }
    public string? WeekendBedtime { get; set; }
    public string WeekendWakeTime { get; set; } = "08:00";
    public int? WeekendLimitMinutes { get; set; }
    public long Revision { get; set; }
}

/// <summary>
/// One screen-time day of a profile, from one wake time to the next: the minutes watched and what the parents
/// allowed for that day only.
/// </summary>
public sealed class ScreenTimeDay
{
    public Guid UserId { get; set; }
    public ServerUser User { get; set; } = null!;
    public DateOnly Day { get; set; }
    public int WatchedSeconds { get; set; }
    public int ExtraMinutes { get; set; }
    public bool BedtimeLifted { get; set; }
    public bool OneMoreTitleGranted { get; set; }
    public bool OneMoreTitleUsed { get; set; }
    /// <summary>When the watched time first reached the limit; titles started before then may finish.</summary>
    public DateTimeOffset? LimitReachedAt { get; set; }
    /// <summary>The last progress report counted: watched time is the playing between two reports of one title.</summary>
    public Guid? LastMediaId { get; set; }
    public long LastPositionMilliseconds { get; set; }
    public DateTimeOffset? LastReportAt { get; set; }
}
