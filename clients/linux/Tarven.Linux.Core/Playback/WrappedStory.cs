using System.Globalization;

namespace Tarven.Linux.Core.Playback;

/// <summary>Wrapped's story rules: colors, counting up and moving between slides.</summary>
public static class WrappedStory
{
    public static readonly TimeSpan SlideTime = TimeSpan.FromSeconds(6);

    /// <summary>The newest month whose Wrapped is ready: last month from the 2nd on, else the one before.</summary>
    public static (int Year, int Month, string Name) ReadyMonth(DateTime today)
    {
        var first = new DateTime(today.Year, today.Month, 1).AddMonths(today.Day >= 2 ? -1 : -2);
        return (first.Year, first.Month, CultureInfo.InvariantCulture.DateTimeFormat.GetMonthName(first.Month));
    }

    /// <summary>The months of <paramref name="year"/> whose Wrapped is ready: all of a past year, up to the newest ready one.</summary>
    public static IReadOnlyList<int> ReadyMonths(int year, DateTime today)
    {
        var ready = ReadyMonth(today);
        if (year < ready.Year) return Enumerable.Range(1, 12).ToList();
        return year == ready.Year ? Enumerable.Range(1, ready.Month).ToList() : [];
    }

    /// <summary>The years that can have a monthly Wrapped: those with activity and the newest ready month's, newest first.</summary>
    public static IReadOnlyList<int> WrappedYears(IEnumerable<int> activityYears, DateTime today)
    {
        var ready = ReadyMonth(today).Year;
        return activityYears.Where(year => year <= ready).Append(ready).Distinct().OrderDescending().ToList();
    }

    /// <summary>The English name of a month, 1 to 12.</summary>
    public static string MonthName(int month) => CultureInfo.InvariantCulture.DateTimeFormat.GetMonthName(Math.Clamp(month, 1, 12));

    /// <summary>Home shows the new month in its first week, from the 2nd to the 8th.</summary>
    public static bool MonthIsNew(DateTime today) => today.Day is >= 2 and <= 8;

    /// <summary>A color field and the ink and sticker on it, as #RRGGBB.</summary>
    public sealed record Accent(string Field, string Ink, string Sticker);

    public static readonly IReadOnlyDictionary<string, Accent> Accents = new Dictionary<string, Accent>
    {
        ["night"] = new("#171A3A", "#F2F0FF", "#5B7CFF"),
        ["ember"] = new("#FF5A36", "#1C0600", "#1C0600"),
        ["violet"] = new("#6A4CFF", "#FFFFFF", "#FFD84D"),
        ["gold"] = new("#F6B92B", "#1E1400", "#1E1400"),
        ["rose"] = new("#FF4D88", "#22000F", "#22000F"),
        ["mint"] = new("#33D39A", "#00180E", "#00180E"),
        ["ocean"] = new("#1D8BFF", "#FFFFFF", "#0B1A3A"),
        ["lime"] = new("#C4EE34", "#131A00", "#131A00"),
    };

    public static Accent For(string? name) => name is not null && Accents.TryGetValue(name, out var accent) ? accent : Accents["night"];

    /// <summary>The number to count up to, when the big text is a plain number ("143", not "02:47").</summary>
    public static int? CountTarget(string? text) =>
        text is { Length: > 0 and <= 6 } && text.All(char.IsAsciiDigit) ? int.Parse(text, CultureInfo.InvariantCulture) : null;

    /// <summary>The number <paramref name="fraction"/> (0…1) into the count, easing out so it lands softly.</summary>
    public static int CountValue(int target, double fraction)
    {
        var t = Math.Clamp(fraction, 0, 1);
        return (int)Math.Round(target * (1 - Math.Pow(1 - t, 3)));
    }

    /// <summary>The slide after a click; null past the last one, which closes the story.</summary>
    public static int? Step(int index, int count, bool forward) =>
        forward ? (index + 1 < count ? index + 1 : null) : Math.Max(0, index - 1);
}
