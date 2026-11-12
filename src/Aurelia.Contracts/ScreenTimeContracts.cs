namespace Aurelia.Contracts;

/// <summary>What closes when a children's profile's screen time is over.</summary>
public enum ScreenTimeLockScope { PlaybackOnly, WholeProfile }

/// <summary>What happens to a title that is playing when screen time ends.</summary>
public enum ScreenTimeEnding { FinishTitle, StopNow }

/// <summary>Open, the last title of the day (no Up Next), or closed until <see cref="ScreenTimeStatus.OpensAt"/>.</summary>
public enum ScreenTimeState { Open, LastTitle, Closed }

public enum ScreenTimeReason { None, Bedtime, Limit }

/// <summary>
/// One evening's rules. <paramref name="Bedtime"/> and <paramref name="WakeTime"/> are server-local "HH:mm";
/// <paramref name="WakeTime"/> is the next morning. A null bedtime or limit means none.
/// </summary>
public sealed record ScreenTimeDayRule(string? Bedtime, string WakeTime, int? DailyLimitMinutes);

/// <summary>
/// A children's profile's screen time. School nights are Sunday to Thursday evenings, the weekend is Friday and
/// Saturday evenings; a day runs from one wake time to the next and takes the rules of its evening.
/// </summary>
public sealed record ScreenTimeRules(bool Enabled, ScreenTimeLockScope LockScope, ScreenTimeEnding Ending,
    int MaxOvertimeMinutes, ScreenTimeDayRule SchoolNight, ScreenTimeDayRule Weekend)
{
    public static ScreenTimeRules Default { get; } = new(false, ScreenTimeLockScope.PlaybackOnly, ScreenTimeEnding.FinishTitle, 30,
        new("19:30", "07:00", null), new("20:30", "08:00", null));
}

/// <summary>What the parents allowed for today only; it ends at the next wake time.</summary>
public sealed record ScreenTimeToday(int ExtraMinutes, bool BedtimeLifted, bool OneMoreTitle, bool OneMoreTitleUsed);

/// <summary>
/// The profile's screen time now. <paramref name="ClosesAt"/> is when it will close if watching goes on without a
/// pause; <paramref name="TitleEndsBy"/> is when a title that is playing then must have ended.
/// <paramref name="OneMoreTitleAvailable"/> lets one more title start although the profile is closed.
/// </summary>
public sealed record ScreenTimeStatus(ScreenTimeState State, ScreenTimeReason Reason, int WatchedMinutesToday,
    int? LimitMinutes, int? RemainingMinutes, DateTimeOffset? ClosesAt, DateTimeOffset? TitleEndsBy, DateTimeOffset? OpensAt,
    ScreenTimeLockScope LockScope, ScreenTimeEnding Ending, bool OneMoreTitleAvailable)
{
    /// <summary>No new title may start, so clients show no Up Next and end with the good-night screen.</summary>
    public bool NoMoreTitles => State != ScreenTimeState.Open;
}

public sealed record ProfileScreenTimeResponse(ScreenTimeRules Rules, ScreenTimeToday Today, ScreenTimeStatus? Status, long Revision);
public sealed record UpdateProfileScreenTimeRequest(ScreenTimeRules Rules, long Revision);

/// <summary>An exception for today: more minutes, no bedtime tonight, or one more title. Fields that are 0 or false stay as they are.</summary>
public sealed record GrantScreenTimeRequest(int AddMinutes = 0, bool LiftBedtime = false, bool OneMoreTitle = false);

/// <summary>The active profile's own screen time; <paramref name="Status"/> is null when it has none.</summary>
public sealed record OwnScreenTimeResponse(ScreenTimeStatus? Status);

public static class ScreenTimeCodes
{
    /// <summary>A new title was refused: it is bedtime.</summary>
    public const string Bedtime = "screen_time_bedtime";
    /// <summary>A new title was refused: today's time is used up.</summary>
    public const string Limit = "screen_time_limit";
    /// <summary>The whole profile is closed until its wake time; contains "profile" so older clients end the profile session.</summary>
    public const string ProfileClosed = "profile_screen_time_closed";
}
