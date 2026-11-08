using System.Globalization;
using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Library;

/// <summary>Durations and dates for History and Statistics, in minutes, hours and days.</summary>
public static class ActivityFormat
{
    /// <summary>"45 min", "3 h 20 min", "2 d 4 h".</summary>
    public static string Duration(TimeSpan duration)
    {
        if (duration < TimeSpan.FromMinutes(1)) return duration.TotalSeconds < 1 ? "0 min" : "1 min";
        if (duration < TimeSpan.FromHours(1)) return $"{(int)Math.Round(duration.TotalMinutes)} min";
        if (duration < TimeSpan.FromDays(1))
        {
            var minutes = duration.Minutes;
            return minutes == 0 ? $"{(int)duration.TotalHours} h" : $"{(int)duration.TotalHours} h {minutes} min";
        }
        var hours = duration.Hours;
        return hours == 0 ? $"{(int)duration.TotalDays} d" : $"{(int)duration.TotalDays} d {hours} h";
    }

    public static string Hours(double hours) => Duration(TimeSpan.FromHours(Math.Max(0, hours)));

    /// <summary>"Today", "Yesterday" or the date, for History's day groups.</summary>
    public static string Day(DateTimeOffset when, DateTimeOffset now)
    {
        var day = when.ToLocalTime().Date;
        var today = now.ToLocalTime().Date;
        if (day == today) return "Today";
        if (day == today.AddDays(-1)) return "Yesterday";
        return day.ToString(day.Year == today.Year ? "dddd, d MMMM" : "d MMMM yyyy", CultureInfo.GetCultureInfo("en-US"));
    }

    public static string Time(DateTimeOffset when) => when.ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture);

    public static string Percent(double fraction) => ((int)Math.Round(Math.Clamp(fraction, 0, 1) * 100)).ToString(CultureInfo.InvariantCulture) + " %";

    /// <summary>
    /// The last weeks up to this one, oldest first, with no watch time where nothing was watched;
    /// the server lists only weeks with watching, as on the Mac.
    /// </summary>
    public static List<PeriodHours> LastWeeks(IEnumerable<PeriodHours> periods, DateTime today, int count = 12)
    {
        var hours = periods.GroupBy(period => period.Period).ToDictionary(group => group.Key, group => group.Sum(period => period.Hours));
        return [.. Enumerable.Range(0, count).Reverse().Select(back =>
        {
            var day = today.Date.AddDays(-7 * back);
            var key = $"{ISOWeek.GetYear(day)}-W{ISOWeek.GetWeekOfYear(day):D2}";
            return new PeriodHours(key, hours.GetValueOrDefault(key));
        })];
    }

    /// <summary>"Nov 3": the Monday a week of the form 2026-W45 starts on.</summary>
    public static string WeekStart(string period)
    {
        var parts = period.Split("-W");
        return parts.Length == 2 && int.TryParse(parts[0], CultureInfo.InvariantCulture, out var year)
            && int.TryParse(parts[1], CultureInfo.InvariantCulture, out var week) && week is >= 1 and <= 53
            ? ISOWeek.ToDateTime(year, week, DayOfWeek.Monday).ToString("MMM d", CultureInfo.GetCultureInfo("en-US"))
            : period;
    }

    /// <summary>"November 1, 2026" for a day of the form 2026-11-01.</summary>
    public static string LongDay(string day) =>
        DateTime.TryParseExact(day, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)
            ? date.ToString("MMMM d, yyyy", CultureInfo.GetCultureInfo("en-US"))
            : day;
}
