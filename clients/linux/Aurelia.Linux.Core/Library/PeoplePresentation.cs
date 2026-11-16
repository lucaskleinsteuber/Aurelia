using System.Globalization;
using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Library;

/// <summary>What People and a person's page say, in the Mac app's words ("people-v1").</summary>
public static class PeoplePresentation
{
    public const int PageSize = 60;

    /// <summary>"3 titles", or "Director · 1 title" for someone behind the camera.</summary>
    public static string Role(PersonSummary person)
    {
        var titles = person.TitleCount == 1 ? "1 title" : $"{person.TitleCount} titles";
        return string.IsNullOrWhiteSpace(person.Department) || person.Department == "Acting" ? titles : $"{person.Department} · {titles}";
    }

    /// <summary>Only a person TMDB identified has a life to show.</summary>
    public static bool HasProfile(string? personKey) =>
        personKey?.StartsWith("tmdb:person:", StringComparison.OrdinalIgnoreCase) == true;

    /// <summary>
    /// "Born May 1, 1970 (age 56) in Invented Town", or both dates for someone who died. TMDB
    /// writes dates as YYYY-MM-DD; anything else is left out.
    /// </summary>
    public static string? Life(PersonAbout? about, DateOnly today)
    {
        if (about is null) return null;
        var born = Day(about.Birthday);
        var died = Day(about.Deathday);
        var place = string.IsNullOrWhiteSpace(about.PlaceOfBirth) ? null : about.PlaceOfBirth.Trim();
        if (born is { } start && died is { } end)
        {
            var line = $"{Format(start)} – {Format(end)} (aged {Age(start, end)})";
            return place is null ? line : $"{line} · {place}";
        }
        if (born is { } birthday)
        {
            var line = $"Born {Format(birthday)} (age {Age(birthday, today)})";
            return place is null ? line : $"{line} in {place}";
        }
        if (died is { } death) return $"Died {Format(death)}";
        return place is null ? null : $"Born in {place}";
    }

    private static DateOnly? Day(string? text) =>
        text is { Length: 10 } && DateOnly.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day) ? day : null;

    private static int Age(DateOnly born, DateOnly day)
    {
        var age = day.Year - born.Year;
        if (day.Month < born.Month || (day.Month == born.Month && day.Day < born.Day)) age--;
        return Math.Max(0, age);
    }

    private static string Format(DateOnly day) => day.ToString("MMMM d, yyyy", CultureInfo.GetCultureInfo("en-US"));
}
