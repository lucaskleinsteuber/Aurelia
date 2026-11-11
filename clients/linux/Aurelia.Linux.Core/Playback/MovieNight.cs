using System.ComponentModel;
using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Playback;

/// <summary>The Movie Night requests; <see cref="Library.LibraryClient"/> answers them, tests fake them.</summary>
public interface IMovieNightApi
{
    Task<IReadOnlyList<MovieNightSummary>> MovieNightsAsync(CancellationToken cancellation);

    Task<MovieNightState> CreateMovieNightAsync(CreateMovieNightRequest request, CancellationToken cancellation);

    Task<MovieNightState> JoinMovieNightAsync(Guid nightId, JoinMovieNightRequest request, CancellationToken cancellation);

    Task<MovieNightState> MovieNightAsync(Guid nightId, long? after, int? deckVersion, int waitMilliseconds, CancellationToken cancellation);

    Task<MovieNightState> MovieNightSettingsAsync(Guid nightId, MovieNightSettingsRequest request, CancellationToken cancellation);

    Task<MovieNightState> DealMovieNightAsync(Guid nightId, CancellationToken cancellation);

    Task<MovieNightState> VoteMovieNightAsync(Guid nightId, MovieNightVoteRequest request, CancellationToken cancellation);

    Task<MovieNightState> KeepSwipingAsync(Guid nightId, CancellationToken cancellation);

    Task<MovieNightState> MovieNightRoleAsync(Guid nightId, MovieNightRoleRequest request, CancellationToken cancellation);

    Task LeaveMovieNightAsync(Guid nightId, CancellationToken cancellation);
}

public enum MovieNightScreen
{
    Intro,
    Lobby,
    Swipe,
    Waiting,
    Match,
    NoMatch,
}

/// <summary>Movie Night's rules that need no window, the same as the other apps'.</summary>
public static class MovieNightRules
{
    /// <summary>How far a card travels, in pixels, before letting go counts as a vote.</summary>
    public const double SwipeDistance = 110;

    /// <summary>True for yes, false for nope, null when the card goes back.</summary>
    public static bool? Choice(double offset, double velocity = 0, double width = 360)
    {
        var limit = Math.Min(SwipeDistance, Math.Max(60, width * 0.3));
        if (offset >= limit || (velocity > 600 && offset > 30)) return true;
        if (offset <= -limit || (velocity < -600 && offset < -30)) return false;
        return null;
    }

    public static IReadOnlyList<MovieNightCard> Remaining(IReadOnlyList<MovieNightCard> deck, IReadOnlyList<MovieNightVote> votes, IReadOnlyDictionary<Guid, bool> pending)
    {
        var voted = votes.Select(vote => vote.MediaId).Concat(pending.Keys).ToHashSet();
        return deck.Where(card => !voted.Contains(card.MediaId)).ToList();
    }

    /// <summary>"1h 52m", "48m", or null.</summary>
    public static string? Runtime(int? minutes)
    {
        if (minutes is not > 0) return null;
        var hours = minutes.Value / 60;
        var rest = minutes.Value % 60;
        if (hours == 0) return $"{rest}m";
        return rest == 0 ? $"{hours}h" : $"{hours}h {rest}m";
    }

    /// <summary>"2019 · 1h 53m · Comedy · Crime".</summary>
    public static string Meta(MovieNightCard card) =>
        string.Join(" · ", new[] { card.Year?.ToString(CultureInfo.InvariantCulture), Runtime(card.RuntimeMinutes) }
            .Concat(card.Genres.Take(2)).Where(part => !string.IsNullOrEmpty(part)));

    public static MovieNightScreen Screen(MovieNightState? state, int remaining) => state?.Phase switch
    {
        null => MovieNightScreen.Intro,
        "lobby" => MovieNightScreen.Lobby,
        "match" => MovieNightScreen.Match,
        "no-match" => MovieNightScreen.NoMatch,
        _ => state.Members.FirstOrDefault(member => member.IsYou)?.IsVoting == true && remaining > 0 ? MovieNightScreen.Swipe : MovieNightScreen.Waiting,
    };

    /// <summary>The voters still swiping, slowest first.</summary>
    public static IReadOnlyList<MovieNightMember> Slowpokes(MovieNightState state, int deckSize) =>
        state.Members.Where(member => member.IsVoting && member.Swiped < deckSize).OrderBy(member => member.Swiped).ToList();
}

/// <summary>Tonight's program: what the host lets the server deal, and how it reads.</summary>
public static class MovieNightProgram
{
    public static readonly IReadOnlyList<(string Key, string Label)> Kinds = [("movies", "Movies"), ("all", "Movies and Shows")];
    public static readonly IReadOnlyList<(string Key, string Label)> Eras =
        [("any", "Any Time"), ("2020s", "2020s"), ("2010s", "2010s"), ("2000s", "2000s"), ("older", "Older")];
    public static readonly IReadOnlyList<(string Key, string Label)> Lengths =
        [("any", "Any Length"), ("short", "Short, up to 1h 40m"), ("standard", "Up to 2h 10m")];

    public static MovieNightSettingsRequest Current(MovieNightState state) =>
        new(state.Kinds, state.Genre, state.Era, state.Length);

    /// <summary>"Movies · Comedy · 2010s · Short".</summary>
    public static string Summary(MovieNightSettingsRequest program) => string.Join(" · ", new[]
    {
        program.Kinds == "all" ? "Movies and Shows" : "Movies",
        program.Genre,
        program.Era is null or "any" ? null : Eras.FirstOrDefault(era => era.Key == program.Era).Label,
        program.Length switch { "short" => "Short", "standard" => "Up to 2h 10m", _ => null },
    }.Where(part => !string.IsNullOrEmpty(part)));
}

/// <summary>
/// The night this computer is in. A swipe counts here at once and is sent behind; the deck is kept
/// between polls, which only carry it again when it changed. <paramref name="post"/> runs a change
/// on the window's thread.
/// </summary>
public sealed class MovieNightSession(IMovieNightApi api, string deviceName, Action<Action> post) : INotifyPropertyChanged, IDisposable
{
    private readonly Dictionary<Guid, bool> pending = [];
    private CancellationTokenSource? polling;
    private MovieNightState? state;
    private IReadOnlyList<MovieNightCard> deck = [];
    private string? error;

    public event PropertyChangedEventHandler? PropertyChanged;

    public MovieNightState? State => state;

    public IReadOnlyList<MovieNightCard> Deck => deck;

    public string? Error
    {
        get => error;
        set { error = value; Changed(nameof(Error)); }
    }

    public IReadOnlyList<MovieNightCard> Remaining =>
        state is null ? [] : MovieNightRules.Remaining(deck, state.YourVotes, pending);

    public MovieNightScreen Screen => MovieNightRules.Screen(state, Remaining.Count);

    public Task StartAsync(bool voting = true) =>
        RunAsync(token => api.CreateMovieNightAsync(new CreateMovieNightRequest(deviceName, voting), token));

    public Task JoinAsync(Guid nightId, bool voting = true) =>
        RunAsync(token => api.JoinMovieNightAsync(nightId, new JoinMovieNightRequest(deviceName, voting), token));

    /// <summary>Changes one part of tonight's program; the other choices stay.</summary>
    public Task SettingsAsync(Func<MovieNightSettingsRequest, MovieNightSettingsRequest> change) => state is { } current
        ? RunAsync(token => api.MovieNightSettingsAsync(current.Id, change(MovieNightProgram.Current(current)), token)) : Task.CompletedTask;

    public Task DealAsync() => state is { } current ? RunAsync(token => api.DealMovieNightAsync(current.Id, token)) : Task.CompletedTask;

    public Task KeepSwipingAsync() => state is { } current ? RunAsync(token => api.KeepSwipingAsync(current.Id, token)) : Task.CompletedTask;

    public Task SetVotingAsync(bool voting) => state is { } current
        ? RunAsync(token => api.MovieNightRoleAsync(current.Id, new MovieNightRoleRequest(voting), token)) : Task.CompletedTask;

    /// <summary>Counts at once; the server's answer follows.</summary>
    public async Task VoteAsync(MovieNightCard card, bool like)
    {
        if (state is not { } current) return;
        pending[card.MediaId] = like;
        Changed(nameof(State));
        try
        {
            Receive(await api.VoteMovieNightAsync(current.Id, new MovieNightVoteRequest(card.MediaId, like), CancellationToken.None));
        }
        catch (Exception exception) when (exception is AureliaApiException or HttpRequestException or OperationCanceledException)
        {
            pending.Remove(card.MediaId);
            Error = exception is AureliaApiException ? exception.Message : "That swipe didn't reach the server. Try it again.";
            Changed(nameof(State));
        }
    }

    public async Task LeaveAsync()
    {
        StopPolling();
        if (state is { } current)
        {
            try { await api.LeaveMovieNightAsync(current.Id, CancellationToken.None); }
            catch (Exception exception) when (exception is AureliaApiException or HttpRequestException or OperationCanceledException) { }
        }
        state = null;
        deck = [];
        pending.Clear();
        Changed(nameof(State));
    }

    public void Dispose() => StopPolling();

    /// <summary>Takes a state from the server; an older one never undoes a newer one.</summary>
    public void Receive(MovieNightState next)
    {
        if (state is { } current && current.Id == next.Id && next.Revision < current.Revision) return;
        if (next.Deck is { } nextDeck)
        {
            deck = nextDeck;
            var inDeck = nextDeck.Select(card => card.MediaId).ToHashSet();
            foreach (var id in pending.Keys.Where(id => !inDeck.Contains(id)).ToList()) pending.Remove(id);
        }
        if (state is { } previous && previous.Round != next.Round) pending.Clear();
        foreach (var vote in next.YourVotes) pending.Remove(vote.MediaId);
        state = next;
        Changed(nameof(State));
    }

    private async Task RunAsync(Func<CancellationToken, Task<MovieNightState>> action)
    {
        try
        {
            Receive(await action(CancellationToken.None));
            Error = null;
            StartPolling();
        }
        catch (Exception exception) when (exception is AureliaApiException or HttpRequestException or OperationCanceledException)
        {
            Error = exception is AureliaApiException ? exception.Message : "Movie Night isn't available right now.";
        }
    }

    private void StartPolling()
    {
        if (polling is not null) return;
        var cancel = polling = new CancellationTokenSource();
        var token = cancel.Token;
        _ = Task.Run(async () =>
        {
            var failures = 0;
            while (!token.IsCancellationRequested && state is { } current)
            {
                try
                {
                    var next = await api.MovieNightAsync(current.Id, current.Revision, current.DeckVersion, 20_000, token);
                    failures = 0;
                    post(() => Receive(next));
                    await Task.Delay(50, token);
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested)
                {
                    return;
                }
                catch (AureliaApiException failure) when (failure.Status is 403 or 404)
                {
                    post(() => Ended("This Movie Night has ended."));
                    return;
                }
                catch (Exception exception) when (exception is AureliaApiException or HttpRequestException or OperationCanceledException)
                {
                    if (++failures >= 6)
                    {
                        post(() => Ended("Lost the connection to Movie Night."));
                        return;
                    }
                    try { await Task.Delay(2000, token); }
                    catch (OperationCanceledException) { return; }
                }
            }
        }, token);
    }

    private void StopPolling()
    {
        polling?.Cancel();
        polling?.Dispose();
        polling = null;
    }

    private void Ended(string message)
    {
        polling = null;
        state = null;
        deck = [];
        pending.Clear();
        Error = message;
        Changed(nameof(State));
    }

    private void Changed(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>Wrapped's story rules: colors, counting up and moving between slides.</summary>
public static class WrappedStory
{
    public static readonly TimeSpan SlideTime = TimeSpan.FromSeconds(6);

    /// <summary>The newest month whose Wrapped is ready: last month from the 2nd on, else the one before.</summary>
    public static (int Year, int Month, string Name) ReadyMonth(DateTime today)
    {
        var first = new DateTime(today.Year, today.Month, 1).AddMonths(today.Day >= 2 ? -1 : -2);
        return (first.Year, first.Month, CultureInfo.InvariantCulture.DateTimeFormat.GetMonthName(first.Month));
    }

    /// <summary>Home shows the new month in its first week, from the 2nd to the 8th.</summary>
    public static bool MonthIsNew(DateTime today) => today.Day is >= 2 and <= 8;

    /// <summary>A color field and the ink and sticker on it, as #RRGGBB.</summary>
    public sealed record Accent(string Field, string Ink, string Sticker);

    public static readonly IReadOnlyDictionary<string, Accent> Accents = new Dictionary<string, Accent>
    {
        ["night"] = new("#171A3A", "#F2F0FF", "#5B7CFF"),
        ["ember"] = new("#FF5A36", "#1C0600", "#1C0600"),
        ["violet"] = new("#6A4CFF", "#FFFFFF", "#FFD84D"),
        ["gold"] = new("#F6B92B", "#1E1400", "#1E1400"),
        ["rose"] = new("#FF4D88", "#22000F", "#22000F"),
        ["mint"] = new("#33D39A", "#00180E", "#00180E"),
        ["ocean"] = new("#1D8BFF", "#FFFFFF", "#0B1A3A"),
        ["lime"] = new("#C4EE34", "#131A00", "#131A00"),
    };

    public static Accent For(string? name) => name is not null && Accents.TryGetValue(name, out var accent) ? accent : Accents["night"];

    /// <summary>The number to count up to, when the big text is a plain number ("143", not "02:47").</summary>
    public static int? CountTarget(string? text) =>
        text is { Length: > 0 and <= 6 } && text.All(char.IsAsciiDigit) ? int.Parse(text, CultureInfo.InvariantCulture) : null;

    /// <summary>The number <paramref name="fraction"/> (0…1) into the count, easing out so it lands softly.</summary>
    public static int CountValue(int target, double fraction)
    {
        var t = Math.Clamp(fraction, 0, 1);
        return (int)Math.Round(target * (1 - Math.Pow(1 - t, 3)));
    }

    /// <summary>The slide after a click; null past the last one, which closes the story.</summary>
    public static int? Step(int index, int count, bool forward) =>
        forward ? (index + 1 < count ? index + 1 : null) : Math.Max(0, index - 1);
}
