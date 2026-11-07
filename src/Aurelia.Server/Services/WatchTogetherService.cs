using Aurelia.Contracts;

namespace Aurelia.Server.Services;

/// <summary>
/// Watch Together parties, in memory only. A member is one profile on one device (its profile
/// session); it stays while it asks for the party at least every <see cref="MemberTimeout"/>.
/// A member that loads or buffers holds everyone at the same picture for at most
/// <see cref="BufferingLimit"/>, so one slow device cannot stop the others for long.
/// </summary>
public sealed class WatchTogetherService(TimeProvider clock)
{
    public static readonly TimeSpan MemberTimeout = TimeSpan.FromSeconds(40);
    public static readonly TimeSpan BufferingLimit = TimeSpan.FromSeconds(30);
    public const int MaximumParties = 32;
    public const int MaximumMembers = 16;
    public const int MaximumWaitMilliseconds = 25_000;
    private const int MaximumNameLength = 100;

    private readonly object gate = new();
    private readonly Dictionary<Guid, Party> parties = [];

    /// <summary>Parties on this server, for the titles <paramref name="visible"/> allows.</summary>
    public IReadOnlyList<WatchPartySummary> List(Func<Guid, bool> visible, Guid? mediaId)
    {
        lock (gate)
        {
            Maintain();
            return parties.Values
                .Where(party => (mediaId is null || party.MediaId == mediaId) && visible(party.MediaId))
                .OrderBy(party => party.CreatedAt)
                .Select(party => new WatchPartySummary(party.Id, party.MediaId, party.Title,
                    party.Members.FirstOrDefault(member => member.Id == party.HostId)?.Name ?? party.Members.First().Name,
                    party.Members.Count, party.IsPlaying))
                .ToList();
        }
    }

    public WatchPartyState Create(Guid profileSession, string name, string? device, Guid mediaId, string title, long position, bool playing)
    {
        lock (gate)
        {
            Maintain();
            LeaveAll(profileSession);
            if (parties.Count >= MaximumParties)
                throw new PlaybackException("too_many_parties", "Too many Watch Together parties are open on this server.", StatusCodes.Status429TooManyRequests);
            var now = clock.GetUtcNow();
            var member = new Member(Guid.NewGuid(), profileSession, Bounded(name, "Someone"), Bounded(device, "Unknown Device"), now);
            var party = new Party(Guid.NewGuid(), member.Id, now)
            {
                MediaId = mediaId,
                Title = Bounded(title, "Untitled"),
                IsPlaying = playing,
                PositionMilliseconds = Math.Max(0, position),
                UpdatedAt = now,
                LastAction = "started",
                LastActionBy = member.Name,
            };
            party.Members.Add(member);
            parties[party.Id] = party;
            return Describe(party, profileSession);
        }
    }

    public WatchPartyState Join(Guid partyId, Guid profileSession, string name, string? device, Func<Guid, bool> visible)
    {
        lock (gate)
        {
            Maintain();
            var party = Find(partyId);
            if (!visible(party.MediaId)) throw NotFound();
            if (party.Members.FirstOrDefault(member => member.ProfileSession == profileSession) is { } existing)
            {
                existing.LastSeen = clock.GetUtcNow();
                return Describe(party, profileSession);
            }
            LeaveAll(profileSession);
            if (party.Members.Count >= MaximumMembers)
                throw new PlaybackException("party_full", "This Watch Together party is full.", StatusCodes.Status409Conflict);
            var now = clock.GetUtcNow();
            // A new member first loads the title; everyone waits for it at the same picture.
            var member = new Member(Guid.NewGuid(), profileSession, Bounded(name, "Someone"), Bounded(device, "Unknown Device"), now) { BufferingSince = now };
            Freeze(party, now);
            party.Members.Add(member);
            Changed(party, "joined", member.Name);
            return Describe(party, profileSession);
        }
    }

    /// <summary>The state once its revision is newer than <paramref name="after"/>, or after the wait.</summary>
    public async Task<WatchPartyState> WaitAsync(Guid partyId, Guid profileSession, long? after, int waitMilliseconds, CancellationToken token)
    {
        Task changed;
        lock (gate)
        {
            Maintain();
            var party = Find(partyId);
            var member = Membership(party, profileSession);
            member.LastSeen = clock.GetUtcNow();
            if (after is null || party.Revision > after || waitMilliseconds <= 0) return Describe(party, profileSession);
            changed = party.Signal.Task;
        }
        var wait = Math.Clamp(waitMilliseconds, 0, MaximumWaitMilliseconds);
        await Task.WhenAny(changed, Task.Delay(TimeSpan.FromMilliseconds(wait), clock, token));
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            Maintain();
            var party = Find(partyId);
            Membership(party, profileSession).LastSeen = clock.GetUtcNow();
            return Describe(party, profileSession);
        }
    }

    /// <summary>Applies one member's command. <paramref name="title"/> names a new title for <c>change</c>.</summary>
    public WatchPartyState Command(Guid partyId, Guid profileSession, WatchPartyCommandRequest request, string? title = null)
    {
        lock (gate)
        {
            Maintain();
            var party = Find(partyId);
            var member = Membership(party, profileSession);
            var now = clock.GetUtcNow();
            member.LastSeen = now;
            var position = request.PositionMilliseconds is { } requested ? Math.Max(0, requested) : Position(party, now);
            switch (request.Action?.Trim().ToLowerInvariant())
            {
                case "play":
                    party.PositionMilliseconds = position;
                    party.UpdatedAt = now;
                    party.IsPlaying = true;
                    Changed(party, "play", member.Name);
                    break;
                case "pause":
                    party.PositionMilliseconds = position;
                    party.UpdatedAt = now;
                    party.IsPlaying = false;
                    Changed(party, "pause", member.Name);
                    break;
                case "seek":
                    party.PositionMilliseconds = position;
                    party.UpdatedAt = now;
                    Changed(party, "seek", member.Name);
                    break;
                case "buffering":
                    if (member.BufferingSince is null)
                    {
                        Freeze(party, now);
                        member.BufferingSince = now;
                        Changed(party, "buffering", member.Name);
                    }
                    break;
                case "ready":
                    if (member.BufferingSince is not null)
                    {
                        var wasWaiting = Waiting(party, now);
                        member.BufferingSince = null;
                        if (wasWaiting && !Waiting(party, now)) party.UpdatedAt = now;
                        Changed(party, "ready", member.Name);
                    }
                    break;
                case "change":
                    if (request.MediaId is not { } media || title is null)
                        throw new PlaybackException("invalid_party_command", "Choose a title for the party.", StatusCodes.Status400BadRequest);
                    party.MediaId = media;
                    party.Title = Bounded(title, "Untitled");
                    party.PositionMilliseconds = request.PositionMilliseconds ?? 0;
                    party.UpdatedAt = now;
                    party.IsPlaying = true;
                    // Everyone loads the new title; the party starts together once all are ready.
                    foreach (var each in party.Members) each.BufferingSince = now;
                    Changed(party, "change", member.Name);
                    break;
                default:
                    throw new PlaybackException("invalid_party_command", "The Watch Together command is not known.", StatusCodes.Status400BadRequest);
            }
            return Describe(party, profileSession);
        }
    }

    public void Leave(Guid partyId, Guid profileSession)
    {
        lock (gate)
        {
            if (!parties.TryGetValue(partyId, out var party)) return;
            Remove(party, profileSession);
        }
    }

    /// <summary>Removes a profile session from every party, for example when it signs out.</summary>
    public void LeaveAll(Guid profileSession)
    {
        lock (gate)
        {
            foreach (var party in parties.Values.ToList()) Remove(party, profileSession);
        }
    }

    public IReadOnlyList<Guid> MediaIds()
    {
        lock (gate) return parties.Values.Select(party => party.MediaId).Distinct().ToList();
    }

    public Guid? MediaOf(Guid partyId)
    {
        lock (gate) return parties.TryGetValue(partyId, out var party) ? party.MediaId : null;
    }

    private void Remove(Party party, Guid profileSession)
    {
        var member = party.Members.FirstOrDefault(each => each.ProfileSession == profileSession);
        if (member is null) return;
        var now = clock.GetUtcNow();
        var wasWaiting = Waiting(party, now);
        party.Members.Remove(member);
        if (party.Members.Count == 0)
        {
            parties.Remove(party.Id);
            party.Signal.TrySetResult();
            return;
        }
        if (party.HostId == member.Id) party.HostId = party.Members[0].Id;
        if (wasWaiting && !Waiting(party, now)) party.UpdatedAt = now;
        Changed(party, "left", member.Name);
    }

    /// <summary>Drops members that stopped asking and buffering that took too long.</summary>
    private void Maintain()
    {
        var now = clock.GetUtcNow();
        foreach (var party in parties.Values.ToList())
        {
            foreach (var gone in party.Members.Where(member => now - member.LastSeen > MemberTimeout).ToList())
                Remove(party, gone.ProfileSession);
            if (!parties.ContainsKey(party.Id)) continue;
            var wasWaiting = party.Members.Any(member => member.BufferingSince is not null);
            var expired = party.Members.Where(member => member.BufferingSince is { } since && now - since > BufferingLimit).ToList();
            if (expired.Count == 0) continue;
            foreach (var member in expired) member.BufferingSince = null;
            if (wasWaiting && !Waiting(party, now))
            {
                // The position stayed frozen since the wait began; play on from there.
                party.UpdatedAt = now;
            }
            Changed(party, "ready", expired[0].Name);
        }
    }

    private static bool Waiting(Party party, DateTimeOffset now) =>
        party.Members.Any(member => member.BufferingSince is { } since && now - since <= BufferingLimit);

    /// <summary>Stores the current position so that a wait starts exactly where everyone is.</summary>
    private static void Freeze(Party party, DateTimeOffset now)
    {
        party.PositionMilliseconds = Position(party, now);
        party.UpdatedAt = now;
    }

    private static long Position(Party party, DateTimeOffset now) =>
        party.IsPlaying && !Waiting(party, now)
            ? party.PositionMilliseconds + (long)Math.Max(0, (now - party.UpdatedAt).TotalMilliseconds)
            : party.PositionMilliseconds;

    private static void Changed(Party party, string action, string by)
    {
        party.Revision++;
        party.LastAction = action;
        party.LastActionBy = by;
        var signal = party.Signal;
        party.Signal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        signal.TrySetResult();
    }

    private WatchPartyState Describe(Party party, Guid profileSession)
    {
        var now = clock.GetUtcNow();
        var waiting = Waiting(party, now);
        // While waiting the stored position is frozen; UpdatedAt is moved to now so a client that
        // computes "position + elapsed" never runs ahead.
        return new WatchPartyState(party.Id, party.MediaId, party.Title, party.IsPlaying, waiting,
            party.PositionMilliseconds, waiting ? now : party.UpdatedAt, now, party.Revision,
            party.Members.Select(member => new WatchPartyMember(member.Id, member.Name, member.DeviceName,
                member.BufferingSince is { } since && now - since <= BufferingLimit, member.Id == party.HostId, member.ProfileSession == profileSession)).ToList(),
            party.LastAction, party.LastActionBy);
    }

    private Party Find(Guid id) => parties.TryGetValue(id, out var party) ? party : throw NotFound();

    private static Member Membership(Party party, Guid profileSession) =>
        party.Members.FirstOrDefault(member => member.ProfileSession == profileSession)
        ?? throw new PlaybackException("not_in_party", "Join this Watch Together party first.", StatusCodes.Status403Forbidden);

    private static PlaybackException NotFound() =>
        new("party_not_found", "This Watch Together party has ended.", StatusCodes.Status404NotFound);

    private static string Bounded(string? value, string fallback)
    {
        var text = new string((value ?? "").Where(character => !char.IsControl(character)).ToArray()).Trim();
        if (text.Length == 0) return fallback;
        return text.Length <= MaximumNameLength ? text : text[..MaximumNameLength];
    }

    private sealed class Party(Guid id, Guid hostId, DateTimeOffset createdAt)
    {
        public Guid Id { get; } = id;
        public Guid HostId { get; set; } = hostId;
        public DateTimeOffset CreatedAt { get; } = createdAt;
        public List<Member> Members { get; } = [];
        public Guid MediaId { get; set; }
        public string Title { get; set; } = "";
        public bool IsPlaying { get; set; }
        public long PositionMilliseconds { get; set; }
        public DateTimeOffset UpdatedAt { get; set; }
        public long Revision { get; set; } = 1;
        public string? LastAction { get; set; }
        public string? LastActionBy { get; set; }
        public TaskCompletionSource Signal { get; set; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class Member(Guid id, Guid profileSession, string name, string deviceName, DateTimeOffset lastSeen)
    {
        public Guid Id { get; } = id;
        public Guid ProfileSession { get; } = profileSession;
        public string Name { get; } = name;
        public string DeviceName { get; } = deviceName;
        public DateTimeOffset LastSeen { get; set; } = lastSeen;
        public DateTimeOffset? BufferingSince { get; set; }
    }
}
