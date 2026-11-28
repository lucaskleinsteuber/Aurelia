using Tarven.Contracts;
using Tarven.Linux.Core;
using Tarven.Linux.Core.Library;
using Tarven.Linux.Library;
using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.VisualTree;
using Xunit;

namespace Tarven.Linux.Tests;

/// <summary>People ("people-v1") in the Linux app: the sidebar page, a person's life and Known For. Invented people only.</summary>
public sealed class PeopleTests
{
    private static PersonAbout About(string? born, string? died = null, string? place = null) =>
        new(null, born, died, place, "Acting", "tmdb", "17");

    [Fact]
    public void TheLifeLineAndTheCardSayWhatTheMacSays()
    {
        var today = new DateOnly(2026, 11, 16);
        Assert.Equal("Born May 1, 1970 (age 56) in Invented Town", PeoplePresentation.Life(About("1970-05-01", place: "Invented Town"), today));
        Assert.Equal("Born December 24, 1970 (age 55)", PeoplePresentation.Life(About("1970-12-24"), today));
        Assert.Equal("February 8, 1931 – September 30, 1955 (aged 24) · Invented Town",
            PeoplePresentation.Life(About("1931-02-08", "1955-09-30", "Invented Town"), today));
        Assert.Equal("Died March 4, 2001", PeoplePresentation.Life(About(null, "2001-03-04"), today));
        Assert.Null(PeoplePresentation.Life(About("sometime"), today));
        Assert.Null(PeoplePresentation.Life(null, today));

        Assert.Equal("3 titles", PeoplePresentation.Role(new PersonSummary("Morgan Vale", "tmdb:person:17", null, 3, "Acting")));
        Assert.Equal("Director · 1 title", PeoplePresentation.Role(new PersonSummary("Theo Brandt", "tmdb:person:18", null, 1, "Director")));
        Assert.True(PeoplePresentation.HasProfile("tmdb:person:17"));
        Assert.False(PeoplePresentation.HasProfile("ada"));

        // Catalog person lookup must pass `key` (not `personKey`) and omit `unidentified:` keys (audit SRV-API-002).
        Assert.Equal("name=Ada%20Lovelace&key=tmdb%3Aperson%3A17", LibraryClient.PersonQuery("Ada Lovelace", "tmdb:person:17"));
        Assert.Equal("name=Ada%20Lovelace", LibraryClient.PersonQuery("Ada Lovelace", "unidentified:ada"));
        Assert.Equal("name=Ada%20Lovelace", LibraryClient.PersonQuery("Ada Lovelace", null));
    }

    [Fact]
    public void PeopleJoinTheSidebarOnlyWhereTheServerHasThem()
    {
        Assert.DoesNotContain(LibraryDestination.People, SidebarLayout.Default.VisibleItems(supportsWatchlist: true, supportsWishes: true));
        var visible = SidebarLayout.Default.VisibleItems(supportsWatchlist: true, supportsWishes: true, supportsPeople: true).ToList();
        Assert.Equal(visible.IndexOf(LibraryDestination.Watchlist) + 1, visible.IndexOf(LibraryDestination.People));
        Assert.Equal(LibraryDestination.People, LibraryDestinations.FromIdentifier("people"));
    }

    [AvaloniaFact]
    public void PeopleListsEveryoneAndAPersonShowsTheirLifeAndWhatToWish()
    {
        var unsupported = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        Assert.DoesNotContain(unsupported.Shell!.SidebarItems, item => item.Destination == LibraryDestination.People);

        var server = FakeLibrary.Create(wishes: true, people: true);
        var window = FakeLibrary.ShowLibrary(server);
        Assert.Contains(window.Shell!.SidebarItems, item => item.Destination == LibraryDestination.People);
        window.Shell.Destination = LibraryDestination.People;
        var page = Assert.IsType<PeopleBrowsePage>(window.Shell.CurrentPage);
        FakeLibrary.Pump(() => page.People.Count == 2);
        var texts = page.GetVisualDescendants().OfType<TextBlock>().Select(text => text.Text).ToList();
        Assert.Contains("Ada Lovelace", texts);
        Assert.Contains("Director · 1 title", texts);
        Assert.Contains("GET /api/v1/people", server.Requests);

        window.Shell.OpenPerson("Ada Lovelace", "tmdb:person:17");
        var person = Assert.IsType<PersonPage>(window.Shell.CurrentPage);
        FakeLibrary.Pump(() => person.Profile is not null);
        FakeLibrary.Pump(() => false, rounds: 10);
        texts = person.GetVisualDescendants().OfType<TextBlock>().Select(text => text.Text).ToList();
        Assert.Contains(texts, text => text?.StartsWith("Born May 1, 1970 (age ", StringComparison.Ordinal) == true && text.EndsWith(") in Invented Town", StringComparison.Ordinal));
        Assert.Contains("An invented actor who plays invented captains.", texts);
        Assert.Contains("In Your Library", texts);
        Assert.Contains("Known For", texts);
        Assert.Contains("Distant Shore", texts);

        var wishing = person.WishAsync(person.Profile!.KnownFor[0]);
        FakeLibrary.Pump(() => wishing.IsCompleted);
        Assert.Contains("POST /api/v1/wishes", server.Requests);
        Assert.True(person.Profile!.KnownFor[0].SupportedByCaller);
        texts = person.GetVisualDescendants().OfType<TextBlock>().Select(text => text.Text).ToList();
        Assert.Contains("✓ Wished", texts);
    }
}
