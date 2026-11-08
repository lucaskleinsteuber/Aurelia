namespace Aurelia.Server.Services;

/// <summary>
/// Shared worlds that TMDB marks with a keyword on their movies and series alike, so a series such
/// as one from the Marvel Cinematic Universe joins its movies in one collection. TMDB's own
/// collections only hold the movies of one series of films; a universe spans several of them.
/// Only keywords that name the world itself count, never ones that merely mention it.
/// </summary>
public static class MediaUniverses
{
    public const string Provider = "universe";

    private static readonly (string Keyword, string Key, string Name)[] Known =
    [
        ("marvel cinematic universe (mcu)", "marvel-cinematic-universe", "Marvel Cinematic Universe"),
        ("marvel cinematic universe", "marvel-cinematic-universe", "Marvel Cinematic Universe"),
        ("dc extended universe (dceu)", "dc-extended-universe", "DC Extended Universe"),
        ("dc extended universe", "dc-extended-universe", "DC Extended Universe"),
        ("dc universe (dcu)", "dc-universe", "DC Universe"),
        ("wizarding world", "wizarding-world", "Wizarding World"),
        ("middle-earth (tolkien)", "middle-earth", "Middle-earth"),
        ("monsterverse", "monsterverse", "MonsterVerse"),
        ("the conjuring universe", "conjuring-universe", "The Conjuring Universe"),
        ("conjuring universe", "conjuring-universe", "The Conjuring Universe"),
        ("star wars universe", "star-wars", "Star Wars"),
        ("star trek universe", "star-trek", "Star Trek"),
        ("alien franchise", "alien", "Alien"),
        ("predator franchise", "predator", "Predator"),
    ];

    /// <summary>The universes the given TMDB keywords place a title in.</summary>
    public static IReadOnlyList<(string Key, string Name)> Find(IEnumerable<string>? keywords) =>
        keywords is null ? [] : keywords
            .Select(keyword => keyword.Trim().ToLowerInvariant())
            .SelectMany(keyword => Known.Where(known => known.Keyword == keyword))
            .Select(known => (known.Key, known.Name))
            .Distinct()
            .ToList();
}
