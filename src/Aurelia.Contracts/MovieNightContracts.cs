namespace Aurelia.Contracts;

/// <summary>
/// Movie Night: everyone at home swipes through the same deck of titles from the library, and
/// the first title every voter liked is the match. A device can also join as a screen that only
/// shows the lobby, the progress and the match, such as an Apple TV. Nights live in memory only.
/// Nobody learns another member's votes, only how many cards each has swiped.
/// </summary>
public sealed record MovieNightSummary(
    Guid Id,
    string HostName,
    string HostDevice,
    int MemberCount,
    string Phase);

public sealed record MovieNightMember(
    Guid Id,
    string Name,
    string DeviceName,
    bool IsVoting,
    bool IsHost,
    bool IsYou,
    int Swiped);

public sealed record MovieNightCard(
    Guid MediaId,
    MediaKind Kind,
    string Title,
    int? Year,
    string? Overview,
    IReadOnlyList<string> Genres,
    int? RuntimeMinutes,
    ArtworkSummary? Poster,
    ArtworkSummary? Backdrop);

public sealed record MovieNightVote(Guid MediaId, bool Like);

/// <summary>A cheeky title for one member once the night has a result, such as "Hardest to please".</summary>
public sealed record MovieNightAward(string Title, string Name, string Line);

/// <summary>
/// The match, or without one the title most voters liked. <see cref="Card"/> is null when
/// nobody liked anything.
/// </summary>
public sealed record MovieNightResult(
    MovieNightCard? Card,
    int Likes,
    int Voters,
    bool IsUnanimous,
    string Headline,
    string Line,
    IReadOnlyList<MovieNightAward> Awards);

/// <summary>
/// <see cref="Phase"/> is <c>lobby</c>, <c>voting</c>, <c>match</c> or <c>no-match</c>.
/// <see cref="Deck"/> is the same for everyone and in the same order; it is left out (null) when
/// the request named the current <see cref="DeckVersion"/>, so a long poll stays small.
/// </summary>
public sealed record MovieNightState(
    Guid Id,
    string Phase,
    long Revision,
    int Round,
    int DeckVersion,
    string Kinds,
    string? Genre,
    IReadOnlyList<string> GenreOptions,
    IReadOnlyList<MovieNightMember> Members,
    IReadOnlyList<MovieNightCard>? Deck,
    IReadOnlyList<MovieNightVote> YourVotes,
    MovieNightResult? Result,
    string? LastAction,
    string? LastActionBy);

/// <summary><see cref="IsVoting"/> false joins as a screen that only watches.</summary>
public sealed record CreateMovieNightRequest(string? DeviceName, bool IsVoting = true);

public sealed record JoinMovieNightRequest(string? DeviceName, bool IsVoting = true);

/// <summary><see cref="Kinds"/> is <c>movies</c> or <c>all</c> (movies and shows); a null genre means any.</summary>
public sealed record MovieNightSettingsRequest(string? Kinds, string? Genre);

public sealed record MovieNightVoteRequest(Guid MediaId, bool Like);

public sealed record MovieNightRoleRequest(bool IsVoting);
