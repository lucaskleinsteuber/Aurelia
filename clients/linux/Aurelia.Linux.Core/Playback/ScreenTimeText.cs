using System.Globalization;
using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Playback;

/// <summary>
/// What the app shows for a children's profile's screen time (docs/SCREEN_TIME.md): the server decides; the
/// player ends with a good-night screen, "Who's watching?" shows a closed profile, and parents see today's line.
/// </summary>
public static class ScreenTimeText
{
    /// <summary>The player asks the server this often while a title plays.</summary>
    public static readonly TimeSpan RefreshInterval = TimeSpan.FromSeconds(60);

    public static bool IsScreenTimeCode(string? code) =>
        code is ScreenTimeCodes.Bedtime or ScreenTimeCodes.Limit or ScreenTimeCodes.ProfileClosed;

    /// <summary>"07:00" in this computer's clock, or "" without a time.</summary>
    public static string Clock(DateTimeOffset? value, TimeZoneInfo? zone = null) =>
        value is { } instant ? TimeZoneInfo.ConvertTime(instant, zone ?? TimeZoneInfo.Local).ToString("HH:mm", CultureInfo.InvariantCulture) : "";

    /// <summary>The good-night screen's heading and line.</summary>
    public static (string Title, string Text) GoodNight(ScreenTimeStatus? status, string? name, TimeZoneInfo? zone = null)
    {
        var who = (name ?? "").Trim();
        var opens = Clock(status?.OpensAt, zone);
        if (status?.Reason == ScreenTimeReason.Limit)
            return (who.Length == 0 ? "That's all for today" : $"That's all for today, {who}",
                opens.Length == 0 ? "See you tomorrow." : $"See you tomorrow at {opens}.");
        return (who.Length == 0 ? "Good night" : $"Good night, {who}", opens.Length == 0 ? "Sleep well." : $"See you at {opens}.");
    }

    /// <summary>The quiet note while the last title of the day plays.</summary>
    public static string LastTitleNote(ScreenTimeStatus? status) =>
        status?.Reason == ScreenTimeReason.Limit ? "This is the last title for today." : "This is the last episode before bedtime.";

    /// <summary>"Good night · back at 07:00" for a closed profile in "Who's watching?", null when it is open.</summary>
    public static string? ClosedLabel(DateTimeOffset? until, TimeZoneInfo? zone = null) =>
        until is null ? null : $"Good night · back at {Clock(until, zone)}";

    /// <summary>"42 of 60 min watched today · Closes at 19:30" for the parents' "Today" line.</summary>
    public static string TodaySummary(ScreenTimeStatus? status, TimeZoneInfo? zone = null)
    {
        if (status is null) return "Screen time is off.";
        var watched = status.LimitMinutes is { } limit
            ? $"{status.WatchedMinutesToday} of {limit} min watched today"
            : $"{status.WatchedMinutesToday} min watched today";
        if (status.State == ScreenTimeState.Closed)
        {
            var opens = Clock(status.OpensAt, zone);
            var why = status.Reason == ScreenTimeReason.Limit ? "Time is up" : "Bedtime";
            return $"{watched} · {why}{(opens.Length == 0 ? "" : $", opens at {opens}")}{(status.OneMoreTitleAvailable ? " · One more title allowed" : "")}";
        }
        var closes = Clock(status.ClosesAt, zone);
        return closes.Length == 0 ? watched : $"{watched} · Closes at {closes}";
    }

    /// <summary>"HH:mm" for a time field, null when it is not a valid time.</summary>
    public static string? Time(string? value) =>
        TimeOnly.TryParseExact((value ?? "").Trim(), "HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out var time)
            ? time.ToString("HH:mm", CultureInfo.InvariantCulture) : null;

    /// <summary>The first problem in edited rules, or null when the server will accept them.</summary>
    public static string? Problem(ScreenTimeRules rules)
    {
        ArgumentNullException.ThrowIfNull(rules);
        foreach (var (label, rule) in new[] { ("school-night", rules.SchoolNight), ("weekend", rules.Weekend) })
        {
            if (!string.IsNullOrWhiteSpace(rule.Bedtime) && Time(rule.Bedtime) is null) return $"Enter the {label} bedtime like 19:30.";
            if (Time(rule.WakeTime) is null) return $"Enter the {label} wake time like 07:00.";
            if (rule.DailyLimitMinutes is < 5 or > 1440) return $"The {label} daily limit is 5 to 1440 minutes.";
        }
        return rules.MaxOvertimeMinutes is < 0 or > 180 ? "A title may run over by 0 to 180 minutes." : null;
    }
}
