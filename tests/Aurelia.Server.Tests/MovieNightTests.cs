using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>Movie Night with invented profiles, devices and titles; nothing is played.</summary>
public sealed class MovieNightTests
{
    private static readonly Guid Couch = Guid.NewGuid();
    private static readonly Guid Phone = Guid.NewGuid();
    private static readonly Guid Tablet = Guid.NewGuid();
    private static readonly Guid TV = Guid.NewGuid();
    private static readonly Guid[] Titles = Enumerable.Range(1, 6).Select(index => Guid.Parse($"00000000-0000-4000-8000-0000000000a{index}")).ToArray();
    private static readonly HashSet<Guid> Everything = [.. Titles];

    [Fact]
    public void TheFirstTitleEveryVoterLikedIsTheMatch()
    {
        var service = new MovieNightService(new Clock());
        var night = service.Create(Couch, "Lucas", "Invented Laptop", voting: true, gentle: false, Everything, ["Comedy", "Horror"]);
        Assert.Equal(MovieNightService.Lobby, night.Phase);
        service.Join(night.Id, Phone, "Mia", "Invented Phone", voting: true, gentle: false, Everything);
        var dealt = service.Deal(night.Id, Couch, Cards());
        Assert.Equal(MovieNightService.Voting, dealt.Phase);
        Assert.Equal(6, dealt.Deck!.Count);

        service.Vote(night.Id, Couch, Titles[0], like: false);
        service.Vote(night.Id, Couch, Titles[1], like: true);
        service.Vote(night.Id, Phone, Titles[0], like: true);
        var waiting = service.Vote(night.Id, Couch, Titles[2], like: true);
        Assert.Equal(MovieNightService.Voting, waiting.Phase);
        var matched = service.Vote(night.Id, Phone, Titles[2], like: true);
        Assert.Equal(MovieNightService.Matched, matched.Phase);
        Assert.Equal(Titles[2], matched.Result!.Card!.MediaId);
        Assert.True(matched.Result.IsUnanimous);
        Assert.Equal("It's a match!", matched.Result.Headline);
        // Mia has not swiped Titles[1] yet; once she likes it too it is earlier in the deck, but
        // the match shown stays put.
        Assert.Equal(Titles[2], service.Vote(night.Id, Phone, Titles[1], like: true).Result!.Card!.MediaId);

        // Setting the match aside finds the earlier title everyone liked in the meantime.
        var next = service.KeepSwiping(night.Id, Phone);
        Assert.Equal(MovieNightService.Matched, next.Phase);
        Assert.Equal(Titles[1], next.Result!.Card!.MediaId);
        Assert.Throws<PlaybackException>(() => service.Vote(night.Id, Couch, Guid.NewGuid(), like: true));
    }

    [Fact]
    public void NobodySeesHowTheOthersVoted()
    {
        var service = new MovieNightService(new Clock());
        var night = service.Create(Couch, "Lucas", null, voting: true, gentle: false, Everything, []);
        service.Join(night.Id, Phone, "Mia", null, voting: true, gentle: false, Everything);
        service.Deal(night.Id, Couch, Cards());
        service.Vote(night.Id, Phone, Titles[0], like: false);
        var mine = service.Vote(night.Id, Couch, Titles[1], like: true);
        Assert.Equal([new MovieNightVote(Titles[1], true)], mine.YourVotes);
        Assert.Equal(1, mine.Members.Single(member => member.Name == "Mia").Swiped);
        var theirs = service.Vote(night.Id, Phone, Titles[2], like: true);
        Assert.Equal(2, theirs.YourVotes.Count);
        Assert.DoesNotContain(theirs.YourVotes, vote => vote.MediaId == Titles[1]);
    }

    [Fact]
    public void TheDeckOnlyHoldsTitlesEveryMemberMayOpen()
    {
        var service = new MovieNightService(new Clock());
        var night = service.Create(Couch, "Lucas", null, voting: true, gentle: false, Everything, []);
        service.Deal(night.Id, Couch, Cards());
        service.Vote(night.Id, Couch, Titles[0], like: true);
        // The first title was a match for Lucas alone; a child joining cannot open it.
        HashSet<Guid> childShelf = [Titles[3], Titles[4]];
        var joined = service.Join(night.Id, Tablet, "Invented Kid", "Invented Tablet", voting: true, gentle: true, childShelf);
        Assert.Equal([Titles[3], Titles[4]], joined.Deck!.Select(card => card.MediaId));
        Assert.Equal(MovieNightService.Voting, joined.Phase);
        Assert.Null(joined.Result);

        var plan = service.Plan(night.Id, Couch);
        Assert.DoesNotContain(Titles[0], plan.Allowed);
        Assert.DoesNotContain(Titles[3], plan.Allowed);
        var redealt = service.Deal(night.Id, Couch, Cards());
        Assert.Equal([Titles[3], Titles[4]], redealt.Deck!.Select(card => card.MediaId));
        Assert.Equal(2, redealt.Round);
        Assert.Empty(redealt.YourVotes);
    }

    [Fact]
    public async Task TheLastHoldoutLeavingMakesTheMatch()
    {
        var clock = new Clock();
        var service = new MovieNightService(clock);
        var night = service.Create(TV, "Lucas", "Invented Living Room", voting: false, gentle: false, Everything, []);
        Assert.Throws<PlaybackException>(() => service.Deal(night.Id, TV, Cards()));
        service.Join(night.Id, Phone, "Mia", null, voting: true, gentle: false, Everything);
        service.Join(night.Id, Couch, "Tom", null, voting: true, gentle: false, Everything);
        service.Deal(night.Id, TV, Cards());
        Assert.Throws<PlaybackException>(() => service.Vote(night.Id, TV, Titles[0], like: true));
        service.Vote(night.Id, Phone, Titles[0], like: true);
        var stillVoting = service.Vote(night.Id, Couch, Titles[0], like: false);
        Assert.Equal(MovieNightService.Voting, stillVoting.Phase);

        // Tom stops asking for the night; the screen keeps asking.
        clock.Advance(TimeSpan.FromSeconds(30));
        await service.WaitAsync(night.Id, TV, null, null, 0, default);
        await service.WaitAsync(night.Id, Phone, null, null, 0, default);
        clock.Advance(TimeSpan.FromSeconds(15));
        var after = await service.WaitAsync(night.Id, TV, null, null, 0, default);
        Assert.Equal(2, after.Members.Count);
        Assert.Equal(MovieNightService.Matched, after.Phase);
        Assert.Equal(Titles[0], after.Result!.Card!.MediaId);
    }

    [Fact]
    public async Task WithAllCardsSwipedAndNoMatchTheMostLikedWins()
    {
        var service = new MovieNightService(new Clock());
        var night = service.Create(Couch, "Lucas", null, voting: true, gentle: false, Everything, []);
        service.Join(night.Id, Phone, "Mia", null, voting: true, gentle: false, Everything);
        service.Join(night.Id, Tablet, "Tom", null, voting: true, gentle: false, Everything);
        var cards = Cards().Take(3).ToList();
        service.Deal(night.Id, Couch, cards);
        // Lucas likes everything, Mia only the second, Tom nothing.
        foreach (var card in cards) service.Vote(night.Id, Couch, card.MediaId, like: true);
        foreach (var card in cards) service.Vote(night.Id, Phone, card.MediaId, like: card.MediaId == Titles[1]);
        MovieNightState last = null!;
        foreach (var card in cards) last = service.Vote(night.Id, Tablet, card.MediaId, like: false);
        Assert.Equal(MovieNightService.NoMatch, last.Phase);
        Assert.Equal(Titles[1], last.Result!.Card!.MediaId);
        Assert.Equal(2, last.Result.Likes);
        Assert.Equal(3, last.Result.Voters);
        Assert.False(last.Result.IsUnanimous);
        var picky = Assert.Single(last.Result.Awards, award => award.Title == "Hardest to please");
        Assert.Equal("Tom", picky.Name);
        Assert.Contains("3", picky.Line, StringComparison.Ordinal);
        Assert.Equal("Lucas", Assert.Single(last.Result.Awards, award => award.Title == "Easiest to please").Name);
        // The lines stay the same however often someone asks.
        Assert.Equal(last.Result, (await service.WaitAsync(night.Id, Phone, null, null, 0, default)).Result);
    }

    [Fact]
    public void ANightWithAChildGetsTheGentleLines()
    {
        var service = new MovieNightService(new Clock());
        var night = service.Create(Couch, "Lucas", null, voting: true, gentle: false, Everything, []);
        service.Join(night.Id, Tablet, "Invented Kid", null, voting: true, gentle: true, Everything);
        service.Deal(night.Id, Couch, Cards());
        service.Vote(night.Id, Couch, Titles[0], like: true);
        var matched = service.Vote(night.Id, Tablet, Titles[0], like: true);
        Assert.Contains(matched.Result!.Line, MovieNightLines.MatchGentle);
    }

    [Fact]
    public async Task ALongPollAnswersAsSoonAsSomeoneSwipesAndSkipsTheKnownDeck()
    {
        var service = new MovieNightService(new Clock());
        var night = service.Create(TV, "Lucas", null, voting: false, gentle: false, Everything, []);
        service.Join(night.Id, Phone, "Mia", null, voting: true, gentle: false, Everything);
        var dealt = service.Deal(night.Id, Phone, Cards());
        var waiting = service.WaitAsync(night.Id, TV, dealt.Revision, dealt.DeckVersion, 20_000, default);
        Assert.False(waiting.IsCompleted);
        service.Vote(night.Id, Phone, Titles[0], like: false);
        var changed = await waiting.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Null(changed.Deck);
        Assert.Equal(1, changed.Members.Single(member => member.Name == "Mia").Swiped);
        Assert.Equal("swiped", changed.LastAction);
    }

    [Fact]
    public void OnlyTheHostChangesWhatIsDealt()
    {
        var service = new MovieNightService(new Clock());
        var night = service.Create(Couch, "Lucas", null, voting: true, gentle: false, Everything, ["Comedy"]);
        service.Join(night.Id, Phone, "Mia", null, voting: true, gentle: false, Everything);
        Assert.Throws<PlaybackException>(() => service.Settings(night.Id, Phone, "all", null));
        Assert.Throws<PlaybackException>(() => service.Settings(night.Id, Couch, "all", "Invented Genre"));
        var changed = service.Settings(night.Id, Couch, "all", "comedy");
        Assert.Equal("all", changed.Kinds);
        Assert.Equal("Comedy", changed.Genre);
        for (var member = 2; member < MovieNightService.MaximumMembers; member++)
            service.Join(night.Id, Guid.NewGuid(), "Invented Guest", null, voting: true, gentle: false, Everything);
        Assert.Throws<PlaybackException>(() => service.Join(night.Id, Guid.NewGuid(), "One Too Many", null, voting: true, gentle: false, Everything));
    }

    [Fact]
    public async Task AChildsPhoneOnlyGetsTitlesItsProfileMayOpenThroughTheApi()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var shared = await AddMovieAsync(factory, "Invented Family Film", "Comedy");
        var hidden = await AddMovieAsync(factory, "Invented Grown-up Film", "Thriller");
        using (var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                   new CreateUserRequest("invented-child", "another correct horse password", UserRole.User, ApiTestClient.TestPin,
                       AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: [shared])))
        using (var created = await ApiTestClient.SendAsync(client, create))
            created.EnsureSuccessStatusCode();
        using var login = await ApiTestClient.LoginAsync(client, new LoginRequest("invented-child", "another correct horse password", "Invented Tablet"));
        var child = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);

        MovieNightState night;
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/movie-night", owner.Token, new CreateMovieNightRequest("Invented Living Room", IsVoting: false)))
        using (var response = await ApiTestClient.SendAsync(client, request))
        {
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            night = await ApiTestClient.ReadAsync<MovieNightState>(response);
        }
        Assert.Equal(MovieNightService.Lobby, night.Phase);
        Assert.Contains("Thriller", night.GenreOptions);

        using (var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/movie-night", child.Token))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Equal("Invented Living Room", Assert.Single(await ApiTestClient.ReadAsync<List<MovieNightSummary>>(response)).HostDevice);
        using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/movie-night/{night.Id}", child.Token))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/movie-night/{night.Id}/join", child.Token, new JoinMovieNightRequest("Invented Tablet")))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Equal(2, (await ApiTestClient.ReadAsync<MovieNightState>(response)).Members.Count);

        MovieNightState dealt;
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/movie-night/{night.Id}/deal", owner.Token))
        using (var response = await ApiTestClient.SendAsync(client, request))
        {
            var body = await response.Content.ReadAsStringAsync();
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            Assert.DoesNotContain("Grown-up", body, StringComparison.Ordinal);
            Assert.DoesNotContain(hidden.ToString(), body, StringComparison.OrdinalIgnoreCase);
            dealt = System.Text.Json.JsonSerializer.Deserialize<MovieNightState>(body, ApiTestClient.JsonOptions)!;
        }
        Assert.Equal("Invented Family Film", Assert.Single(dealt.Deck!).Title);

        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/movie-night/{night.Id}/votes", child.Token, new MovieNightVoteRequest(hidden, true)))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/movie-night/{night.Id}/votes", child.Token, new MovieNightVoteRequest(shared, true)))
        using (var response = await ApiTestClient.SendAsync(client, request))
        {
            var state = await ApiTestClient.ReadAsync<MovieNightState>(response);
            Assert.Equal(MovieNightService.Matched, state.Phase);
            // A profile limited to chosen titles is not a children's profile; only an age limit is.
            Assert.Contains(state.Result!.Line, MovieNightLines.Solo);
        }

        foreach (var token in new[] { child.Token, owner.Token })
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/movie-night/{night.Id}/members/me", token);
            using var response = await ApiTestClient.SendAsync(client, request);
            Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        }
        using (var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/movie-night", owner.Token))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Empty(await ApiTestClient.ReadAsync<List<MovieNightSummary>>(response));
    }

    [Fact]
    public void WaitingForTheNightDoesNotKeepTheServerAwake()
    {
        var context = new Microsoft.AspNetCore.Http.DefaultHttpContext();
        context.User = new System.Security.Claims.ClaimsPrincipal(new System.Security.Claims.ClaimsIdentity([new System.Security.Claims.Claim("sub", "x")], "Test"));
        context.Request.Method = "GET";
        context.Request.Path = $"/api/v1/movie-night/{Guid.NewGuid()}";
        context.Request.QueryString = new Microsoft.AspNetCore.Http.QueryString("?after=3&waitMs=20000");
        Assert.False(ServerUseClock.CountsAsUse(context));
        context.Request.Method = "POST";
        context.Request.QueryString = default;
        Assert.True(ServerUseClock.CountsAsUse(context));
    }

    private static List<MovieNightCard> Cards() =>
        Titles.Select((id, index) => new MovieNightCard(id, MediaKind.Movie, $"Invented Film {index + 1}", 2020 + index, null, ["Comedy"], 95, null, null)).ToList();

    private static async Task<Guid> AddMovieAsync(AureliaServerFactory factory, string title, string genre)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var root = Path.Combine(factory.DataDirectory, "Invented Movie Night Library " + title);
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Invented",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = DateTimeOffset.UtcNow,
            MonitoringEnabled = false,
        };
        var path = Path.Combine(root, title + ".mkv");
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = MediaKind.Movie,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            DetectedTitle = title,
            Category = string.Empty,
            Extension = ".mkv",
            FileSize = 1,
            FileModifiedAt = DateTimeOffset.UtcNow,
            Availability = MediaAvailability.Available,
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
        };
        database.MediaItems.Add(media);
        database.MediaMetadata.Add(new MediaMetadata
        {
            MediaItemId = media.Id,
            MediaItem = media,
            ProviderGenresJson = MetadataPresentation.SerializeList([genre]),
        });
        await database.SaveChangesAsync();
        return media.Id;
    }

    private sealed class Clock : TimeProvider
    {
        private DateTimeOffset now = new(2026, 11, 7, 20, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan by) => now += by;
    }
}
