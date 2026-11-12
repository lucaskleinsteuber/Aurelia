using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Bedtime, a daily limit and today's exceptions for children's profiles (docs/SCREEN_TIME.md). The server's
/// local time decides; only profiles without server access can have screen time.
/// </summary>
public sealed class ScreenTimeService(AureliaDbContext database, TimeProvider clock)
{
    /// <summary>A day's state as <see cref="Evaluate"/> needs it.</summary>
    public sealed record DayState(int WatchedSeconds = 0, int ExtraMinutes = 0, bool BedtimeLifted = false,
        bool OneMoreTitleGranted = false, bool OneMoreTitleUsed = false, DateTimeOffset? LimitReachedAt = null);

    /// <summary>How long before closing the player calls a title the last one and stops offering the next.</summary>
    public static readonly TimeSpan LastTitleWindow = TimeSpan.FromMinutes(5);

    /// <summary>A watched interval between two progress reports counts at most this long.</summary>
    public static readonly TimeSpan MaximumReportInterval = TimeSpan.FromSeconds(90);

    public const int MaximumExtraMinutesPerDay = 600;

    private TimeZoneInfo Zone => clock.LocalTimeZone;

    // ---- Rules -------------------------------------------------------------------------------------------

    /// <summary>The rules of a Friday or Saturday evening are the weekend's; every other evening is a school night.</summary>
    public static ScreenTimeDayRule RuleFor(ScreenTimeRules rules, DateOnly evening) =>
        evening.DayOfWeek is DayOfWeek.Friday or DayOfWeek.Saturday ? rules.Weekend : rules.SchoolNight;

    /// <summary>The screen-time day <paramref name="now"/> belongs to: from the wake time of its morning to the next.</summary>
    public static DateOnly DayOf(ScreenTimeRules rules, DateTimeOffset now, TimeZoneInfo zone)
    {
        var date = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, zone).DateTime);
        var wake = At(date, Time(RuleFor(rules, date.AddDays(-1)).WakeTime) ?? new TimeOnly(7, 0), zone);
        return now < wake ? date.AddDays(-1) : date;
    }

    /// <summary>The state of a profile with <paramref name="rules"/> on day <paramref name="date"/> at <paramref name="now"/>.</summary>
    public static ScreenTimeStatus Evaluate(ScreenTimeRules rules, DayState day, DateOnly date, DateTimeOffset now, TimeZoneInfo zone)
    {
        var rule = RuleFor(rules, date);
        var morning = Time(RuleFor(rules, date.AddDays(-1)).WakeTime) ?? new TimeOnly(7, 0);
        var opensAt = At(date.AddDays(1), Time(rule.WakeTime) ?? new TimeOnly(7, 0), zone);
        var extra = TimeSpan.FromMinutes(day.ExtraMinutes);
        DateTimeOffset? bedtime = null;
        if (!day.BedtimeLifted && Time(rule.Bedtime) is { } clockTime)
        {
            // A bedtime before the morning's wake time ("00:30") is after midnight.
            var instant = At(clockTime < morning ? date.AddDays(1) : date, clockTime, zone) + extra;
            bedtime = instant < opensAt ? instant : opensAt;
        }
        int? limit = rule.DailyLimitMinutes is { } minutes ? minutes + day.ExtraMinutes : null;
        int? remainingSeconds = limit is { } total ? Math.Max(0, total * 60 - day.WatchedSeconds) : null;
        var overtime = rules.Ending == ScreenTimeEnding.FinishTitle ? TimeSpan.FromMinutes(rules.MaxOvertimeMinutes) : TimeSpan.Zero;
        var oneMore = day.OneMoreTitleGranted && !day.OneMoreTitleUsed;
        var watchedMinutes = day.WatchedSeconds / 60;

        DateTimeOffset? closedAt = null;
        var reason = ScreenTimeReason.None;
        if (bedtime is { } bed && now >= bed) (closedAt, reason) = (bed, ScreenTimeReason.Bedtime);
        if (remainingSeconds == 0)
        {
            var reached = day.LimitReachedAt ?? now;
            if (closedAt is null || reached < closedAt) (closedAt, reason) = (reached, ScreenTimeReason.Limit);
        }
        if (closedAt is { } closed)
            return new(ScreenTimeState.Closed, reason, watchedMinutes, limit, 0, closed, closed + overtime, opensAt,
                rules.LockScope, rules.Ending, oneMore);

        DateTimeOffset? closesAt = bedtime;
        var upcoming = bedtime is null ? ScreenTimeReason.None : ScreenTimeReason.Bedtime;
        if (remainingSeconds is { } seconds && (closesAt is null || now.AddSeconds(seconds) < closesAt))
            (closesAt, upcoming) = (now.AddSeconds(seconds), ScreenTimeReason.Limit);
        var last = closesAt is { } at && at - now <= LastTitleWindow;
        return new(last ? ScreenTimeState.LastTitle : ScreenTimeState.Open, last ? upcoming : ScreenTimeReason.None,
            watchedMinutes, limit, remainingSeconds is { } left ? (left + 59) / 60 : null, closesAt,
            closesAt + overtime, last ? opensAt : null, rules.LockScope, rules.Ending, oneMore);
    }

    public static TimeOnly? Time(string? value) =>
        TimeOnly.TryParseExact(value, "HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out var time) ? time : null;

    private static DateTimeOffset At(DateOnly date, TimeOnly time, TimeZoneInfo zone)
    {
        var local = date.ToDateTime(time);
        // The hour skipped when clocks go forward does not exist; take the next one.
        if (zone.IsInvalidTime(local)) local = local.AddHours(1);
        return new DateTimeOffset(local, zone.GetUtcOffset(local));
    }

    public static ScreenTimeRules ToRules(ScreenTimeRule row) => new(row.Enabled, row.LockScope, row.Ending, row.MaxOvertimeMinutes,
        new(row.SchoolBedtime, row.SchoolWakeTime, row.SchoolLimitMinutes), new(row.WeekendBedtime, row.WeekendWakeTime, row.WeekendLimitMinutes));

    private static DayState ToState(ScreenTimeDay? day) => day is null ? new()
        : new(day.WatchedSeconds, day.ExtraMinutes, day.BedtimeLifted, day.OneMoreTitleGranted, day.OneMoreTitleUsed, day.LimitReachedAt);

    // ---- Status ------------------------------------------------------------------------------------------

    private async Task<ScreenTimeRules?> ActiveRulesAsync(Guid userId, CancellationToken token)
    {
        var row = await database.ScreenTimeRules.AsNoTracking()
            .Where(rule => rule.UserId == userId && rule.Enabled && rule.User.Role == UserRole.User)
            .SingleOrDefaultAsync(token);
        return row is null ? null : ToRules(row);
    }

    private Task<ScreenTimeDay?> DayAsync(Guid userId, DateOnly date, CancellationToken token) =>
        database.ScreenTimeDays.SingleOrDefaultAsync(day => day.UserId == userId && day.Day == date, token);

    private async Task<ScreenTimeDay> TrackedDayAsync(Guid userId, DateOnly date, CancellationToken token)
    {
        var day = database.ScreenTimeDays.Local.SingleOrDefault(day => day.UserId == userId && day.Day == date)
            ?? await DayAsync(userId, date, token);
        if (day is null)
        {
            day = new ScreenTimeDay { UserId = userId, Day = date };
            database.ScreenTimeDays.Add(day);
        }
        return day;
    }

    /// <summary>The profile's screen time now, or null when it has none.</summary>
    public async Task<ScreenTimeStatus?> StatusAsync(Guid userId, CancellationToken token)
    {
        if (await ActiveRulesAsync(userId, token) is not { } rules) return null;
        var now = clock.GetUtcNow();
        var date = DayOf(rules, now, Zone);
        return Evaluate(rules, ToState(await database.ScreenTimeDays.AsNoTracking()
            .SingleOrDefaultAsync(day => day.UserId == userId && day.Day == date, token)), date, now, Zone);
    }

    /// <summary>The time screen time goes by.</summary>
    public DateTimeOffset Now => clock.GetUtcNow();

    /// <summary>
    /// Counts watched time from a progress report: the playing since the last report of the same title, no
    /// longer than the time between them (a pause or a jump forward does not count). The caller's save stores it.
    /// </summary>
    public async Task RecordProgressAsync(Guid userId, Guid mediaId, long positionMilliseconds, CancellationToken token)
    {
        if (await ActiveRulesAsync(userId, token) is not { } rules) return;
        var now = clock.GetUtcNow();
        var date = DayOf(rules, now, Zone);
        var day = await TrackedDayAsync(userId, date, token);
        if (day.LastMediaId == mediaId && day.LastReportAt is { } last && positionMilliseconds > day.LastPositionMilliseconds)
        {
            var played = TimeSpan.FromMilliseconds(positionMilliseconds - day.LastPositionMilliseconds);
            var elapsed = now - last;
            var counted = new[] { played, elapsed, MaximumReportInterval }.Min();
            if (counted > TimeSpan.Zero) day.WatchedSeconds = checked(day.WatchedSeconds + (int)Math.Round(counted.TotalSeconds));
        }
        (day.LastMediaId, day.LastPositionMilliseconds, day.LastReportAt) = (mediaId, positionMilliseconds, now);
        if (day.LimitReachedAt is null && RuleFor(rules, date).DailyLimitMinutes is { } limit
            && day.WatchedSeconds >= (limit + day.ExtraMinutes) * 60)
            day.LimitReachedAt = now;
    }

    /// <summary>
    /// Allows a new title or refuses it. A title that already played before closing may start again (for
    /// example after a lost connection) until it must have ended; "one more title" is used up here. Returns
    /// the status to give the player and, for one more title, when it must have ended.
    /// </summary>
    public async Task<(ScreenTimeStatus? Status, DateTimeOffset? ExtraEndsAt)> AdmitTitleAsync(Guid userId, Guid mediaId, CancellationToken token)
    {
        if (await ActiveRulesAsync(userId, token) is not { } rules) return (null, null);
        var now = clock.GetUtcNow();
        var date = DayOf(rules, now, Zone);
        var row = await DayAsync(userId, date, token);
        var status = Evaluate(rules, ToState(row), date, now, Zone);
        if (status.State != ScreenTimeState.Closed) return (status, null);
        var earlier = await database.PlaybackTickets.IgnoreQueryFilters().AsNoTracking()
            .Where(ticket => ticket.UserId == userId && ticket.MediaItemId == mediaId && ticket.RevokedAt == null)
            .Select(ticket => new { ticket.CreatedAt, ticket.ScreenTimeExtraEndsAt }).ToListAsync(token);
        if (earlier.Select(ticket => ticket.ScreenTimeExtraEndsAt).Where(end => end > now).Max() is { } extraEnd)
            return (status with { TitleEndsBy = extraEnd }, extraEnd);
        // A new ticket for the title that was already playing (a renewal or a lost connection) may stream as long
        // as that title may still finish.
        if (rules.Ending == ScreenTimeEnding.FinishTitle && now < status.TitleEndsBy && earlier.Any(ticket => ticket.CreatedAt < status.ClosesAt))
            return (status, status.TitleEndsBy);
        if (status.OneMoreTitleAvailable)
        {
            row!.OneMoreTitleUsed = true;
            var ends = now + await RuntimeAsync(userId, mediaId, token) + TimeSpan.FromMinutes(15);
            return (status with { OneMoreTitleAvailable = false, TitleEndsBy = ends }, ends);
        }
        throw status.Reason == ScreenTimeReason.Limit
            ? new PlaybackException(ScreenTimeCodes.Limit, $"That's all for today. Aurelia opens again at {LocalClock(status.OpensAt)}.", 403)
            : new PlaybackException(ScreenTimeCodes.Bedtime, $"It's bedtime. Aurelia opens again at {LocalClock(status.OpensAt)}.", 403);
    }

    private async Task<TimeSpan> RuntimeAsync(Guid userId, Guid mediaId, CancellationToken token)
    {
        var reported = await database.PlaybackProgress.IgnoreQueryFilters().AsNoTracking()
            .Where(progress => progress.UserId == userId && progress.MediaItemId == mediaId)
            .Select(progress => (long?)progress.DurationMilliseconds).SingleOrDefaultAsync(token);
        if (reported is > 0) return TimeSpan.FromMilliseconds(reported.Value);
        var minutes = await database.MediaMetadata.IgnoreQueryFilters().AsNoTracking().Where(metadata => metadata.MediaItemId == mediaId)
            .Select(metadata => metadata.ManualRuntimeMinutes ?? metadata.ProviderRuntimeMinutes).SingleOrDefaultAsync(token);
        return TimeSpan.FromMinutes(minutes is > 0 ? minutes.Value : 120);
    }

    /// <summary>Whether a ticket's title may still stream: always while open, and after closing only as long as it may finish.</summary>
    public async Task<bool> StreamAllowedAsync(Guid userId, DateTimeOffset ticketCreatedAt, DateTimeOffset? extraEndsAt, CancellationToken token)
    {
        if (await StatusAsync(userId, token) is not { State: ScreenTimeState.Closed } status) return true;
        var now = clock.GetUtcNow();
        if (extraEndsAt > now) return true;
        return status.Ending == ScreenTimeEnding.FinishTitle && ticketCreatedAt < status.ClosesAt && now < status.TitleEndsBy;
    }

    /// <summary>When a whole-profile lock keeps this profile closed, the time it opens again.</summary>
    public async Task<DateTimeOffset?> ProfileClosedUntilAsync(Guid userId, CancellationToken token)
    {
        if (await StatusAsync(userId, token) is not { State: ScreenTimeState.Closed, LockScope: ScreenTimeLockScope.WholeProfile, OneMoreTitleAvailable: false } status)
            return null;
        var now = clock.GetUtcNow();
        return await database.PlaybackTickets.IgnoreQueryFilters().AnyAsync(ticket => ticket.UserId == userId && ticket.RevokedAt == null
            && ticket.ScreenTimeExtraEndsAt != null && ticket.ScreenTimeExtraEndsAt > now, token) ? null : status.OpensAt;
    }

    public string LocalClock(DateTimeOffset? instant) =>
        instant is { } value ? TimeZoneInfo.ConvertTime(value, Zone).ToString("HH:mm", CultureInfo.InvariantCulture) : "";

    // ---- Parents -----------------------------------------------------------------------------------------

    public async Task<ProfileScreenTimeResponse> ProfileAsync(Guid userId, CancellationToken token)
    {
        var user = await database.Users.IgnoreQueryFilters().AsNoTracking().SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        var row = await database.ScreenTimeRules.AsNoTracking().SingleOrDefaultAsync(rule => rule.UserId == userId, token);
        var rules = row is null ? ScreenTimeRules.Default : ToRules(row);
        var now = clock.GetUtcNow();
        var date = DayOf(rules, now, Zone);
        var day = ToState(await database.ScreenTimeDays.AsNoTracking().SingleOrDefaultAsync(day => day.UserId == userId && day.Day == date, token));
        var status = rules.Enabled && user.Role == UserRole.User ? Evaluate(rules, day, date, now, Zone) : null;
        return new(rules, new(day.ExtraMinutes, day.BedtimeLifted, day.OneMoreTitleGranted, day.OneMoreTitleUsed), status, row?.Revision ?? 0);
    }

    public async Task<ProfileScreenTimeResponse> UpdateAsync(Guid userId, UpdateProfileScreenTimeRequest request, CancellationToken token)
    {
        var rules = request.Rules ?? throw Invalid("Choose the screen time rules.");
        Validate(rules);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        if (rules.Enabled && user.Role != UserRole.User)
            throw new AccountException("screen_time_role", "Only profiles without server access can have screen time.", 400);
        var row = await database.ScreenTimeRules.SingleOrDefaultAsync(rule => rule.UserId == userId, token);
        if ((row?.Revision ?? 0) != request.Revision)
            throw new AccountException("screen_time_conflict", "Screen time changed on another device. Reload before saving.", 409);
        if (row is null)
        {
            row = new ScreenTimeRule { UserId = userId };
            database.ScreenTimeRules.Add(row);
        }
        row.Enabled = rules.Enabled;
        row.LockScope = rules.LockScope;
        row.Ending = rules.Ending;
        row.MaxOvertimeMinutes = rules.MaxOvertimeMinutes;
        (row.SchoolBedtime, row.SchoolWakeTime, row.SchoolLimitMinutes) = (Clean(rules.SchoolNight.Bedtime), rules.SchoolNight.WakeTime, rules.SchoolNight.DailyLimitMinutes);
        (row.WeekendBedtime, row.WeekendWakeTime, row.WeekendLimitMinutes) = (Clean(rules.Weekend.Bedtime), rules.Weekend.WakeTime, rules.Weekend.DailyLimitMinutes);
        row.Revision++;
        Changed(userId);
        await database.SaveChangesAsync(token);
        return await ProfileAsync(userId, token);
    }

    public async Task<ProfileScreenTimeResponse> GrantAsync(Guid userId, GrantScreenTimeRequest request, CancellationToken token)
    {
        if (request.AddMinutes is < 0 or > 240) throw Invalid("Add between 1 and 240 minutes.");
        if (await ActiveRulesAsync(userId, token) is not { } rules)
            throw new AccountException("screen_time_off", "This profile has no screen time.", 409);
        var date = DayOf(rules, clock.GetUtcNow(), Zone);
        var day = await TrackedDayAsync(userId, date, token);
        if (day.ExtraMinutes + request.AddMinutes > MaximumExtraMinutesPerDay) throw Invalid("Today already has the most extra time.");
        day.ExtraMinutes += request.AddMinutes;
        if (request.AddMinutes > 0 && day.LimitReachedAt is not null) day.LimitReachedAt = null;
        if (request.LiftBedtime) day.BedtimeLifted = true;
        if (request.OneMoreTitle) (day.OneMoreTitleGranted, day.OneMoreTitleUsed) = (true, false);
        Changed(userId);
        await database.SaveChangesAsync(token);
        return await ProfileAsync(userId, token);
    }

    private void Changed(Guid userId) =>
        database.SyncChanges.Add(new SyncChange { UserId = userId, Area = SyncChangeArea.UserState, CreatedAt = clock.GetUtcNow() });

    private static string? Clean(string? bedtime) => string.IsNullOrWhiteSpace(bedtime) ? null : bedtime;

    private static void Validate(ScreenTimeRules rules)
    {
        if (!Enum.IsDefined(rules.LockScope) || !Enum.IsDefined(rules.Ending)) throw Invalid("Choose what closes and how a title ends.");
        if (rules.MaxOvertimeMinutes is < 0 or > 180) throw Invalid("A title may run over by 0 to 180 minutes.");
        foreach (var rule in new[] { rules.SchoolNight, rules.Weekend })
        {
            if (rule is null || Time(rule.WakeTime) is null) throw Invalid("Enter a wake time like 07:00.");
            if (!string.IsNullOrWhiteSpace(rule.Bedtime) && Time(rule.Bedtime) is null) throw Invalid("Enter a bedtime like 19:30.");
            if (rule.DailyLimitMinutes is < 5 or > 1440) throw Invalid("A daily limit is 5 minutes to 24 hours.");
        }
    }

    private static AccountException Invalid(string message) => new("invalid_screen_time", message, 400);
}
