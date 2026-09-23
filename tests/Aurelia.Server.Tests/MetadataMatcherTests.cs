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

    private static MetadataCandidateSummary Candidate(
        string id,
        string title,
        int? year,
        double confidence) =>
        new("tmdb", id, "movie", title, null, year, null, null, confidence);
}
