using Aurelia.Contracts;

namespace Aurelia.Server.Services;

/// <summary>The era and length a Movie Night host can choose, and whether a title fits them.</summary>
public static class MovieNightFilters
{
    public static readonly IReadOnlyList<string> Eras = ["any", "2020s", "2010s", "2000s", "older"];
    public static readonly IReadOnlyList<string> Lengths = ["any", "short", "standard"];

    public static string Era(string? value) => Pick(value, Eras);

    public static string Length(string? value) => Pick(value, Lengths);

    /// <summary>
    /// Whether a title fits. A title without a year is left out once an era is chosen; a show's
    /// episodes are short anyway, so length only applies to films, and a film without a known
    /// running time stays in.
    /// </summary>
    public static bool Matches(MediaKind kind, int? year, int? runtimeMinutes, string era, string length)
    {
        var fitsEra = era switch
        {
            "2020s" => year >= 2020,
            "2010s" => year is >= 2010 and < 2020,
            "2000s" => year is >= 2000 and < 2010,
            "older" => year < 2000,
            _ => true,
        };
        if (!fitsEra) return false;
        if (kind != MediaKind.Movie || runtimeMinutes is not > 0) return true;
        return length switch
        {
            "short" => runtimeMinutes <= 100,
            "standard" => runtimeMinutes <= 130,
            _ => true,
        };
    }

    private static string Pick(string? value, IReadOnlyList<string> choices)
    {
        var wanted = value?.Trim();
        if (string.IsNullOrEmpty(wanted)) return choices[0];
        return choices.FirstOrDefault(choice => string.Equals(choice, wanted, StringComparison.OrdinalIgnoreCase))
            ?? throw new PlaybackException("invalid_movie_night_choice", "Choose one of the offered eras and lengths.", StatusCodes.Status400BadRequest);
    }
}
