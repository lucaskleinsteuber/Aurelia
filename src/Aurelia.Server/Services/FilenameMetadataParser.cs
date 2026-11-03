using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Aurelia.Server.Services;

public static partial class FilenameMetadataParser
{
    public sealed record MovieIdentity(string Title, int? Year);

    public sealed record EpisodeIdentity(string Title, int? Season, int? Episode);

    public static MovieIdentity Movie(string path)
    {
        var filename = Path.GetFileNameWithoutExtension(path);
        var trailerSuffix = TrailerSuffixExpression().Match(filename);
        int? trailerYear = null;
        if (trailerSuffix.Success)
        {
            if (int.TryParse(trailerSuffix.Groups["year"].Value, out var parsedTrailerYear)
                && IsPlausibleYear(parsedTrailerYear))
            {
                trailerYear = parsedTrailerYear;
            }

            filename = filename[..trailerSuffix.Index];
        }

        var title = CleanTitle(filename);
        if (string.IsNullOrWhiteSpace(title))
        {
            title = "Trailer";
        }
        var match = MovieYearExpression().Match(title);
        if (!match.Success || !int.TryParse(match.Groups[2].Value, out var year))
        {
            return new MovieIdentity(title, trailerYear);
        }

        var plausibleYear = year >= 1888 && year <= DateTime.UtcNow.Year + 2;
        var titleWithoutYear = match.Groups[1].Value.Trim();
        if (plausibleYear && titleWithoutYear.Any(char.IsLetter))
        {
            return new MovieIdentity(titleWithoutYear, year);
        }

        return new MovieIdentity(title, trailerYear);
    }

    public static MovieIdentity Series(string directoryPath)
    {
        var title = CleanTitle(Path.GetFileName(directoryPath));
        var match = MovieYearExpression().Match(title);
        if (!match.Success || !int.TryParse(match.Groups[2].Value, out var year))
        {
            return new MovieIdentity(title, null);
        }

        return year >= 1888 && year <= DateTime.UtcNow.Year + 2
            ? new MovieIdentity(match.Groups[1].Value.Trim(), year)
            : new MovieIdentity(title, null);
    }

    public static bool IsExplicitTrailerFile(string path) =>
        TrailerSuffixExpression().IsMatch(Path.GetFileNameWithoutExtension(path))
        || TrailerPrefixExpression().IsMatch(Path.GetFileNameWithoutExtension(path));

    public static bool IsExplicitExtraFile(string path) =>
        ExtraSuffixExpression().IsMatch(Path.GetFileNameWithoutExtension(path));

    public static string NormalizeMatchTitle(string value)
    {
        var normalized = value.Normalize(NormalizationForm.FormKD);
        var builder = new StringBuilder(normalized.Length);
        foreach (var character in normalized)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark
                && char.IsLetterOrDigit(character))
            {
                builder.Append(char.ToLowerInvariant(character));
            }
        }

        return builder.ToString();
    }

    public static EpisodeIdentity Episode(string path, int? expectedSeason)
    {
        var raw = Path.GetFileNameWithoutExtension(path);
        foreach (var expression in EpisodeExpressions())
        {
            var match = expression.Match(raw);
            if (!match.Success)
            {
                continue;
            }

            var prefix = CleanTitleOrNull(raw[..match.Index]);
            var suffix = CleanTitleOrNull(raw[(match.Index + match.Length)..]);
            return new EpisodeIdentity(
                suffix ?? prefix ?? CleanTitle(raw),
                int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture),
                int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture));
        }

        if (expectedSeason.HasValue)
        {
            foreach (var expression in LocalEpisodeExpressions())
            {
                var match = expression.Match(raw);
                if (!match.Success)
                {
                    continue;
                }

                var title = match.Groups.Count > 2 && match.Groups[2].Success
                    ? CleanTitleOrNull(match.Groups[2].Value)
                    : null;
                return new EpisodeIdentity(
                    title ?? CleanTitle(raw),
                    expectedSeason,
                    int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture));
            }
        }

        return new EpisodeIdentity(CleanTitle(raw), null, null);
    }

    public static int? SeasonNumber(string directoryName)
    {
        var match = SeasonExpression().Match(directoryName);
        return match.Success
            ? int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture)
            : null;
    }

    public static string SupplementTitle(string path, string parentTitle)
    {
        var title = CleanTitle(Path.GetFileNameWithoutExtension(path));
        var cleanParent = CleanTitle(parentTitle);
        if (!title.StartsWith(cleanParent, StringComparison.OrdinalIgnoreCase))
        {
            return title;
        }

        var withoutParent = title[cleanParent.Length..].Trim(' ', '-', '–', '—', '.', '_');
        return string.IsNullOrWhiteSpace(withoutParent) ? title : withoutParent;
    }

    public static string NormalizeFolderToken(string value)
    {
        var decomposed = value.Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(decomposed.Length);
        foreach (var character in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark
                && char.IsAsciiLetterOrDigit(character))
            {
                builder.Append(char.ToLowerInvariant(character));
            }
        }

        return builder.ToString();
    }

    public static string CleanTitle(string value)
    {
        return CleanTitleOrNull(value) ?? value.Trim();
    }

    // File-system enumeration is ordinal, which puts episode 10 before episode 2.
    // Keep the media order stable while comparing numeric runs as numbers.
    public static int CompareNaturally(string left, string right)
    {
        var leftIndex = 0;
        var rightIndex = 0;
        while (leftIndex < left.Length && rightIndex < right.Length)
        {
            var leftIsDigit = char.IsDigit(left[leftIndex]);
            var rightIsDigit = char.IsDigit(right[rightIndex]);
            if (leftIsDigit && rightIsDigit)
            {
                var leftStart = leftIndex;
                var rightStart = rightIndex;
                while (leftIndex < left.Length && char.IsDigit(left[leftIndex])) leftIndex++;
                while (rightIndex < right.Length && char.IsDigit(right[rightIndex])) rightIndex++;

                var leftDigits = left[leftStart..leftIndex].TrimStart('0');
                var rightDigits = right[rightStart..rightIndex].TrimStart('0');
                if (leftDigits.Length != rightDigits.Length)
                {
                    return leftDigits.Length.CompareTo(rightDigits.Length);
                }

                var numericComparison = string.Compare(leftDigits, rightDigits, StringComparison.Ordinal);
                if (numericComparison != 0)
                {
                    return numericComparison;
                }

                // Equal numeric values get a deterministic tie-breaker for names such as 02/2.
                var runComparison = (leftIndex - leftStart).CompareTo(rightIndex - rightStart);
                if (runComparison != 0)
                {
                    return runComparison;
                }

                continue;
            }

            var leftCharacter = char.ToUpperInvariant(left[leftIndex++]);
            var rightCharacter = char.ToUpperInvariant(right[rightIndex++]);
            if (leftCharacter != rightCharacter)
            {
                return leftCharacter.CompareTo(rightCharacter);
            }
        }

        return (left.Length - leftIndex).CompareTo(right.Length - rightIndex);
    }

    private static string? CleanTitleOrNull(string value)
    {
        var title = value.Replace('.', ' ').Replace('_', ' ');
        title = NoiseExpression().Replace(title, string.Empty);
        // Edition and container words at the end ("Remastered", "Mini Series", "Mp4") are not
        // part of the title; a year before them stays, so it can still be recognized.
        title = EditionSuffixExpression().Replace(title, string.Empty);
        title = WhitespaceExpression().Replace(title, " ");
        title = title.Trim(' ', '-', '–', '—', '[', ']', '(', ')');
        return string.IsNullOrWhiteSpace(title) ? null : title;
    }

    private static IReadOnlyList<Regex> EpisodeExpressions()
    {
        return
        [
            SeasonEpisodeExpression(),
            NumericEpisodeExpression(),
            LongEpisodeExpression(),
            GermanEpisodeExpression(),
        ];
    }

    private static IReadOnlyList<Regex> LocalEpisodeExpressions()
    {
        return [LocalNamedEpisodeExpression(), LocalNumericEpisodeExpression()];
    }

    [GeneratedRegex(@"^(.+?)\s+\(?((?:19|20)\d{2})\)?$", RegexOptions.CultureInvariant)]
    private static partial Regex MovieYearExpression();

    private static bool IsPlausibleYear(int year) => year >= 1888 && year <= DateTime.UtcNow.Year + 2;

    [GeneratedRegex(@"(?:^|[\s._-]+)(?:official[\s._-]+)?(?:teaser|trailer)(?:[\s._-]*\d+)?(?:[\s._-]+\(?(?<year>(?:19|20)\d{2})\)?)?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex TrailerSuffixExpression();

    [GeneratedRegex(@"^(?:official[\s._-]+)?(?:teaser|trailer)(?:[\s._]*\d+)?\s*[-–—:]\s*\S", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex TrailerPrefixExpression();

    [GeneratedRegex(@"[-_]+\s*(?:extra|featurette|behind[ ._-]*the[ ._-]*scenes|deleted[ ._-]*scenes?|deleted|interview|scene|clip|short|other)(?:[\s._-]*\d+)?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ExtraSuffixExpression();

    [GeneratedRegex(@"S(\d{1,2})[ ._-]*E(\d{1,3})\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex SeasonEpisodeExpression();

    [GeneratedRegex(@"\b(\d{1,2})x(\d{1,3})\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex NumericEpisodeExpression();

    [GeneratedRegex(@"\bSeason[ ._-]*(\d{1,2})[ ._-]*Episode[ ._-]*(\d{1,3})\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex LongEpisodeExpression();

    [GeneratedRegex(@"\bStaffel[ ._-]*(\d{1,2})[ ._-]*Folge[ ._-]*(\d{1,3})\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex GermanEpisodeExpression();

    [GeneratedRegex(@"^(?:(?:Season|Staffel)[ ._-]*|S)(\d{1,2})\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex SeasonExpression();

    [GeneratedRegex(@"^(?:E|Episode|Folge)[ ._-]*(\d{1,3})(?:\s*[-._ ]+\s*(.*))?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex LocalNamedEpisodeExpression();

    [GeneratedRegex(@"^(\d{1,3})(?:\s*[-._ ]+\s*(.*))?$", RegexOptions.CultureInvariant)]
    private static partial Regex LocalNumericEpisodeExpression();

    [GeneratedRegex(@"\b(2160p|1080p|720p|480p|uhd|bluray|blu-ray|web[- .]?dl|webrip|hdtv|x26[45]|hevc|av1|aac|dts|remux)\b.*$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex NoiseExpression();

    [GeneratedRegex(@"\s+", RegexOptions.CultureInvariant)]
    private static partial Regex WhitespaceExpression();

    [GeneratedRegex(@"(?<=\S)(?:[\s()\[\]-]+(?:remastered|restored|extended(?:[\s-]+(?:cut|edition|version))?|director'?s[\s-]+cut|unrated|uncut|theatrical[\s-]+cut|special[\s-]+edition|anniversary[\s-]+edition|imax|mini[\s-]?series|limited[\s-]+series|complete[\s-]+series|mp4|mkv|m4v|avi|mov))+[\s()\[\]-]*$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex EditionSuffixExpression();
}
