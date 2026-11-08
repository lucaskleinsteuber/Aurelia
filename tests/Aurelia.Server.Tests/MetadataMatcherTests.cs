using Aurelia.Contracts;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class MetadataMatcherTests
{
    [Fact]
    public void MatchScoreNormalizesDiacriticsPunctuationAndYear()
    {
        Assert.Equal(1, MetadataMatcher.Score("Amélie: A Film", 2020, "Amelie A Film", null, 2020));
        Assert.Equal(0.96, MetadataMatcher.Score("Amélie: A Film", null, "Amelie A Film", null, 2020));
        Assert.Equal(0.82, MetadataMatcher.Score("Amélie: A Film", 2020, "Amelie A Film", null, 2001));
    }

    [Fact]
    public void ProviderOrderingIsNotMatchEvidenceAndUncertainResultsNeedReview()
    {
        var exactScore = MetadataMatcher.Score("The Truman Show", 1998, "The Truman Show", null, 1998);
        var nearScore = MetadataMatcher.Score("The Truman Show", 1998, "The Truman Show Returns", null, 1998);
        var exact = Candidate("1", "The Truman Show", 1998, exactScore);
        var near = Candidate("2", "The Truman Show Returns", 1998, nearScore);

        Assert.Equal(exact.Confidence, exactScore);
        Assert.Equal(near.Confidence, nearScore);
        Assert.True(MetadataMatcher.IsUnambiguous([exact], "The Truman Show", 1998));
        Assert.True(MetadataMatcher.IsUnambiguous([near, exact], "The Truman Show", 1998));
        Assert.Equal(exact, MetadataMatcher.SelectAutomaticMatch([near, exact], "The Truman Show", 1998));
        Assert.False(MetadataMatcher.IsUnambiguous(
            [Candidate("3", "The Truman Show", 2001, 0.82)], "The Truman Show", 1998));
    }

    [Fact]
    public void FilenamesDropEditionAndContainerWordsAndKeepTheYear()
    {
        Assert.Equal(new FilenameMetadataParser.MovieIdentity("Harbor Lights", 2000),
            FilenameMetadataParser.Movie("/media/Harbor Lights 2000 Remastered.mkv"));
        Assert.Equal(new FilenameMetadataParser.MovieIdentity("Harbor Lights", 2000),
            FilenameMetadataParser.Movie("/media/Harbor.Lights.2000.Directors.Cut.mkv"));
        Assert.Equal("One Day On Mars", FilenameMetadataParser.Series("/media/One Day On Mars Mini Series Mp4").Title);
        // Only trailing words are removed: titles that merely contain such a word keep it.
        Assert.Equal("Uncut Diamonds", FilenameMetadataParser.Series("/media/Uncut Diamonds").Title);
        Assert.Equal("My Extended Family", FilenameMetadataParser.Series("/media/My Extended Family").Title);
    }

    [Fact]
    public void SameNamedShowsAreToldApartBySeasonsEpisodesAndVotes()
    {
        var classic = Candidate("10", "Road Test", 1977, 0.96) with { VoteCount = 12 };
        var modern = Candidate("11", "Road Test", 2002, 0.96) with { VoteCount = 2400 };
        var remake = Candidate("12", "Road Test", 2010, 0.96) with { VoteCount = 300 };
        Assert.Null(MetadataMatcher.SelectAutomaticMatch([classic, modern, remake], "Road Test", null));

        // Only one show has as many seasons and episodes as the files here.
        var shapes = new Dictionary<string, TmdbShowShape>
        {
            ["10"] = new(4, 40),
            ["11"] = new(33, 250),
            ["12"] = new(6, 70),
        };
        Assert.Equal(modern, MetadataMatcher.SelectBySignals(
            [classic, modern, remake], "Road Test", null, new MetadataMatcher.LocalShape(20, 150), shapes));
        // Several shows fit: the far better known one wins only with five times the votes.
        Assert.Equal(modern, MetadataMatcher.SelectBySignals(
            [classic, modern, remake], "Road Test", null, new MetadataMatcher.LocalShape(2, 10), shapes));
        Assert.Null(MetadataMatcher.SelectBySignals(
            [modern, remake with { VoteCount = 1000 }], "Road Test", null));
        // Little-known titles never decide by votes.
        Assert.Null(MetadataMatcher.SelectBySignals(
            [classic with { VoteCount = 15 }, remake with { VoteCount = 0 }], "Road Test", null));
        // A different title is never chosen, however popular.
        Assert.Null(MetadataMatcher.SelectBySignals([modern], "Road Trip", null));
    }

    [Fact]
    public void AYearOneOffIsAcceptedOnlyForASingleExactTitle()
    {
        var film = Candidate("20", "Quiet Harbor", 2019, 0.82);
        Assert.Null(MetadataMatcher.SelectAutomaticMatch([film], "Quiet Harbor", 2018));
        Assert.Equal(film, MetadataMatcher.SelectBySignals([film], "Quiet Harbor", 2018));
        Assert.Null(MetadataMatcher.SelectBySignals([film], "Quiet Harbor", 2016));
        Assert.Null(MetadataMatcher.SelectBySignals(
            [film, Candidate("21", "Quiet Harbor", 2017, 0.82)], "Quiet Harbor", 2018));
    }

    [Fact]
    public void LongTitlesAreAlsoSearchedByTheirMainPart()
    {
        Assert.Equal(["Die Jagd am Fluss"], MetadataMatcher.FallbackQueries("Die Jagd am Fluss - Eine lange Geschichte"));
        Assert.Equal(["Deep Water"], MetadataMatcher.FallbackQueries("Deep Water: The Return"));
        Assert.Empty(MetadataMatcher.FallbackQueries("Alien - Director"));
        Assert.Empty(MetadataMatcher.FallbackQueries("Plain Title"));
    }

    [Fact]
    public void ExactYearAndOnePluralDifferenceAllowOnlyAnUnambiguousMatch()
    {
        var confidence = MetadataMatcher.Score(
            "Minions & Monster", 2026, "Minions & Monsters", null, 2026);
        var match = Candidate("1", "Minions & Monsters", 2026, confidence);

        Assert.True(confidence >= 0.86);
        Assert.True(MetadataMatcher.IsUnambiguous([match], "Minions & Monster", 2026));
        Assert.False(MetadataMatcher.IsUnambiguous([match], "Minions & Monster", 2025));
        Assert.False(MetadataMatcher.IsUnambiguous([match], "Minions & Monster", null));

        var closeCompetitor = Candidate("2", "Minion Monsters", 2026, confidence - 0.03);
        Assert.False(MetadataMatcher.IsUnambiguous(
            [match, closeCompetitor], "Minions & Monster", 2026));

        var filenameVariant = Candidate(
            "3",
            "Minions & Monsters",
            2026,
            MetadataMatcher.Score("Minions and Monster", 2026, "Minions & Monsters", null, 2026));
        Assert.Equal(
            filenameVariant,
            MetadataMatcher.SelectAutomaticMatch([filenameVariant], "Minions and Monster", 2026));
    }

    [Fact]
    public void ReviewReasonDistinguishesNoSingleAndAmbiguousResults()
    {
        Assert.Equal(
            "TMDB returned no results for the detected title.",
            MetadataMatcher.ReviewReason("Minions & Monster", 2026, []));

        var single = Candidate("1", "Minions & Monsters", 2025, 0.7);
        Assert.Contains("2025 instead of 2026", MetadataMatcher.ReviewReason(
            "Minions & Monster", 2026, [single]));

        var first = Candidate("2", "Example Movie", 2020, 0.82);
        var second = Candidate("3", "Example Movies", 2020, 0.79);
        Assert.Equal(
            "Several similar TMDB matches need confirmation.",
            MetadataMatcher.ReviewReason("Example Movie", 2020, [first, second]));
    }

    [Fact]
    public void CreditDeduplicationCollapsesExactProviderRolesButPreservesDistinctCredits()
    {
        var credits = new[]
        {
            new TmdbCredit("person-1", "Bryan Cranston", "Acting", null, "Walter White", 0, "/bryan.jpg"),
            new TmdbCredit("person-1", "Bryan Cranston", "Acting", null, "Walter White", 1, "/bryan.jpg"),
            new TmdbCredit("person-1", "Bryan Cranston", "Crew", null, "Walter White", 1, "/bryan.jpg"),
            new TmdbCredit("person-1", "Bryan Cranston", "Production", "Executive Producer", null, 2, null),
            new TmdbCredit("person-1", "Bryan Cranston", "Acting", null, "Hal", 3, "/bryan.jpg"),
            new TmdbCredit(string.Empty, "Unknown Person", "Acting", null, "Unknown", 4, null),
            new TmdbCredit(string.Empty, "Unknown Person", "Acting", null, "Unknown", 5, null),
        };

        var result = MetadataCreditDeduplicator.Deduplicate(credits);

        Assert.Equal(5, result.Count);
        Assert.Equal(1, result.Count(credit => credit.Job == null && credit.Character == "Walter White"));
        Assert.Contains(result, credit => credit.Job == "Executive Producer");
        Assert.Contains(result, credit => credit.Character == "Hal");
        Assert.Equal(2, result.Count(credit => credit.ProviderId.Length == 0));
    }

    [Fact]
    public void CreditsKeepTheWholeCastAndEveryCrewJobWithKeyJobsFirst()
    {
        var cast = string.Join(",", Enumerable.Range(0, 120).Select(i => $$"""{"id":{{i + 1}},"name":"Actor {{i}}","character":"Role {{i}}"}"""));
        var crew = """
            {"id":900,"name":"Grip","department":"Crew","job":"Key Grip"},
            {"id":901,"name":"Composer","department":"Sound","job":"Original Music Composer"},
            {"id":902,"name":"Boss","department":"Directing","job":"Director"}
            """;
        using var document = System.Text.Json.JsonDocument.Parse($$"""{"cast":[{{cast}}],"crew":[{{crew}}]}""");

        var result = TmdbClient.ParseCredits(document.RootElement);

        Assert.Equal(120, result.Count(credit => credit.Department == "Acting"));
        var jobs = result.Where(credit => credit.Department != "Acting").OrderBy(credit => credit.Order).Select(credit => credit.Job).ToList();
        Assert.Equal(["Director", "Original Music Composer", "Key Grip"], jobs);
        Assert.True(result.Where(credit => credit.Department == "Acting").Max(credit => credit.Order)
            < result.Where(credit => credit.Department != "Acting").Min(credit => credit.Order));
    }

    [Fact]
    public void SeriesAggregateCreditsJoinRolesAndSplitJobs()
    {
        using var document = System.Text.Json.JsonDocument.Parse("""
            {"cast":[{"id":1,"name":"Lead","roles":[{"character":"Young Ann"},{"character":"Ann"}]}],
             "crew":[{"id":2,"name":"Maker","department":"Writing","jobs":[{"job":"Creator"},{"job":"Writer"}]},{"name":"No Id","job":"Director"}]}
            """);

        var result = TmdbClient.ParseCredits(document.RootElement);

        Assert.Equal("Young Ann / Ann", Assert.Single(result, credit => credit.Department == "Acting").Character);
        Assert.Equal(["Creator", "Writer"], result.Where(credit => credit.ProviderId == "2").Select(credit => credit.Job));
        Assert.DoesNotContain(result, credit => credit.Name == "No Id");
    }

    [Fact]
    public void UniversesComeOnlyFromKeywordsNamingTheWorldItself()
    {
        Assert.Equal([("marvel-cinematic-universe", "Marvel Cinematic Universe")],
            MediaUniverses.Find(["superhero", "Marvel Cinematic Universe (MCU)", "marvel cinematic universe"]));
        Assert.Empty(MediaUniverses.Find(["parallel universe", "multiverse", "based on comic"]));
        Assert.Empty(MediaUniverses.Find(null));
    }

    private static MetadataCandidateSummary Candidate(
        string id,
        string title,
        int? year,
        double confidence) =>
        new("tmdb", id, "movie", title, null, year, null, null, confidence);
}
