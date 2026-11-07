using System.ComponentModel;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Library;

namespace Aurelia.Linux.Core.Playback;

public enum PlaybackUserActionKind
{
    Play,
    Pause,
    Seek,
}

/// <summary>Play, pause or seek someone did on this computer, with the position it happened at.</summary>
public sealed record PlaybackUserAction(PlaybackUserActionKind Kind, long PositionMilliseconds);

/// <summary>
/// How a player follows a Watch Together party, as on the Mac: where the shared picture is now,
/// and which few steps bring this player there. Small differences are left alone.
/// </summary>
public static class WatchTogetherFollower
{
    public const long DriftTolerance = 1_500;
    public const long StillTolerance = 500;

    public enum FollowStep
    {
        Play,
        Pause,
        Seek,
    }

    public static bool ShouldPlay(WatchPartyState state) => state.IsPlaying && !state.IsWaiting;

    public static long Position(WatchPartyState state, DateTimeOffset serverNow) =>
        ShouldPlay(state)
            ? state.PositionMilliseconds + (long)Math.Max(0, (serverNow - state.UpdatedAt).TotalMilliseconds)
            : state.PositionMilliseconds;

    public static IReadOnlyList<(FollowStep Step, long Position)> Steps(WatchPartyState state, DateTimeOffset serverNow, long localPosition, bool localPlaying)
    {
        var steps = new List<(FollowStep, long)>();
        var target = Position(state, serverNow);
        var playing = ShouldPlay(state);
        if (Math.Abs(localPosition - target) > (playing ? DriftTolerance : StillTolerance)) steps.Add((FollowStep.Seek, target));
        if (playing != localPlaying) steps.Add((playing ? FollowStep.Play : FollowStep.Pause, target));
        return steps;
    }

    /// <summary>The server's clock minus this computer's, assuming it answered halfway through the request.</summary>
    public static TimeSpan Offset(DateTimeOffset serverTime, DateTimeOffset sent, DateTimeOffset received) =>
        serverTime - (sent + (received - sent) / 2);

    /// <summary>"Mia paused", the last thing someone did, for a short notice in the player.</summary>
    public static string? Notice(WatchPartyState state) => (state.LastAction, state.LastActionBy) switch
    {
        ("play", { } by) => $"{by} pressed play",
        ("pause", { } by) => $"{by} paused",
        ("seek", { } by) => $"{by} jumped to another moment",
        ("joined", { } by) => $"{by} joined",
        ("left", { } by) => $"{by} left",
        ("change", { } by) => $"{by} started {state.Title}",
        _ => null,
    };
}

/// <summary>
/// The party this computer is in: it long-polls the server for changes, makes the attached
/// player follow them and sends what happens here. Remote steps are applied while
/// <c>applyingRemote</c> is set, so they are not sent back as this player's own actions.
/// Everything runs on the thread <c>post</c> hands work to.
/// </summary>
public sealed class WatchTogetherSession(LibraryClient client, string deviceName, TimeProvider time, Action<Action> post) : INotifyPropertyChanged, IDisposable
{
    private readonly HashSet<long> ownRevisions = [];
    private PlaybackController? player;
    private CancellationTokenSource? polling;
    private TimeSpan offset;
    private bool applyingRemote;
    private bool reportedReady;
    private WatchPartyState? state;
    private string? notice;
    private string? error;
    private long noticeGeneration;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Opens another title when the party moves on, such as to the next episode.</summary>
    public Func<Guid, Task>? OpenTitle { get; set; }

    public WatchPartyState? State
    {
        get => state;
        private set { state = value; Changed(nameof(State)); }
    }

    public string? Notice
    {
        get => notice;
        private set { notice = value; Changed(nameof(Notice)); }
    }

    public string? Error
    {
        get => error;
        private set { error = value; Changed(nameof(Error)); }
    }

    /// <summary>Set while this computer opens the party's new title, so closing the old player keeps the party.</summary>
    public bool IsChangingTitle { get; private set; }

    public Task<bool> StartAsync(Guid mediaId, long position, bool playing) =>
        RunAsync(token => client.CreateWatchPartyAsync(new CreateWatchPartyRequest(mediaId, position, playing, deviceName), token));

    public Task<bool> JoinAsync(Guid partyId) =>
        RunAsync(token => client.JoinWatchPartyAsync(partyId, new JoinWatchPartyRequest(deviceName), token));

    public async Task LeaveAsync()
    {
        polling?.Cancel();
        polling?.Dispose();
        polling = null;
        Detach();
        if (State is { } current)
        {
            try { await client.LeaveWatchPartyAsync(current.Id, CancellationToken.None); }
            catch (Exception exception) when (exception is AureliaApiException or HttpRequestException or OperationCanceledException) { }
        }
        State = null;
    }

    public void Dispose()
    {
        polling?.Cancel();
        polling?.Dispose();
        polling = null;
        Detach();
    }

    public void Attach(PlaybackController controller)
    {
        Detach();
        player = controller;
        IsChangingTitle = false;
        reportedReady = false;
        controller.UserAction += Send;
        controller.PropertyChanged += PlayerChanged;
        if (State is { } current) Apply(current);
    }

    /// <summary>Whether this session follows the given player.</summary>
    public bool IsFollowing(PlaybackController controller) => ReferenceEquals(player, controller);

    public void Detach()
    {
        if (player is null) return;
        player.UserAction -= Send;
        player.PropertyChanged -= PlayerChanged;
        player = null;
    }

    /// <summary>Turns the party's state into steps for the player.</summary>
    public void Apply(WatchPartyState current)
    {
        if (player is not { Item: { } item } controller) return;
        if (current.MediaId != item.Id)
        {
            if (IsChangingTitle || OpenTitle is null) return;
            IsChangingTitle = true;
            _ = OpenTitle(current.MediaId);
            return;
        }
        if (controller.State is not (PlayerState.Playing or PlayerState.Paused)) return;
        applyingRemote = true;
        try
        {
            foreach (var (step, position) in WatchTogetherFollower.Steps(current, time.GetUtcNow() + offset, controller.Position, controller.IsPlaying))
            {
                switch (step)
                {
                    case WatchTogetherFollower.FollowStep.Seek: controller.SeekTo(position); break;
                    case WatchTogetherFollower.FollowStep.Play: controller.Play(); break;
                    case WatchTogetherFollower.FollowStep.Pause: controller.Pause(); break;
                }
            }
        }
        finally { applyingRemote = false; }
    }

    private async Task<bool> RunAsync(Func<CancellationToken, Task<WatchPartyState>> action)
    {
        try
        {
            var sent = time.GetUtcNow();
            var next = await action(CancellationToken.None);
            Receive(next, sent, own: true);
            Error = null;
            StartPolling();
            return true;
        }
        catch (Exception exception) when (exception is AureliaApiException or HttpRequestException or OperationCanceledException)
        {
            Error = exception.Message;
            return false;
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
            while (!token.IsCancellationRequested && State is { } current)
            {
                var sent = time.GetUtcNow();
                try
                {
                    var next = await client.WatchPartyAsync(current.Id, current.Revision, 20_000, token);
                    failures = 0;
                    post(() => Receive(next, sent, own: false));
                    await Task.Delay(50, token);
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested)
                {
                    return;
                }
                catch (AureliaApiException failure) when (failure.Status is 403 or 404)
                {
                    post(() => Ended("The Watch Together party has ended."));
                    return;
                }
                catch (Exception exception) when (exception is AureliaApiException or HttpRequestException or OperationCanceledException)
                {
                    if (++failures >= 6)
                    {
                        post(() => Ended("Lost the Watch Together party."));
                        return;
                    }
                    try { await Task.Delay(2000, token); }
                    catch (OperationCanceledException) { return; }
                }
            }
        });
    }

    private void Ended(string message)
    {
        Error = message;
        Detach();
        polling = null;
        State = null;
    }

    private void Receive(WatchPartyState next, DateTimeOffset sent, bool own)
    {
        offset = WatchTogetherFollower.Offset(next.ServerTime, sent, time.GetUtcNow());
        if (own) ownRevisions.Add(next.Revision);
        // Answers can arrive out of order; an older state never undoes a newer one.
        if (State is { } known && known.Id == next.Id && next.Revision < known.Revision) return;
        var isNew = next.Revision != State?.Revision;
        State = next;
        if (isNew && !own && !ownRevisions.Contains(next.Revision) && WatchTogetherFollower.Notice(next) is { } text) Show(text);
        var me = next.Members.FirstOrDefault(member => member.IsYou);
        if (me is { IsBuffering: true } && player is { Item: { } item, State: PlayerState.Playing or PlayerState.Paused } && item.Id == next.MediaId)
            SendCommand(new WatchPartyCommandRequest("ready"));
        Apply(next);
    }

    private void Show(string text)
    {
        Notice = text;
        var generation = ++noticeGeneration;
        _ = Task.Delay(4000).ContinueWith(_ => post(() => { if (generation == noticeGeneration) Notice = null; }), TaskScheduler.Default);
    }

    private void Send(PlaybackUserAction action)
    {
        if (applyingRemote || State is null) return;
        var name = action.Kind switch
        {
            PlaybackUserActionKind.Play => "play",
            PlaybackUserActionKind.Pause => "pause",
            _ => "seek",
        };
        SendCommand(new WatchPartyCommandRequest(name, action.PositionMilliseconds));
    }

    private void PlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (player is not { } controller || State is not { } current) return;
        if (args.PropertyName == nameof(PlaybackController.Item) && controller.Item is { } item && item.Id != current.MediaId && !IsChangingTitle)
        {
            // The player moved on by itself (Up Next, next or previous episode): the party follows.
            reportedReady = false;
            SendCommand(new WatchPartyCommandRequest("change", 0, item.Id));
            return;
        }
        if (args.PropertyName != nameof(PlaybackController.State) || controller.Item?.Id != current.MediaId) return;
        var me = current.Members.FirstOrDefault(member => member.IsYou);
        if (controller.State is PlayerState.Playing or PlayerState.Paused)
        {
            if (me is { IsBuffering: true } || !reportedReady)
            {
                reportedReady = true;
                SendCommand(new WatchPartyCommandRequest("ready"));
            }
            Apply(current);
        }
        else if (controller.State is PlayerState.Loading or PlayerState.Recovering && reportedReady && me is { IsBuffering: false })
        {
            SendCommand(new WatchPartyCommandRequest("buffering"));
        }
    }

    private void SendCommand(WatchPartyCommandRequest request)
    {
        if (State is not { } current) return;
        var sent = time.GetUtcNow();
        _ = Task.Run(async () =>
        {
            try
            {
                var next = await client.WatchPartyCommandAsync(current.Id, request, CancellationToken.None);
                post(() => Receive(next, sent, own: true));
            }
            catch (Exception exception) when (exception is AureliaApiException or HttpRequestException or OperationCanceledException)
            {
                post(() => Error = exception.Message);
            }
        });
    }

    private void Changed(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
