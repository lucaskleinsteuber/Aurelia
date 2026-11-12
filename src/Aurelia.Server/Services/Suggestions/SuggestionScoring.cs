using System.Globalization;
using System.Text;
using Aurelia.Contracts;

namespace Aurelia.Server.Services.Suggestions;

/// <summary>What suggestions compare of a movie or series. Names are as stored; comparing ignores case.</summary>
/// <param name="Release">For ordering a film series: the release date ("2010-06-18") or the year.</param>
/// <param name="Franchises">Film series and shared universes the title is in.</param>
/// <param name="People">Leading actors, in billing order.</param>
/// <param name="Makers">Directors of a movie, creators of a series.</param>
/// <param name="Age">The age its rating allows (FSK), or null when unknown.</param>
public sealed record SuggestionTitle(
    Guid Id,
    MediaKind Kind,
    string Title,
    string? Release,
    IReadOnlyList<string> Genres,
    IReadOnlyList<string> Studios,
    IReadOnlyList<string> Keywords,
    IReadOnlyList<SuggestionFranchise> Franchises,
    IReadOnlyList<string> People,
    IReadOnlyList<string> Makers,
    int? Age);

/// <param name="IsFilmSeries">TMDB's collection of one series of films, which has an order; a universe has none.</param>
public sealed record SuggestionFranchise(string Key, string Name, bool IsFilmSeries);

/// <summary>A scored candidate with the reason that weighed most.</summary>
public sealed record ScoredSuggestion(SuggestionTitle Title, double Score, MediaSuggestionKind Kind, string Reason);

/// <summary>
/// How alike two titles are, for "what to watch next". The next film of a series of films comes
/// far ahead of everything; then the same franchise; then shared TMDB keywords, weighted by how
/// rare they are in the library; then genres (rare ones weigh more), the same director or
/// leading actors, the same studio and a similar title. Very different age ratings weigh strongly
/// against a title. Pure and deterministic, so the same library always gives the same order.
/// </summary>
public static class SuggestionScoring
{
    public const double NextPartScore = 1_000;
    public const double FranchiseScore = 120;
    public const double KeywordWeight = 60;
    public const double GenreWeight = 15;
    public const double MakerScore = 12;
    public const double ActorScore = 4;
    public const double MaximumPeopleScore = 24;
    public const double StudioScore = 5;
    public const double MaximumStudioScore = 10;
    public const double TitleWeight = 15;
    public const double AgePenalty = 60;

    /// <summary>Anything less alike than this is not suggested at all.</summary>
    public const double MinimumScore = 8;

    /// <summary>Ratings this many years apart (FSK 6 and FSK 16, for example) are very different.</summary>
    public const int AgeGap = 10;

    /// <summary>How many leading actors count.</summary>
    public const int LeadingActors = 8;

    private static readonly HashSet<string> TitleStopWords = new(StringComparer.Ordinal)
    {
        "the", "a", "an", "of", "and", "in", "on", "to", "der", "die", "das", "ein", "eine", "und", "le", "la", "les", "el", "part", "chapter",
    };

    /// <summary>
    /// How rare each keyword and genre is among <paramref name="library"/>: ln(1 + titles / titles with it).
    /// A keyword only one title has weighs most; "drama", which half the library has, little.
    /// </summary>
    public static Rarity Weigh(IReadOnlyCollection<SuggestionTitle> library)
    {
        ArgumentNullException.ThrowIfNull(library);
        static Dictionary<string, double> Count(IEnumerable<IEnumerable<string>> lists, int total)
        {
            var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (var list in lists)
            {
                foreach (var value in list.Distinct(StringComparer.OrdinalIgnoreCase)) counts[value] = counts.GetValueOrDefault(value) + 1;
            }
            return counts.ToDictionary(pair => pair.Key, pair => Math.Log(1 + (double)Math.Max(1, total) / pair.Value), StringComparer.OrdinalIgnoreCase);
        }
        return new Rarity(Count(library.Select(title => title.Keywords), library.Count), Count(library.Select(title => title.Genres), library.Count),
            Math.Log(1 + Math.Max(1, library.Count)));
    }

    /// <summary>Rarity weights; an unknown value weighs as if one title had it.</summary>
    public sealed record Rarity(IReadOnlyDictionary<string, double> Keywords, IReadOnlyDictionary<string, double> Genres, double Unknown)
    {
        public double Keyword(string value) => Keywords.TryGetValue(value, out var weight) ? weight : Unknown;

        public double Genre(string value) => Genres.TryGetValue(value, out var weight) ? weight : Unknown;
    }

    /// <summary>
    /// The films that come next after <paramref name="seed"/> in its series of films: in each, the
    /// first one released after it that is not finished.
    /// </summary>
    public static IReadOnlyDictionary<Guid, SuggestionFranchise> NextParts(SuggestionTitle seed, IReadOnlyCollection<SuggestionTitle> library, IReadOnlySet<Guid> finished)
    {
        ArgumentNullException.ThrowIfNull(seed);
        ArgumentNullException.ThrowIfNull(library);
        ArgumentNullException.ThrowIfNull(finished);
        var next = new Dictionary<Guid, SuggestionFranchise>();
        if (seed.Release is not { } seedRelease) return next;
        foreach (var series in seed.Franchises.Where(franchise => franchise.IsFilmSeries))
        {
            var following = library
                .Where(title => title.Id != seed.Id && title.Release is { } release && string.CompareOrdinal(release, seedRelease) > 0
                    && title.Franchises.Any(franchise => franchise.Key == series.Key))
                .OrderBy(title => title.Release, StringComparer.Ordinal).ThenBy(title => title.Id)
                .FirstOrDefault(title => !finished.Contains(title.Id));
            if (following is not null) next.TryAdd(following.Id, series);
        }
        return next;
    }

    /// <summary>How alike <paramref name="candidate"/> is to <paramref name="seed"/>, with the reason that weighed most.</summary>
    public static ScoredSuggestion Score(SuggestionTitle seed, SuggestionTitle candidate, Rarity rarity, SuggestionFranchise? nextPartOf = null)
    {
        ArgumentNullException.ThrowIfNull(seed);
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentNullException.ThrowIfNull(rarity);
        var parts = new List<(double Score, MediaSuggestionKind Kind, string Reason)>();

        if (nextPartOf is not null) parts.Add((NextPartScore, MediaSuggestionKind.NextPart, $"Next in {nextPartOf.Name}"));

        var franchise = seed.Franchises.FirstOrDefault(own => candidate.Franchises.Any(other => other.Key == own.Key));
        if (franchise is not null && nextPartOf is null) parts.Add((FranchiseScore, MediaSuggestionKind.Franchise, $"Also in {franchise.Name}"));

        var sharedKeywords = Shared(seed.Keywords, candidate.Keywords).OrderByDescending(rarity.Keyword).ThenBy(value => value, StringComparer.Ordinal).ToList();
        var seedKeywords = seed.Keywords.Distinct(StringComparer.OrdinalIgnoreCase).Sum(rarity.Keyword);
        if (sharedKeywords.Count > 0 && seedKeywords > 0)
        {
            var score = KeywordWeight * sharedKeywords.Sum(rarity.Keyword) / seedKeywords;
            parts.Add((score, MediaSuggestionKind.Keywords, $"Also about {Join(sharedKeywords.Take(2))}"));
        }

        var sharedGenres = Shared(seed.Genres, candidate.Genres).OrderByDescending(rarity.Genre).ThenBy(value => value, StringComparer.Ordinal).ToList();
        var seedGenres = seed.Genres.Distinct(StringComparer.OrdinalIgnoreCase).Sum(rarity.Genre);
        if (sharedGenres.Count > 0 && seedGenres > 0)
        {
            // Rare genres weigh more, and a candidate with many other genres is less alike.
            var candidateGenres = candidate.Genres.Distinct(StringComparer.OrdinalIgnoreCase).Sum(rarity.Genre);
            var shared = sharedGenres.Sum(rarity.Genre);
            var score = GenreWeight * shared / Math.Max(seedGenres, candidateGenres);
            parts.Add((score, MediaSuggestionKind.Genres, $"Also {Join(sharedGenres.Take(2))}"));
        }

        var makers = Shared(seed.Makers, candidate.Makers).ToList();
        var actors = Shared(seed.People.Take(LeadingActors), candidate.People.Take(LeadingActors)).ToList();
        if (makers.Count + actors.Count > 0)
        {
            var score = Math.Min(MaximumPeopleScore, makers.Count * MakerScore + actors.Count * ActorScore);
            var reason = makers.Count > 0
                ? (seed.Kind == MediaKind.Series && candidate.Kind == MediaKind.Series ? $"Also by {makers[0]}" : $"Also directed by {makers[0]}")
                : $"Also with {Join(seed.People.Where(person => actors.Contains(person, StringComparer.OrdinalIgnoreCase)).Take(2))}";
            parts.Add((score, MediaSuggestionKind.People, reason));
        }

        var studios = Shared(seed.Studios, candidate.Studios).ToList();
        if (studios.Count > 0) parts.Add((Math.Min(MaximumStudioScore, studios.Count * StudioScore), MediaSuggestionKind.Studio, $"Also from {studios[0]}"));

        var similarity = TitleSimilarity(seed.Title, candidate.Title);
        if (similarity > 0) parts.Add((TitleWeight * similarity, MediaSuggestionKind.Title, $"Like {seed.Title}"));

        var total = parts.Sum(part => part.Score);
        if (seed.Age is { } seedAge && candidate.Age is { } candidateAge && Math.Abs(seedAge - candidateAge) >= AgeGap) total -= AgePenalty;
        var strongest = parts.Count == 0 ? (Score: 0.0, Kind: MediaSuggestionKind.Genres, Reason: string.Empty)
            : parts.OrderByDescending(part => part.Score).First();
        return new ScoredSuggestion(candidate, Math.Round(total, 4), strongest.Kind, strongest.Reason);
    }

    /// <summary>
    /// The best suggestions after <paramref name="seed"/>: not the seed, nothing finished or
    /// excluded, nothing below <see cref="MinimumScore"/>, best first and then by title.
    /// </summary>
    public static IReadOnlyList<ScoredSuggestion> Rank(SuggestionTitle seed, IReadOnlyCollection<SuggestionTitle> library, IReadOnlySet<Guid> finished,
        Rarity rarity, int limit, IReadOnlySet<Guid>? excluded = null)
    {
        ArgumentNullException.ThrowIfNull(seed);
        ArgumentNullException.ThrowIfNull(library);
        ArgumentNullException.ThrowIfNull(finished);
        var next = NextParts(seed, library, finished);
        return [.. library
            .Where(title => title.Id != seed.Id && !finished.Contains(title.Id) && excluded?.Contains(title.Id) != true)
            .Select(title => Score(seed, title, rarity, next.GetValueOrDefault(title.Id)))
            .Where(scored => scored.Score >= MinimumScore)
            .OrderByDescending(scored => scored.Score)
            .ThenBy(scored => scored.Title.Title, StringComparer.OrdinalIgnoreCase)
            .ThenBy(scored => scored.Title.Id)
            .Take(limit)];
    }

    /// <summary>Shared words of two titles (0 to 1), ignoring small words, numbers and punctuation: "Toy Story" and "Toy Story 2" are 1.</summary>
    public static double TitleSimilarity(string first, string second)
    {
        var a = Words(first);
        var b = Words(second);
        if (a.Count == 0 || b.Count == 0) return 0;
        var shared = a.Count(b.Contains);
        return (double)shared / Math.Min(a.Count, b.Count) * ((double)shared / Math.Max(a.Count, b.Count) >= 0.5 ? 1 : 0.5);
    }

    private static HashSet<string> Words(string title)
    {
        var builder = new StringBuilder();
        foreach (var character in title.Normalize(NormalizationForm.FormD))
        {
            var category = CharUnicodeInfo.GetUnicodeCategory(character);
            if (category == UnicodeCategory.NonSpacingMark) continue;
            builder.Append(char.IsLetter(character) ? char.ToLowerInvariant(character) : ' ');
        }
        return [.. builder.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(word => word.Length > 1 && !TitleStopWords.Contains(word))];
    }

    private static IEnumerable<string> Shared(IEnumerable<string> first, IEnumerable<string> second)
    {
        var other = new HashSet<string>(second, StringComparer.OrdinalIgnoreCase);
        return first.Where(other.Contains).Distinct(StringComparer.OrdinalIgnoreCase);
    }

    private static string Join(IEnumerable<string> values)
    {
        var list = values.ToList();
        return list.Count switch
        {
            0 => string.Empty,
            1 => list[0],
            _ => $"{string.Join(", ", list.Take(list.Count - 1))} and {list[^1]}",
        };
    }
}
