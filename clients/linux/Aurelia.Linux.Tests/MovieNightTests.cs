using Aurelia.Contracts;
using Aurelia.Linux.Core.Playback;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>Movie Night and Wrapped on Linux with an invented night, year and server; nothing is played.</summary>
public sealed class MovieNightTests
{
    private static readonly Guid[] Ids = Enumerable.Range(1, 3).Select(index => Guid.Parse($"00000000-0000-4000-8000-0000000000a{index}")).ToArray();
    private static readonly List<MovieNightCard> Deck = Ids.Select((id, index) =>
        new MovieNightCard(id, MediaKind.Movie, $"Invented Film {index + 1}", 2020 + index, null, ["Comedy", "Crime", "Drama"], 95 + index * 25, null, null)).ToList();

    private static MovieNightState Night(string phase = "voting", long revision = 2, int round = 1, bool withDeck = true,
        List<MovieNightVote>? votes = null, bool voting = true) =>
        new(Guid.Parse("00000000-0000-4000-8000-0000000000b1"), phase, revision, round, round, "movies", null, ["Comedy"],
            [
                new MovieNightMember(Guid.NewGuid(), "Invented PC", "Linux PC", voting, true, true, votes?.Count ?? 0),
                new MovieNightMember(Guid.NewGuid(), "Mia", "Browser", true, false, false, 1),
            ],
            withDeck ? Deck : null, votes ?? [], null, null, null);

    [Fact]
    public void ACardCountsOnceItTravelsFarEnoughOrIsFlicked()
    {
        Assert.True(MovieNightRules.Choice(120));
        Assert.False(MovieNightRules.Choice(-120));
        Assert.Null(MovieNightRules.Choice(40));
        Assert.True(MovieNightRules.Choice(40, 900));
        Assert.False(MovieNightRules.Choice(-40, -900));
        Assert.True(MovieNightRules.Choice(80, 0, 260));
    }

    [Fact]
    public async Task TonightsProgramChangesOneChoiceAndKeepsTheOthers()
    {
        var lobby = Night("lobby") with { Genre = "Comedy", Era = "2010s", Length = "short" };
        var api = new FakeMovieNightApi(lobby, lobby);
        using var session = new MovieNightSession(api, "Invented PC", action => action());
        await session.StartAsync();
        await session.SettingsAsync(program => program with { Era = "older" });
        Assert.Equal(new MovieNightSettingsRequest("movies", "Comedy", "older", "short"), Assert.Single(api.Programs));
        Assert.Equal("Movies · Comedy · 2010s · Short", MovieNightProgram.Summary(MovieNightProgram.Current(lobby)));
        Assert.Equal("Movies and Shows · Up to 2h 10m", MovieNightProgram.Summary(new MovieNightSettingsRequest("all", null, "any", "standard")));
        // A server before eras and lengths leaves them at "any".
        Assert.Equal(("any", "any"), (Night("lobby").Era, Night("lobby").Length));
    }

    [Fact]
    public void TheScreenFollowsTheNight()
    {
        Assert.Equal(MovieNightScreen.Intro, MovieNightRules.Screen(null, 0));
        Assert.Equal(MovieNightScreen.Lobby, MovieNightRules.Screen(Night("lobby"), 3));
        Assert.Equal(MovieNightScreen.Swipe, MovieNightRules.Screen(Night(), 3));
        Assert.Equal(MovieNightScreen.Waiting, MovieNightRules.Screen(Night(), 0));
        Assert.Equal(MovieNightScreen.Waiting, MovieNightRules.Screen(Night(voting: false), 3));
        Assert.Equal(MovieNightScreen.Match, MovieNightRules.Screen(Night("match"), 1));
        Assert.Equal(MovieNightScreen.NoMatch, MovieNightRules.Screen(Night("no-match"), 0));
        Assert.Equal("1h 35m", MovieNightRules.Runtime(95));
        Assert.Equal("2h", MovieNightRules.Runtime(120));
        Assert.Null(MovieNightRules.Runtime(null));
        Assert.Equal("2020 · 1h 35m · Comedy · Crime", MovieNightRules.Meta(Deck[0]));
        var done = Night(votes: Deck.Select(card => new MovieNightVote(card.MediaId, true)).ToList());
        Assert.Equal(["Mia"], MovieNightRules.Slowpokes(done, 3).Select(member => member.Name));
    }

    [Fact]
    public async Task ASwipeCountsAtOnceAndTheDeckIsKeptBetweenPolls()
    {
        var api = new FakeMovieNightApi(Night(), Night(revision: 3, withDeck: false, votes: [new MovieNightVote(Ids[0], true)]));
        using var session = new MovieNightSession(api, "Invented PC", action => action());
        await session.StartAsync();
        Assert.Equal(MovieNightScreen.Swipe, session.Screen);
        Assert.Equal(3, session.Remaining.Count);

        await session.VoteAsync(Deck[0], like: true);
        Assert.Equal(Ids[1..], session.Remaining.Select(card => card.MediaId));
        Assert.Equal(3, session.State!.Revision);
        Assert.Equal(3, session.Deck.Count);
        Assert.Equal([new MovieNightVoteRequest(Ids[0], true)], api.Votes);

        // An older answer never undoes a newer one; a new round starts everyone over.
        session.Receive(Night(revision: 1, withDeck: false));
        Assert.Equal(3, session.State!.Revision);
        session.Receive(Night(revision: 4, round: 2));
        Assert.Equal(3, session.Remaining.Count);
        await session.LeaveAsync();
        Assert.Null(session.State);
    }

    [Fact]
    public async Task ARefusedSwipeCanBeSwipedAgain()
    {
        var api = new FakeMovieNightApi(Night()) { RefuseVotes = true };
        using var session = new MovieNightSession(api, "Invented PC", action => action());
        await session.JoinAsync(Guid.NewGuid());
        await session.VoteAsync(Deck[1], like: false);
        Assert.Equal(3, session.Remaining.Count);
        Assert.Equal("That title is not in tonight's deck.", session.Error);
        await session.LeaveAsync();
    }

    [Fact]
    public void WrappedCountsPlainNumbersAndClosesAfterTheLastSlide()
    {
        Assert.Equal(143, WrappedStory.CountTarget("143"));
        Assert.Null(WrappedStory.CountTarget("02:47"));
        Assert.Null(WrappedStory.CountTarget(null));
        Assert.Equal(0, WrappedStory.CountValue(143, 0));
        Assert.Equal(143, WrappedStory.CountValue(143, 1));
        Assert.True(WrappedStory.CountValue(100, 0.5) > 50);
        Assert.Equal(1, WrappedStory.Step(0, 3, forward: true));
        Assert.Null(WrappedStory.Step(2, 3, forward: true));
        Assert.Equal(0, WrappedStory.Step(0, 3, forward: false));
        foreach (var name in new[] { "night", "ember", "violet", "gold", "rose", "mint", "ocean", "lime" })
            Assert.True(WrappedStory.Accents.ContainsKey(name), name);
        Assert.Equal(WrappedStory.Accents["night"], WrappedStory.For("invented"));
    }

    [Fact]
    public void AMonthIsReadyFromTheSecondAndNewOnHomeForAWeek()
    {
        Assert.Equal((2026, 10, "October"), WrappedStory.ReadyMonth(new DateTime(2026, 11, 2)));
        Assert.Equal((2026, 9, "September"), WrappedStory.ReadyMonth(new DateTime(2026, 11, 1)));
        Assert.Equal((2026, 12, "December"), WrappedStory.ReadyMonth(new DateTime(2027, 1, 5)));
        Assert.Equal((2026, 11, "November"), WrappedStory.ReadyMonth(new DateTime(2027, 1, 1)));
        Assert.False(WrappedStory.MonthIsNew(new DateTime(2026, 11, 1)));
        Assert.True(WrappedStory.MonthIsNew(new DateTime(2026, 11, 8)));
        Assert.False(WrappedStory.MonthIsNew(new DateTime(2026, 11, 9)));
    }

    private sealed class FakeMovieNightApi(params MovieNightState[] answers) : IMovieNightApi
    {
        private readonly Queue<MovieNightState> answers = new(answers);

        public List<MovieNightVoteRequest> Votes { get; } = [];

        public bool RefuseVotes { get; init; }

        private Task<MovieNightState> Next() => Task.FromResult(answers.Dequeue());

        public Task<IReadOnlyList<MovieNightSummary>> MovieNightsAsync(CancellationToken cancellation) => Task.FromResult<IReadOnlyList<MovieNightSummary>>([]);

        public Task<MovieNightState> CreateMovieNightAsync(CreateMovieNightRequest request, CancellationToken cancellation) => Next();

        public Task<MovieNightState> JoinMovieNightAsync(Guid nightId, JoinMovieNightRequest request, CancellationToken cancellation) => Next();

        // The long poll waits until the session stops.
        public async Task<MovieNightState> MovieNightAsync(Guid nightId, long? after, int? deckVersion, int waitMilliseconds, CancellationToken cancellation)
        {
            await Task.Delay(Timeout.Infinite, cancellation);
            throw new OperationCanceledException(cancellation);
        }

        public List<MovieNightSettingsRequest> Programs { get; } = [];

        public Task<MovieNightState> MovieNightSettingsAsync(Guid nightId, MovieNightSettingsRequest request, CancellationToken cancellation)
        {
            Programs.Add(request);
            return Next();
        }

        public Task<MovieNightState> DealMovieNightAsync(Guid nightId, CancellationToken cancellation) => Next();

        public Task<MovieNightState> VoteMovieNightAsync(Guid nightId, MovieNightVoteRequest request, CancellationToken cancellation)
        {
            if (RefuseVotes) throw new Aurelia.Linux.Core.Api.AureliaApiException(404, "movie_night_card_not_found", "That title is not in tonight's deck.");
            Votes.Add(request);
            return Next();
        }

        public Task<MovieNightState> KeepSwipingAsync(Guid nightId, CancellationToken cancellation) => Next();

        public Task<MovieNightState> MovieNightRoleAsync(Guid nightId, MovieNightRoleRequest request, CancellationToken cancellation) => Next();

        public Task LeaveMovieNightAsync(Guid nightId, CancellationToken cancellation) => Task.CompletedTask;
    }
}
