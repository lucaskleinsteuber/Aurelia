using System.Globalization;

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
}
