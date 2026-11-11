using Aurelia.Contracts;

namespace Aurelia.Server.Services;

/// <summary>
/// Movie Night, in memory only. A member is one profile on one device (its profile session) and
/// stays while it asks for the night at least every <see cref="MemberTimeout"/>. Each member brings
/// the titles its profile may open (its "shelf"); the deck only ever holds titles on every member's
/// shelf, so nobody is shown, or matched with, a title their profile cannot open.
/// </summary>
public sealed class MovieNightService(TimeProvider clock)
{
    public static readonly TimeSpan MemberTimeout = TimeSpan.FromSeconds(40);
    public const int MaximumNights = 8;
    public const int MaximumMembers = 12;
    public const int DeckSize = 40;
    public const int MaximumWaitMilliseconds = 25_000;
    public const string Lobby = "lobby";
    public const string Voting = "voting";
    public const string Matched = "match";
    public const string NoMatch = "no-match";
    private const int MaximumNameLength = 100;

    private readonly object gate = new();
    private readonly Dictionary<Guid, Night> nights = [];

    public IReadOnlyList<MovieNightSummary> List()
    {
        lock (gate)
        {
            Maintain();
            return nights.Values.OrderBy(night => night.CreatedAt).Select(night =>
            {
                var host = Host(night);
                return new MovieNightSummary(night.Id, host.Name, host.DeviceName, night.Members.Count, night.Phase);
            }).ToList();
        }
    }

    public MovieNightState Create(Guid profileSession, string name, string? device, bool voting, bool gentle,
        IReadOnlySet<Guid> shelf, IReadOnlyList<string> genreOptions)
    {
        lock (gate)
        {
            Maintain();
            LeaveAll(profileSession);
            if (nights.Count >= MaximumNights)
                throw new PlaybackException("too_many_movie_nights", "Too many Movie Nights are open on this server.", StatusCodes.Status429TooManyRequests);
            var now = clock.GetUtcNow();
            var member = new Member(Guid.NewGuid(), profileSession, Bounded(name, "Someone"), Bounded(device, "Unknown Device"), now, shelf)
            {
                IsVoting = voting,
                IsGentle = gentle,
            };
            var night = new Night(Guid.NewGuid(), member.Id, now)
            {
                GenreOptions = genreOptions.Take(24).Select(genre => Bounded(genre, "Other")).Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
                LastAction = "started",
                LastActionBy = member.Name,
            };
            night.Members.Add(member);
            nights[night.Id] = night;
            return Describe(night, profileSession, null);
        }
    }

    public MovieNightState Join(Guid nightId, Guid profileSession, string name, string? device, bool voting, bool gentle, IReadOnlySet<Guid> shelf)
    {
        lock (gate)
        {
            Maintain();
            var night = Find(nightId);
            if (night.Members.FirstOrDefault(member => member.ProfileSession == profileSession) is { } existing)
            {
                existing.LastSeen = clock.GetUtcNow();
                return Describe(night, profileSession, null);
            }
            LeaveAll(profileSession);
            if (night.Members.Count >= MaximumMembers)
                throw new PlaybackException("movie_night_full", "This Movie Night is full.", StatusCodes.Status409Conflict);
            var member = new Member(Guid.NewGuid(), profileSession, Bounded(name, "Someone"), Bounded(device, "Unknown Device"), clock.GetUtcNow(), shelf)
            {
                IsVoting = voting,
                IsGentle = gentle,
            };
            night.Members.Add(member);
            // Cards the new member's profile cannot open leave the deck for everyone.
            var before = night.Deck.Count;
            night.Deck.RemoveAll(card => !shelf.Contains(card.MediaId));
            if (night.Deck.Count != before)
            {
                night.DeckVersion++;
                if (night.Phase is Matched or NoMatch && night.Result?.Card is { } shown && !shelf.Contains(shown.MediaId)) Reopen(night);
                if (night.Phase == Voting && night.Deck.Count == 0) Reopen(night);
            }
            Changed(night, "joined", member.Name);
            return Describe(night, profileSession, null);
        }
    }

    /// <summary>The state once its revision is newer than <paramref name="after"/>, or after the wait.</summary>
    public async Task<MovieNightState> WaitAsync(Guid nightId, Guid profileSession, long? after, int? deckVersion, int waitMilliseconds, CancellationToken token)
    {
        Task changed;
        lock (gate)
        {
            Maintain();
            var night = Find(nightId);
            Membership(night, profileSession).LastSeen = clock.GetUtcNow();
            if (after is null || night.Revision > after || waitMilliseconds <= 0) return Describe(night, profileSession, deckVersion);
            changed = night.Signal.Task;
        }
        var wait = Math.Clamp(waitMilliseconds, 0, MaximumWaitMilliseconds);
        await Task.WhenAny(changed, Task.Delay(TimeSpan.FromMilliseconds(wait), clock, token));
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            Maintain();
            var night = Find(nightId);
            Membership(night, profileSession).LastSeen = clock.GetUtcNow();
            return Describe(night, profileSession, deckVersion);
        }
    }

    /// <summary>The host picks movies or also shows, a genre, an era and a length before a deal.</summary>
    public MovieNightState Settings(Guid nightId, Guid profileSession, string? kinds, string? genre, string? era = null, string? length = null)
    {
        lock (gate)
        {
            Maintain();
            var night = Find(nightId);
            var member = Membership(night, profileSession);
            member.LastSeen = clock.GetUtcNow();
            if (member.Id != night.HostId)
                throw new PlaybackException("not_movie_night_host", "Only the person who started Movie Night can change what is dealt.", StatusCodes.Status403Forbidden);
            night.Kinds = NormalizedKinds(kinds);
            night.Genre = string.IsNullOrWhiteSpace(genre) ? null
                : night.GenreOptions.FirstOrDefault(option => string.Equals(option, genre.Trim(), StringComparison.OrdinalIgnoreCase))
                  ?? throw new PlaybackException("invalid_genre", "Choose one of the genres in the list.", StatusCodes.Status400BadRequest);
            night.Era = MovieNightFilters.Era(era);
            night.Length = MovieNightFilters.Length(length);
            Changed(night, "settings", member.Name);
            return Describe(night, profileSession, null);
        }
    }

    /// <summary>What a new deal may hold: titles on every member's shelf that were not dealt before.</summary>
    public DealPlan Plan(Guid nightId, Guid profileSession)
    {
        lock (gate)
        {
            Maintain();
            var night = Find(nightId);
            Membership(night, profileSession).LastSeen = clock.GetUtcNow();
            HashSet<Guid>? allowed = null;
            foreach (var member in night.Members)
            {
                if (allowed is null) allowed = [.. member.Shelf];
                else allowed.IntersectWith(member.Shelf);
            }
            allowed ??= [];
            allowed.ExceptWith(night.Dealt);
            return new DealPlan(allowed, night.Kinds, night.Genre, BitConverter.ToInt32(night.Id.ToByteArray(), 0) ^ (night.Round + 1) * 7919,
                night.Era, night.Length);
        }
    }

    /// <summary>Deals <paramref name="cards"/> as the next round; everyone's votes start over.</summary>
    public MovieNightState Deal(Guid nightId, Guid profileSession, IReadOnlyList<MovieNightCard> cards)
    {
        lock (gate)
        {
            Maintain();
            var night = Find(nightId);
            var member = Membership(night, profileSession);
            member.LastSeen = clock.GetUtcNow();
            if (!night.Members.Any(each => each.IsVoting))
                throw new PlaybackException("no_movie_night_voters", "Someone has to swipe. Join from a phone or another device first.", StatusCodes.Status409Conflict);
            // Someone may have joined since the plan was made.
            var deck = cards.Where(card => night.Members.All(each => each.Shelf.Contains(card.MediaId)))
                .DistinctBy(card => card.MediaId).Take(DeckSize).ToList();
            if (deck.Count == 0)
                throw new PlaybackException("movie_night_empty", night.Genre is null && night.Era == "any" && night.Length == "any"
                    ? "Nothing left in the library that everyone here may watch. Try movies and shows."
                    : "Nothing left that fits these choices and everyone here may watch. Try another genre, era or length.", StatusCodes.Status409Conflict);
            night.Deck.Clear();
            night.Deck.AddRange(deck);
            night.Dealt.UnionWith(deck.Select(card => card.MediaId));
            night.Discarded.Clear();
            foreach (var each in night.Members) each.Votes.Clear();
            night.Round++;
            night.DeckVersion++;
            night.Phase = Voting;
            night.Result = null;
            Changed(night, night.Round == 1 ? "dealt" : "dealt-again", member.Name);
            return Describe(night, profileSession, null);
        }
    }

    public MovieNightState Vote(Guid nightId, Guid profileSession, Guid mediaId, bool like)
    {
        lock (gate)
        {
            Maintain();
            var night = Find(nightId);
            var member = Membership(night, profileSession);
            member.LastSeen = clock.GetUtcNow();
            if (!member.IsVoting)
                throw new PlaybackException("not_movie_night_voter", "This device only watches. Join from another device to swipe.", StatusCodes.Status409Conflict);
            if (night.Deck.All(card => card.MediaId != mediaId))
                throw new PlaybackException("movie_night_card_not_found", "That title is not in tonight's deck.", StatusCodes.Status404NotFound);
            // A vote that arrives after the match is kept, so swiping on stays correct if the
            // others keep swiping; it never changes the result shown.
            member.Votes[mediaId] = like;
            if (night.Phase == Voting) Evaluate(night);
            Changed(night, "swiped", member.Name);
            return Describe(night, profileSession, null);
        }
    }

    /// <summary>Someone did not want the match after all: it is set aside and swiping goes on.</summary>
    public MovieNightState KeepSwiping(Guid nightId, Guid profileSession)
    {
        lock (gate)
        {
            Maintain();
            var night = Find(nightId);
            var member = Membership(night, profileSession);
            member.LastSeen = clock.GetUtcNow();
            if (night.Phase != Matched)
                throw new PlaybackException("no_movie_night_match", "There is no match to set aside.", StatusCodes.Status409Conflict);
            if (night.Result?.Card is { } card) night.Discarded.Add(card.MediaId);
            Reopen(night);
            Changed(night, "kept-swiping", member.Name);
            return Describe(night, profileSession, null);
        }
    }

    public MovieNightState Role(Guid nightId, Guid profileSession, bool voting)
    {
        lock (gate)
        {
            Maintain();
            var night = Find(nightId);
            var member = Membership(night, profileSession);
            member.LastSeen = clock.GetUtcNow();
            if (member.IsVoting == voting) return Describe(night, profileSession, null);
            member.IsVoting = voting;
            if (!voting) member.Votes.Clear();
            if (night.Phase == Voting) Evaluate(night);
            Changed(night, voting ? "voting" : "watching", member.Name);
            return Describe(night, profileSession, null);
        }
    }

    public void Leave(Guid nightId, Guid profileSession)
    {
        lock (gate)
        {
            if (nights.TryGetValue(nightId, out var night)) Remove(night, profileSession);
        }
    }

    public void LeaveAll(Guid profileSession)
    {
        lock (gate)
        {
            foreach (var night in nights.Values.ToList()) Remove(night, profileSession);
        }
    }

    private void Remove(Night night, Guid profileSession)
    {
        var member = night.Members.FirstOrDefault(each => each.ProfileSession == profileSession);
        if (member is null) return;
        night.Members.Remove(member);
        if (night.Members.Count == 0)
        {
            nights.Remove(night.Id);
            night.Signal.TrySetResult();
            return;
        }
        if (night.HostId == member.Id) night.HostId = night.Members[0].Id;
        // The one who kept saying no may have left; the others may agree now.
        if (night.Phase == Voting) Evaluate(night);
        Changed(night, "left", member.Name);
    }

    private void Maintain()
    {
        var now = clock.GetUtcNow();
        foreach (var night in nights.Values.ToList())
            foreach (var gone in night.Members.Where(member => now - member.LastSeen > MemberTimeout).ToList())
                Remove(night, gone.ProfileSession);
    }

    private static void Reopen(Night night)
    {
        night.Phase = night.Round == 0 ? Lobby : Voting;
        night.Result = null;
        if (night.Phase == Voting) Evaluate(night);
    }

    /// <summary>The first card every voter liked is the match; with all cards swiped and none, the most liked.</summary>
    private static void Evaluate(Night night)
    {
        var voters = night.Members.Where(member => member.IsVoting).ToList();
        if (voters.Count == 0) return;
        var open = night.Deck.Where(card => !night.Discarded.Contains(card.MediaId)).ToList();
        int Likes(MovieNightCard card) => voters.Count(voter => voter.Votes.TryGetValue(card.MediaId, out var like) && like);
        if (open.FirstOrDefault(card => Likes(card) == voters.Count) is { } match)
        {
            night.Phase = Matched;
            night.Result = Result(night, voters, match, voters.Count, unanimous: true);
            return;
        }
        if (!voters.All(voter => night.Deck.All(card => voter.Votes.ContainsKey(card.MediaId)))) return;
        var best = open.Select((card, index) => (Card: card, Likes: Likes(card), Index: index))
            .OrderByDescending(entry => entry.Likes).ThenBy(entry => entry.Index).FirstOrDefault();
        night.Phase = NoMatch;
        night.Result = Result(night, voters, best.Likes > 0 ? best.Card : null, best.Likes, unanimous: false);
    }

    private static MovieNightResult Result(Night night, List<Member> voters, MovieNightCard? card, int likes, bool unanimous)
    {
        var gentle = night.Members.Any(member => member.IsGentle);
        var seed = Seed(night);
        var swipes = voters.Sum(voter => voter.Votes.Count);
        string headline;
        string line;
        if (unanimous)
        {
            headline = "It's a match!";
            line = voters.Count == 1
                ? Pick(gentle ? MovieNightLines.SoloGentle : MovieNightLines.Solo, seed)
                : Pick(gentle ? MovieNightLines.MatchGentle : MovieNightLines.Match, seed);
        }
        else if (card is null)
        {
            headline = "Nobody liked anything.";
            line = Pick(gentle ? MovieNightLines.NothingGentle : MovieNightLines.Nothing, seed);
        }
        else
        {
            headline = "No perfect match.";
            line = Pick(gentle ? MovieNightLines.CloseGentle : MovieNightLines.Close, seed);
        }
        line = line.Replace("{voters}", voters.Count.ToString(System.Globalization.CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("{likes}", likes.ToString(System.Globalization.CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("{swipes}", swipes.ToString(System.Globalization.CultureInfo.InvariantCulture), StringComparison.Ordinal);
        return new MovieNightResult(card, likes, voters.Count, unanimous, headline, line, Awards(voters, gentle, seed));
    }

    /// <summary>Hardest and easiest to please, once at least two people swiped.</summary>
    private static List<MovieNightAward> Awards(List<Member> voters, bool gentle, int seed)
    {
        var awards = new List<MovieNightAward>();
        var swiped = voters.Where(voter => voter.Votes.Count > 0).ToList();
        if (swiped.Count < 2) return awards;
        var picky = swiped.OrderByDescending(voter => voter.Votes.Count(vote => !vote.Value)).First();
        var nopes = picky.Votes.Count(vote => !vote.Value);
        if (nopes > 0)
            awards.Add(new MovieNightAward("Hardest to please", picky.Name,
                Fill(Pick(gentle ? MovieNightLines.PickyGentle : MovieNightLines.Picky, seed), picky.Name, nopes)));
        var easy = swiped.Where(voter => voter != picky)
            .OrderByDescending(voter => voter.Votes.Count(vote => vote.Value)).FirstOrDefault();
        var yeses = easy?.Votes.Count(vote => vote.Value) ?? 0;
        if (easy is not null && yeses > 0)
            awards.Add(new MovieNightAward("Easiest to please", easy.Name,
                Fill(Pick(gentle ? MovieNightLines.EasyGentle : MovieNightLines.Easy, seed + 1), easy.Name, yeses)));
        return awards;
    }

    private static string Fill(string line, string name, int count) =>
        line.Replace("{name}", name, StringComparison.Ordinal)
            .Replace("{n}", count.ToString(System.Globalization.CultureInfo.InvariantCulture), StringComparison.Ordinal);

    private static int Seed(Night night) => BitConverter.ToInt32(night.Id.ToByteArray(), 4) ^ (night.Round * 31 + night.Discarded.Count);

    private static string Pick(string[] lines, int seed) => lines[(int)((uint)seed % (uint)lines.Length)];

    private static string NormalizedKinds(string? kinds) =>
        string.Equals(kinds?.Trim(), "all", StringComparison.OrdinalIgnoreCase) ? "all" : "movies";

    private static void Changed(Night night, string action, string by)
    {
        night.Revision++;
        night.LastAction = action;
        night.LastActionBy = by;
        var signal = night.Signal;
        night.Signal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        signal.TrySetResult();
    }

    private static MovieNightState Describe(Night night, Guid profileSession, int? knownDeck)
    {
        var you = night.Members.FirstOrDefault(member => member.ProfileSession == profileSession);
        return new MovieNightState(
            night.Id,
            night.Phase,
            night.Revision,
            night.Round,
            night.DeckVersion,
            night.Kinds,
            night.Genre,
            night.GenreOptions,
            night.Members.Select(member => new MovieNightMember(member.Id, member.Name, member.DeviceName, member.IsVoting,
                member.Id == night.HostId, member.ProfileSession == profileSession,
                night.Deck.Count(card => member.Votes.ContainsKey(card.MediaId)))).ToList(),
            knownDeck == night.DeckVersion ? null : night.Deck.ToList(),
            you is null ? [] : night.Deck.Where(card => you.Votes.ContainsKey(card.MediaId))
                .Select(card => new MovieNightVote(card.MediaId, you.Votes[card.MediaId])).ToList(),
            night.Result,
            night.LastAction,
            night.LastActionBy,
            night.Era,
            night.Length);
    }

    private static Member Host(Night night) => night.Members.FirstOrDefault(member => member.Id == night.HostId) ?? night.Members[0];

    private Night Find(Guid id) => nights.TryGetValue(id, out var night) ? night
        : throw new PlaybackException("movie_night_not_found", "This Movie Night has ended.", StatusCodes.Status404NotFound);

    private static Member Membership(Night night, Guid profileSession) =>
        night.Members.FirstOrDefault(member => member.ProfileSession == profileSession)
        ?? throw new PlaybackException("not_in_movie_night", "Join this Movie Night first.", StatusCodes.Status403Forbidden);

    private static string Bounded(string? value, string fallback)
    {
        var text = new string((value ?? "").Where(character => !char.IsControl(character)).ToArray()).Trim();
        if (text.Length == 0) return fallback;
        return text.Length <= MaximumNameLength ? text : text[..MaximumNameLength];
    }

    /// <summary>The titles a deal may use, the host's choices, and a seed so everyone gets one order.</summary>
    public sealed record DealPlan(IReadOnlySet<Guid> Allowed, string Kinds, string? Genre, int Seed, string Era = "any", string Length = "any");

    private sealed class Night(Guid id, Guid hostId, DateTimeOffset createdAt)
    {
        public Guid Id { get; } = id;
        public Guid HostId { get; set; } = hostId;
        public DateTimeOffset CreatedAt { get; } = createdAt;
        public List<Member> Members { get; } = [];
        public string Phase { get; set; } = Lobby;
        public string Kinds { get; set; } = "movies";
        public string? Genre { get; set; }
        public string Era { get; set; } = "any";
        public string Length { get; set; } = "any";
        public List<string> GenreOptions { get; set; } = [];
        public List<MovieNightCard> Deck { get; } = [];
        public HashSet<Guid> Dealt { get; } = [];
        public HashSet<Guid> Discarded { get; } = [];
        public int Round { get; set; }
        public int DeckVersion { get; set; }
        public MovieNightResult? Result { get; set; }
        public long Revision { get; set; } = 1;
        public string? LastAction { get; set; }
        public string? LastActionBy { get; set; }
        public TaskCompletionSource Signal { get; set; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class Member(Guid id, Guid profileSession, string name, string deviceName, DateTimeOffset lastSeen, IReadOnlySet<Guid> shelf)
    {
        public Guid Id { get; } = id;
        public Guid ProfileSession { get; } = profileSession;
        public string Name { get; } = name;
        public string DeviceName { get; } = deviceName;
        public DateTimeOffset LastSeen { get; set; } = lastSeen;
        public IReadOnlySet<Guid> Shelf { get; } = shelf;
        public bool IsVoting { get; set; }
        public bool IsGentle { get; set; }
        public Dictionary<Guid, bool> Votes { get; } = [];
    }
}

/// <summary>
/// What Movie Night says about the result. The gentle lines are for nights with a children's
/// profile in them. {voters}, {likes}, {swipes}, {name} and {n} are filled in.
/// </summary>
internal static class MovieNightLines
{
    public static readonly string[] Match =
    [
        "Finally, something you all agree on. Screenshot this.",
        "Democracy works. Rarely, but tonight it did.",
        "Nobody fight. Nobody go looking for snacks for 20 minutes. Press play.",
        "{voters} people, one title, zero arguments. Historians will study this night.",
        "{swipes} swipes to agree on one thing. Couples therapy takes longer.",
    ];

    public static readonly string[] MatchGentle =
    [
        "Everyone picked the same one. High five!",
        "Teamwork! Go get the popcorn.",
        "You all agree. That's basically magic.",
    ];

    public static readonly string[] Solo =
    [
        "You matched with yourself. Healthy.",
        "Unanimous. It helps when you're the only voter.",
        "One voter, one match. Nobody to blame but you.",
    ];

    public static readonly string[] SoloGentle =
    [
        "You picked it. Great choice!",
        "Your pick, your night. Enjoy!",
    ];

    public static readonly string[] Close =
    [
        "Democracy has spoken: {likes} of {voters} want this. The rest will survive.",
        "Not unanimous, but close enough. Someone is going to sulk.",
        "The least controversial option. Thrilling.",
        "{likes} of {voters} said yes. The others can watch their phones, as usual.",
    ];

    public static readonly string[] CloseGentle =
    [
        "Most of you liked this one. Fair is fair!",
        "{likes} of {voters} said yes. That's a winner!",
    ];

    public static readonly string[] Nothing =
    [
        "Impressive. Deal again, or go read a book like it's 1850.",
        "Not one yes. This family needs a bigger library. Or lower standards.",
        "Zero likes. Even the algorithm is offended.",
    ];

    public static readonly string[] NothingGentle =
    [
        "Nothing fit tonight. Deal another round!",
        "No winner yet. Let's try new cards!",
    ];

    public static readonly string[] Picky =
    [
        "{name} said no {n} times. Blink twice if you're okay.",
        "{name} rejected {n} titles. Hollywood has been informed.",
        "{name}: {n} nopes. Was it something we said?",
    ];

    public static readonly string[] PickyGentle =
    [
        "{name} said no {n} times. Very choosy!",
        "{name} knows exactly what they want: {n} nopes.",
    ];

    public static readonly string[] Easy =
    [
        "{name} liked {n}. Would happily watch a loading screen.",
        "{name} said yes {n} times. Standards: optional.",
        "{name} liked {n}. A golden retriever with a remote.",
    ];

    public static readonly string[] EasyGentle =
    [
        "{name} liked {n}. So easy to please!",
        "{name} said yes {n} times. What a good sport!",
    ];
}
