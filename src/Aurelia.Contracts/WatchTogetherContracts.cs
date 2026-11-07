namespace Aurelia.Contracts;

/// <summary>
/// Watch Together: several devices at home play the same title in step. The server keeps the
/// shared state (title, playing or paused, position at a server time); each player follows it
/// and sends its own play, pause and seek as commands. Parties live in memory only.
/// </summary>
public sealed record WatchPartySummary(
    Guid Id,
    Guid MediaId,
    string Title,
    string HostName,
    int MemberCount,
    bool IsPlaying);

public sealed record WatchPartyMember(
    Guid Id,
    string Name,
    string DeviceName,
    bool IsBuffering,
    bool IsHost,
    bool IsYou);

/// <summary>
/// The shared state. While <see cref="IsPlaying"/> is true and nobody is buffering, the position
/// now is <see cref="PositionMilliseconds"/> plus the time since <see cref="UpdatedAt"/>;
/// <see cref="ServerTime"/> lets a client measure its clock offset.
/// </summary>
public sealed record WatchPartyState(
    Guid Id,
    Guid MediaId,
    string Title,
    bool IsPlaying,
    bool IsWaiting,
    long PositionMilliseconds,
    DateTimeOffset UpdatedAt,
    DateTimeOffset ServerTime,
    long Revision,
    IReadOnlyList<WatchPartyMember> Members,
    string? LastAction,
    string? LastActionBy);

public sealed record CreateWatchPartyRequest(
    Guid MediaId,
    long PositionMilliseconds,
    bool IsPlaying,
    string? DeviceName);

public sealed record JoinWatchPartyRequest(string? DeviceName);

/// <summary>
/// <c>play</c>, <c>pause</c> and <c>seek</c> change the shared state; <c>buffering</c> and
/// <c>ready</c> say this player is waiting for its video, which holds everyone until it is
/// ready; <c>change</c> moves the party to another title (<see cref="MediaId"/>), such as the
/// next episode.
/// </summary>
public sealed record WatchPartyCommandRequest(
    string Action,
    long? PositionMilliseconds = null,
    Guid? MediaId = null);
