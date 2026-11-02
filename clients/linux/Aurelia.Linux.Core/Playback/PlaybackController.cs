using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Playback;

public enum PlayerState
{
    Loading,
    Playing,
    Paused,
    Recovering,
    Failed,
}

/// <summary>Off, at the end of the episode, or after a number of minutes.</summary>
public sealed record SleepTimer(int Minutes, bool EndOfEpisode)
{
    public static readonly SleepTimer Off = new(0, false);
    public static readonly SleepTimer AtEndOfEpisode = new(0, true);
    public static readonly int[] Choices = [15, 30, 45, 60, 90, 120];

    public bool IsOn => Minutes > 0 || EndOfEpisode;
}

/// <summary>What the desktop learns about playback: media keys and Now Playing (MPRIS), keeping the screen awake.</summary>
public interface IPlaybackSystem
{
    void KeepAwake(bool awake);

    void Update(PlaybackController? controller);
}

public sealed class NoPlaybackSystem : IPlaybackSystem
{
    public void KeepAwake(bool awake)
    {
    }

    public void Update(PlaybackController? controller)
    {
    }
}

/// <summary>
/// One playback, as the Mac app's PlaybackController runs it: a ticket and the loopback relay; VLC
/// opened at the resume position; remembered tracks and the server's sidecar subtitles; progress
/// every 15 seconds and at every pause, seek, end and close; Up Next and the next episode; the sleep
/// timer; ticket renewal five minutes before expiry; recovery when the stream stalls or breaks
/// (1, 2, 4, 8, 15, 30 s, at most two minutes). Call it from the interface thread; engine events are
/// moved there with <paramref name="post"/>.
/// </summary>
public sealed class PlaybackController : ObservableObject, IAsyncDisposable
{
    public static readonly TimeSpan ProgressInterval = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan RenewalLead = TimeSpan.FromMinutes(5);
    public static readonly TimeSpan StallLimit = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan FirstFrameLimit = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan RecoveryBudget = TimeSpan.FromSeconds(120);
    public static readonly int[] RecoveryDelays = [1, 2, 4, 8, 15, 30];

    private readonly PlaybackClient client;
    private readonly IVideoEngineFactory engines;
    private readonly ISettingsStore settings;
    private readonly ProgressOutbox outbox;
    private readonly TimeProvider time;
    private readonly Action<Action> post;
    private readonly IPlaybackSystem system;
    private readonly TrackMemory memory;
    private readonly List<CatalogItemSummary> queue = [];
    private readonly Stack<CatalogItemSummary> previous = new();
    private ITimer? clock;
    private IVideoEngine? engine;
    private LoopbackStreamRelay? relay;
    private PlaybackSourceResponse? ticket;
    private CatalogItemSummary? item;
    private Guid? seriesId;
    private long revision;
    private PlayerState state = PlayerState.Loading;
    private long position;
    private long duration;
    private double rate;
    private double volume;
    private bool muted;
    private IReadOnlyList<MediaTrack> audioTracks = [];
    private IReadOnlyList<MediaTrack> subtitleTracks = [];
    private int audioTrack = -1;
    private int subtitleTrack = -1;
    private IReadOnlyList<PlaybackChapter> chapters = [];
    private int chapter = -1;
    private bool tracksApplied;
    private bool pauseAfterReopen;
    private SleepTimer sleepTimer = SleepTimer.Off;
    private DateTimeOffset? sleepAt;
    private bool upNextDismissed;
    private string? error;
    private bool hasConflict;
    private bool observedPlayback;
    private bool closed;
    private DateTimeOffset lastSave;
    private DateTimeOffset lastMovement;
    private DateTimeOffset openedAt;
    private long lastClock = -1;
    private DateTimeOffset? recoveryStarted;
    private int recoveryAttempt;
    private DateTimeOffset stableSince;

    public PlaybackController(PlaybackClient client, IVideoEngineFactory engines, ISettingsStore settings, ProgressOutbox outbox,
        TimeProvider time, Action<Action> post, IPlaybackSystem? system = null)
    {
        this.client = client;
        this.engines = engines;
        this.settings = settings;
        this.outbox = outbox;
        this.time = time;
        Diagnostics = new PlaybackDiagnostics(time);
        this.post = post;
        this.system = system ?? new NoPlaybackSystem();
        memory = new TrackMemory(settings, client.Library.Profile.User.Id);
        Preferences = PlaybackPreferences.Load(settings);
        rate = Preferences.DefaultRate;
        volume = Preferences.DefaultVolume;
    }

    /// <summary>Raised once when the player should close (the person closed it, the title ended or the sleep timer fired).</summary>
    public event Action? Closed;

    public PlaybackPreferences Preferences { get; private set; }

    public PlaybackDiagnostics Diagnostics { get; }

    public CatalogItemSummary? Item
    {
        get => item;
        private set
        {
            if (!SetProperty(ref item, value)) return;
            OnPropertyChanged(nameof(Title));
            OnPropertyChanged(nameof(Subtitle));
        }
    }

    public string Title => Item?.Title ?? "";

    /// <summary>"Cobalt Station · S1 E2" for episodes, the year for movies.</summary>
    public string Subtitle => Item is { Kind: MediaKind.Episode } episode
        ? $"{episode.ParentTitle} · S{episode.SeasonNumber} E{episode.EpisodeNumber}"
        : Item?.Year?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "";

    public PlayerState State
    {
        get => state;
        private set
        {
            if (!SetProperty(ref state, value)) return;
            Record(PlaybackDiagnosticKind.StateChanged);
            system.KeepAwake(Preferences.PreventSleep && value is PlayerState.Playing or PlayerState.Loading or PlayerState.Recovering);
            system.Update(this);
        }
    }

    public bool IsPlaying => State == PlayerState.Playing;

    public long Position
    {
        get => position;
        private set => SetProperty(ref position, value);
    }

    public long Duration
    {
        get => duration;
        private set => SetProperty(ref duration, value);
    }

    public double Rate
    {
        get => rate;
        set
        {
            if (!PlayerPolicy.Rates.Contains(value) || !SetProperty(ref rate, value)) return;
            if (engine is not null) engine.Rate = value;
        }
    }

    /// <summary>0 to 1.</summary>
    public double Volume
    {
        get => volume;
        set
        {
            if (!SetProperty(ref volume, Math.Clamp(value, 0, 1))) return;
            if (engine is not null) engine.Volume = (int)Math.Round(volume * 100);
        }
    }

    public bool Muted
    {
        get => muted;
        set
        {
            if (!SetProperty(ref muted, value)) return;
            if (engine is not null) engine.Muted = value;
        }
    }

    public IReadOnlyList<MediaTrack> AudioTracks
    {
        get => audioTracks;
        private set => SetProperty(ref audioTracks, value);
    }

    public IReadOnlyList<MediaTrack> SubtitleTracks
    {
        get => subtitleTracks;
        private set => SetProperty(ref subtitleTracks, value);
    }

    public int AudioTrack
    {
        get => audioTrack;
        private set => SetProperty(ref audioTrack, value);
    }

    public int SubtitleTrack
    {
        get => subtitleTrack;
        private set => SetProperty(ref subtitleTrack, value);
    }

    public IReadOnlyList<PlaybackChapter> Chapters
    {
        get => chapters;
        private set => SetProperty(ref chapters, value);
    }

    public int Chapter
    {
        get => chapter;
        private set => SetProperty(ref chapter, value);
    }

    public void SelectChapter(PlaybackChapter selected)
    {
        if (engine is null || !Chapters.Contains(selected)) return;
        engine.Chapter = selected.Index;
        Chapter = selected.Index;
        SeekTo(selected.PositionMilliseconds);
    }

    public SleepTimer SleepTimer
    {
        get => sleepTimer;
        private set => SetProperty(ref sleepTimer, value);
    }

    /// <summary>Time left on a minutes sleep timer.</summary>
    public TimeSpan? SleepRemaining => sleepAt is { } at ? at - time.GetUtcNow() : null;

    public CatalogItemSummary? NextItem => queue.Count > 0 ? queue[0] : null;

    public bool HasPrevious => previous.Count > 0;

    /// <summary>The Up Next card's title while it shows, else null.</summary>
    public CatalogItemSummary? UpNext => NextItem is { } next
        && PlayerPolicy.ShowsUpNext(Position, Duration, true, Preferences.AutoplayNextEpisode, SleepTimer.EndOfEpisode, upNextDismissed, Preferences.UpNextCountdownSeconds)
        ? next
        : null;

    public int UpNextSeconds => PlayerPolicy.UpNextSeconds(Position, Duration);

    public string? Error
    {
        get => error;
        private set => SetProperty(ref error, value);
    }

    /// <summary>Another device saved a different position; the player offers to keep this computer's.</summary>
    public bool HasConflict
    {
        get => hasConflict;
        private set => SetProperty(ref hasConflict, value);
    }

    public PlaybackClient Client => client;

    public IScrubPreviewDecoderFactory? PreviewDecoders => engines as IScrubPreviewDecoderFactory;

    /// <summary>A separate relay for a local timeline still, using the current ticket and its pinned connection.</summary>
    public LoopbackStreamRelay? CreatePreviewRelay() => ticket is { } current
        ? new LoopbackStreamRelay(client.StreamConnection, client.StreamToken, client.StreamUri(current), "preview") : null;

    /// <summary>The decoder in use; it changes when the title or Night Mode changes, or after recovery.</summary>
    public IVideoEngine? Engine => engine;

    /// <summary>Starts a title: a series plays its next episode, an episode continues with the ones after it.</summary>
    public async Task StartAsync(CatalogItemSummary title, bool resume, long? startAt = null)
    {
        Record(PlaybackDiagnosticKind.Started);
        var target = title;
        queue.Clear();
        previous.Clear();
        if (client.Library.Supports("library-state-v1") && title.Kind is MediaKind.Series or MediaKind.Episode)
        {
            try
            {
                var plan = await client.Library.PlaybackPlanAsync(title.Id, CancellationToken.None);
                target = plan.Target ?? title;
                seriesId = plan.SeriesId;
                queue.AddRange(plan.Queue.Where(next => next.Id != target.Id));
                resume = resume || plan.Action == PlaybackPlanAction.Resume;
            }
            catch (AureliaApiException failure) when (!failure.IsAuthenticationFailure)
            {
                // Without a plan the chosen title still plays.
            }
        }
        seriesId ??= target.Kind == MediaKind.Episode ? target.ParentId : null;
        await LoadAsync(target, startAt ?? (resume ? null : 0));
    }

    public void PlayPause()
    {
        if (engine is null) return;
        if (State == PlayerState.Playing)
        {
            engine.Pause();
            State = PlayerState.Paused;
            _ = SaveProgressAsync(finished: false);
        }
        else if (State == PlayerState.Paused)
        {
            pauseAfterReopen = false;
            engine.Play();
            State = PlayerState.Playing;
        }
    }

    /// <summary>Seeks by the seek interval (Settings › Playback), forward or back.</summary>
    public void SeekBy(bool forward) => SeekTo(Position + (forward ? 1 : -1) * Preferences.SeekIntervalSeconds * 1000L);

    public void SeekTo(long milliseconds)
    {
        if (engine is null) return;
        var target = PlayerPolicy.Clamp(milliseconds, Duration);
        engine.Seek(target);
        Position = target;
        Record(PlaybackDiagnosticKind.Seeked);
        upNextDismissed = false;
        lastMovement = time.GetUtcNow();
        _ = SaveProgressAsync(finished: false);
        RaiseClockChanged();
    }

    public void SelectAudio(MediaTrack track)
    {
        if (engine is null) return;
        engine.AudioTrack = track.Id;
        AudioTrack = track.Id;
        Record(PlaybackDiagnosticKind.AudioChanged);
        memory.RememberAudio(track, seriesId);
    }

    /// <summary>Null turns subtitles off.</summary>
    public void SelectSubtitle(MediaTrack? track)
    {
        if (engine is null) return;
        engine.SubtitleTrack = track?.Id ?? -1;
        SubtitleTrack = track?.Id ?? -1;
        Record(PlaybackDiagnosticKind.SubtitleChanged);
        memory.RememberSubtitle(track, seriesId);
    }

    public Task SetNightModeAsync(bool on) => SetVolumeLevelingAsync(on ? VolumeLeveling.Standard : VolumeLeveling.Off);

    public void SetDialogueBoost(DialogueBoost mode)
    {
        if (Preferences.DialogueBoost == mode) return;
        var result = engine?.TrySetDialogueBoost(mode) ?? AudioChangeResult.Applied;
        if (result == AudioChangeResult.Unavailable)
        {
            Error = "Dialogue Boost is unavailable in this VLC installation.";
            return;
        }
        Preferences = Preferences with { DialogueBoost = mode };
        Preferences.Save(settings);
        OnPropertyChanged(nameof(Preferences));
        if (result == AudioChangeResult.ReloadRequired) _ = ReopenAudioAsync();
    }

    /// <summary>Reopen with the other compressor, preserving pause, speed and remembered tracks.</summary>
    public async Task SetVolumeLevelingAsync(VolumeLeveling mode)
    {
        if (Preferences.EffectiveLeveling == mode) return;
        Preferences = Preferences with { VolumeLeveling = mode, NightMode = mode != VolumeLeveling.Off };
        Preferences.Save(settings);
        OnPropertyChanged(nameof(Preferences));
        await ReopenAudioAsync();
    }

    private async Task ReopenAudioAsync()
    {
        var paused = State == PlayerState.Paused;
        var selectedAudio = AudioTracks.FirstOrDefault(track => track.Id == AudioTrack);
        var selectedSubtitle = SubtitleTracks.FirstOrDefault(track => track.Id == SubtitleTrack);
        if (selectedAudio is not null) memory.RememberAudio(selectedAudio, seriesId);
        if (tracksApplied) memory.RememberSubtitle(selectedSubtitle, seriesId);
        if (Item is { } current)
        {
            pauseAfterReopen = paused;
            await LoadAsync(current, Position, keepTicket: true);
            if (paused && engine is not null) { engine.Pause(); State = PlayerState.Paused; }
        }
    }

    public void SetSleepTimer(SleepTimer timer)
    {
        SleepTimer = timer;
        sleepAt = timer.Minutes > 0 ? time.GetUtcNow().AddMinutes(timer.Minutes) : null;
        OnPropertyChanged(nameof(SleepRemaining));
        OnPropertyChanged(nameof(UpNext));
    }

    /// <summary>"Cancel" on the Up Next card: this title plays to its end, then the player closes.</summary>
    public void DismissUpNext()
    {
        upNextDismissed = true;
        OnPropertyChanged(nameof(UpNext));
    }

    public async Task NextAsync()
    {
        if (NextItem is not { } next || Item is not { } current) return;
        await SaveProgressAsync(finished: false);
        queue.RemoveAt(0);
        previous.Push(current);
        await LoadAsync(next, null);
    }

    public async Task PreviousAsync()
    {
        if (!HasPrevious || Item is not { } current) return;
        await SaveProgressAsync(finished: false);
        queue.Insert(0, current);
        await LoadAsync(previous.Pop(), null);
    }

    /// <summary>"Use This Computer's Position" after a conflict: rebases on the server's revision and saves again.</summary>
    public async Task KeepThisPositionAsync()
    {
        if (Item is not { } current) return;
        try
        {
            revision = (await client.ProgressAsync(current.Id, CancellationToken.None)).Revision;
            HasConflict = false;
            await SaveProgressAsync(finished: false);
        }
        catch (AureliaApiException failure)
        {
            Error = failure.Message;
        }
    }

    public async Task RetryAsync()
    {
        if (Item is not { } current) return;
        recoveryStarted = null;
        recoveryAttempt = 0;
        Error = null;
        await LoadAsync(current, Position);
    }

    public async Task CloseAsync()
    {
        if (closed) return;
        closed = true;
        Record(PlaybackDiagnosticKind.Stopped);
        clock?.Dispose();
        await SaveProgressAsync(finished: false);
        await ReleaseAsync(revoke: true);
        system.KeepAwake(false);
        system.Update(null);
        Closed?.Invoke();
    }

    public async ValueTask DisposeAsync() => await CloseAsync();

    private async Task LoadAsync(CatalogItemSummary title, long? start, bool keepTicket = false)
    {
        State = PlayerState.Loading;
        Item = title;
        Error = null;
        HasConflict = false;
        tracksApplied = false;
        upNextDismissed = false;
        observedPlayback = false;
        AudioTracks = [];
        SubtitleTracks = [];
        Chapters = [];
        Chapter = -1;
        await ReleaseAsync(revoke: !keepTicket);
        try
        {
            if (!keepTicket || ticket is null) ticket = await client.StartAsync(title.Id, CancellationToken.None);
            revision = ticket.Progress.Revision;
            var progress = ticket.Progress;
            var resumeAt = start ?? (Preferences.AutomaticResume && !progress.IsCompleted && progress.PositionMilliseconds >= Preferences.ResumeThresholdSeconds * 1000L
                ? progress.PositionMilliseconds
                : 0);
            relay = new LoopbackStreamRelay(client.StreamConnection, client.StreamToken, client.StreamUri(ticket));
            relay.Failed += status => post(() => _ = RecoverAsync($"The stream stopped ({status})."));
            var url = relay.Start();
            engine = engines.Create(Preferences.AudioProcessing);
            OnPropertyChanged(nameof(Engine));
            engine.Changed += OnEngineChanged;
            engine.Finished += OnEngineFinished;
            engine.Rate = Rate;
            engine.Volume = (int)Math.Round(Volume * 100);
            engine.Muted = Muted;
            engine.Open(url, resumeAt, paused: pauseAfterReopen);
            Position = resumeAt;
            Duration = progress.DurationMilliseconds;
            openedAt = time.GetUtcNow();
            lastMovement = openedAt;
            lastClock = -1;
            lastSave = openedAt;
            _ = AddSidecarSubtitlesAsync(ticket, relay);
            StartClock();
        }
        catch (InvalidOperationException failure) { Fail(failure.Message); }
        catch (AureliaApiException failure)
        {
            Record(PlaybackDiagnosticKind.Failed, failure: failure);
            if (failure.IsTransient) await RecoverAsync(failure.Message);
            else Fail(failure.Message);
        }
    }

    private async Task AddSidecarSubtitlesAsync(PlaybackSourceResponse current, LoopbackStreamRelay currentRelay)
    {
        try
        {
            var tracks = await client.SubtitlesAsync(current, CancellationToken.None);
            foreach (var track in tracks.Where(t => t.IsSidecar && t.Supported))
            {
                if (engine is null || relay != currentRelay) return;
                engine.AddSubtitle(currentRelay.SubtitleUrl(track.Index));
            }
        }
        catch (AureliaApiException)
        {
            // Older servers offer no sidecar list; the embedded subtitles still work.
        }
    }

    private void StartClock()
    {
        clock?.Dispose();
        clock = time.CreateTimer(_ => post(Tick), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
    }

    private void OnEngineChanged() => post(() =>
    {
        if (engine is null || closed) return;
        var now = time.GetUtcNow();
        var clockTime = engine.Time;
        if (clockTime >= 0 && clockTime != lastClock)
        {
            if (lastClock >= 0 || clockTime > 0) observedPlayback = true;
            lastMovement = now;
            lastClock = clockTime;
            Position = clockTime;
        }
        if (engine.Length > 0) Duration = engine.Length;
        if (pauseAfterReopen && engine.IsPlaying)
        {
            pauseAfterReopen = false;
            engine.Pause();
            State = PlayerState.Paused;
        }
        else if (engine.IsPlaying && State is PlayerState.Loading or PlayerState.Recovering)
        {
            State = PlayerState.Playing;
            stableSince = now;
        }
        if (!ReferenceEquals(AudioTracks, engine.AudioTracks) && engine.AudioTracks.Count != AudioTracks.Count) AudioTracks = engine.AudioTracks;
        if (engine.SubtitleTracks.Count != SubtitleTracks.Count) SubtitleTracks = engine.SubtitleTracks;
        AudioTrack = engine.AudioTrack;
        SubtitleTrack = engine.SubtitleTrack;
        if (!Chapters.SequenceEqual(engine.Chapters)) Chapters = engine.Chapters;
        Chapter = engine.Chapter;
        if (!tracksApplied && (engine.AudioTracks.Count > 0 || engine.SubtitleTracks.Count > 0)) ApplyTrackPreferences();
        RaiseClockChanged();
    });

    private void OnEngineFinished(EngineEnd end) => post(() =>
    {
        if (engine is null || closed) return;
        if (end == EngineEnd.Ended && PlayerPolicy.IsNaturalCompletion(Math.Max(Position, engine.Time), Duration, observedPlayback))
            _ = FinishTitleAsync();
        else
            _ = RecoverAsync(end == EngineEnd.Failed ? "Playback stopped unexpectedly." : "The stream ended early.");
    });

    /// <summary>The remembered or default tracks, applied once when the decoder reports its tracks.</summary>
    private void ApplyTrackPreferences()
    {
        if (engine is null) return;
        tracksApplied = true;
        var series = memory.ForSeries(seriesId);
        if (TrackMemory.Pick(engine.AudioTracks, series?.Audio ?? memory.LastAudio, Preferences.DefaultAudioLanguage) is { } audio)
        {
            engine.AudioTrack = audio.Id;
            AudioTrack = audio.Id;
        }
        var subtitleChoice = series?.Subtitle ?? memory.LastSubtitle;
        var subtitle = TrackMemory.Pick(engine.SubtitleTracks, subtitleChoice, Preferences.DefaultSubtitleLanguage);
        if (subtitle is not null || subtitleChoice is { Off: true } || Preferences.DefaultSubtitleLanguage != "off")
        {
            engine.SubtitleTrack = subtitle?.Id ?? -1;
            SubtitleTrack = subtitle?.Id ?? -1;
        }
    }

    private void Tick()
    {
        if (engine is null || closed) return;
        var now = time.GetUtcNow();
        if (State == PlayerState.Playing && now - lastSave >= ProgressInterval) _ = SaveProgressAsync(finished: false);
        if (sleepAt is { } at)
        {
            OnPropertyChanged(nameof(SleepRemaining));
            if (now >= at)
            {
                _ = SleepAsync();
                return;
            }
        }
        if (ticket is { } current && current.ExpiresAt - now <= RenewalLead && State == PlayerState.Playing) _ = RenewAsync(current);
        // Watchdog: no movement for 15 s while playing, or no first frame within 30 s, means a stall.
        if (State == PlayerState.Playing && engine.IsPlaying && now - lastMovement >= StallLimit) _ = RecoverAsync("Playback stalled.");
        if (State == PlayerState.Loading && now - openedAt >= FirstFrameLimit) _ = RecoverAsync("The title did not start.");
        // Ten seconds of steady playback reset the recovery budget.
        if (State == PlayerState.Playing && now - stableSince >= TimeSpan.FromSeconds(10)) recoveryAttempt = 0;
        RaiseClockChanged();
    }

    private void RaiseClockChanged()
    {
        OnPropertyChanged(nameof(UpNext));
        OnPropertyChanged(nameof(UpNextSeconds));
        system.Update(this);
    }

    private async Task FinishTitleAsync()
    {
        Record(PlaybackDiagnosticKind.Ended);
        await SaveProgressAsync(finished: true);
        if (SleepTimer.EndOfEpisode)
        {
            await SleepAsync();
            return;
        }
        if (NextItem is { } next && Preferences.AutoplayNextEpisode && !upNextDismissed && Item is { } current)
        {
            queue.RemoveAt(0);
            previous.Push(current);
            await LoadAsync(next, null);
            return;
        }
        await CloseAsync();
    }

    private async Task SleepAsync()
    {
        engine?.Pause();
        State = PlayerState.Paused;
        sleepAt = null;
        SleepTimer = SleepTimer.Off;
        try
        {
            await client.SleepTimerEndedAsync(CancellationToken.None);
        }
        catch (AureliaApiException)
        {
        }
        await CloseAsync();
    }

    private async Task RenewAsync(PlaybackSourceResponse current)
    {
        if (ticket != current) return;
        try
        {
            var renewed = await client.StartAsync(current.MediaId, CancellationToken.None);
            if (ticket != current || relay is null) return;
            ticket = renewed;
            relay.UpdateSource(client.StreamUri(renewed));
            Record(PlaybackDiagnosticKind.TicketRenewed);
            _ = RevokeQuietlyAsync(current.Id);
        }
        catch (AureliaApiException)
        {
            // The next tick tries again while the old ticket is still valid.
        }
    }

    /// <summary>Restarts at the last real position with a new ticket, with growing waits, for at most two minutes.</summary>
    private async Task RecoverAsync(string reason)
    {
        if (closed || Item is not { } current || State == PlayerState.Failed) return;
        var now = time.GetUtcNow();
        recoveryStarted ??= now;
        if (now - recoveryStarted > RecoveryBudget || recoveryAttempt >= RecoveryDelays.Length)
        {
            Fail(reason);
            return;
        }
        State = PlayerState.Recovering;
        var wait = TimeSpan.FromSeconds(RecoveryDelays[recoveryAttempt++]);
        Record(PlaybackDiagnosticKind.RecoveryAttempt, recoveryAttempt);
        var resumeAt = Position;
        await ReleaseAsync(revoke: true);
        try
        {
            await Task.Delay(wait, time);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (closed || Item != current) return;
        await LoadAsync(current, resumeAt);
    }

    private void Fail(string reason)
    {
        Error = reason;
        State = PlayerState.Failed;
        Record(PlaybackDiagnosticKind.Failed);
        recoveryStarted = null;
    }

    private async Task SaveProgressAsync(bool finished)
    {
        if (Item is not { } current || Duration <= 0 || (!observedPlayback && !finished)) return;
        lastSave = time.GetUtcNow();
        var pending = new PendingProgress(client.Library.Server.ServerId, client.Library.Profile.User.Id, current.Id,
            finished ? Duration : Position, Duration, finished, revision, Guid.NewGuid());
        var (result, saved) = await outbox.SaveAsync(client, pending, CancellationToken.None);
        if (result == ProgressResult.Saved && saved is not null) revision = saved.Revision;
        if (result == ProgressResult.Conflict) HasConflict = true;
        if (result == ProgressResult.Conflict) Record(PlaybackDiagnosticKind.ProgressConflict);
        if (result == ProgressResult.Waiting) Record(PlaybackDiagnosticKind.ProgressPending);
    }

    private void Record(PlaybackDiagnosticKind kind, int? attempt = null, AureliaApiException? failure = null) =>
        Diagnostics.Record(kind, Position, Duration, State, attempt, failure);

    private async Task ReleaseAsync(bool revoke)
    {
        var oldEngine = engine;
        var oldRelay = relay;
        var oldTicket = ticket;
        engine = null;
        relay = null;
        if (revoke) ticket = null;
        if (oldEngine is not null) OnPropertyChanged(nameof(Engine));
        if (oldEngine is not null)
        {
            oldEngine.Changed -= OnEngineChanged;
            oldEngine.Finished -= OnEngineFinished;
            oldEngine.Unload();
            oldEngine.Dispose();
        }
        if (oldRelay is not null) await oldRelay.DisposeAsync();
        if (revoke && oldTicket is not null) await RevokeQuietlyAsync(oldTicket.Id);
    }

    private async Task RevokeQuietlyAsync(Guid ticketId)
    {
        try
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
            await client.RevokeAsync(ticketId, limit.Token);
        }
        catch (Exception failure) when (failure is AureliaApiException or OperationCanceledException)
        {
            // An unrevoked ticket expires on its own.
        }
    }
}
