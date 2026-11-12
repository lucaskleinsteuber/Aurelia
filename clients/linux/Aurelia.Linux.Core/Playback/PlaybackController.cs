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
    /// <summary>Set while a download plays from this computer instead of the server.</summary>
    private (OfflineTitle Title, OfflineDownloads Store)? offline;
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
    /// <summary>Cancel in the last seconds: the title plays to its end and the player closes.</summary>
    private bool autoplayCancelled;
    /// <summary>Where the card appeared in the credits; its countdown runs from there.</summary>
    private long? creditsAnchor;
    private bool introSkipped;
    private bool movedIntoIntro;
    /// <summary>The server's suggestions after a movie or a series' last episode; null until asked for.</summary>
    private IReadOnlyList<MediaSuggestion>? suggestions;
    private bool suggestionsRequested;
    private bool suggestionDismissed;
    private bool showsEndScreen;
    /// <summary>Leaving for a suggestion or with Done after the credits began: the title counts as watched.</summary>
    private bool finishOnClose;
    private bool showsSkipIntro;
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
    public CatalogItemSummary? UpNext => NextItem is { } next && ScreenTime?.NoMoreTitles != true
        && PlayerPolicy.ShowsUpNext(Position, Duration, true, Preferences.AutoplayNextEpisode, SleepTimer.EndOfEpisode, upNextDismissed, Preferences.UpNextCountdownSeconds,
            CreditsStart)
        ? next
        : null;

    public int UpNextSeconds => PlayerPolicy.UpNextSeconds(Position, Duration, UpNextDuringCredits ? creditsAnchor : null, Preferences.UpNextCountdownSeconds);

    /// <summary>The card appeared with the credits: its second button keeps watching them ("Watch Credits").</summary>
    public bool UpNextDuringCredits => UpNext is not null && PlayerPolicy.ShowsForCredits(Position, Duration, CreditsStart);

    /// <summary>The server's suggestions for this title, best first.</summary>
    public IReadOnlyList<MediaSuggestion> Suggestions => suggestions ?? [];

    /// <summary>The suggestion card from the credits on, without a countdown.</summary>
    public bool ShowsSuggestion => !showsEndScreen && UpNext is null && ScreenTime?.NoMoreTitles != true
        && PlayerPolicy.ShowsSuggestion(Position, Duration, NextItem is not null, Suggestions.Count > 0, suggestionDismissed,
            Segments?.CreditsStartMilliseconds, Preferences.UpNextCountdownSeconds);

    /// <summary>The end screen with the suggestion and two more, once the file ended.</summary>
    public bool ShowsEndScreen
    {
        get => showsEndScreen;
        private set => SetProperty(ref showsEndScreen, value);
    }

    private ScreenTimeStatus? screenTime;
    private bool showsGoodNight;
    private DateTimeOffset lastScreenTimeCheck;
    private bool checkingScreenTime;

    /// <summary>A children's profile's screen time, from the ticket and then every minute (docs/SCREEN_TIME.md).</summary>
    public ScreenTimeStatus? ScreenTime
    {
        get => screenTime;
        private set
        {
            if (!SetProperty(ref screenTime, value)) return;
            OnPropertyChanged(nameof(LastTitleNote));
            OnPropertyChanged(nameof(UpNext));
            OnPropertyChanged(nameof(ShowsSuggestion));
        }
    }

    /// <summary>The quiet "last episode" note while the last title of the day plays.</summary>
    public string? LastTitleNote => ScreenTime?.NoMoreTitles == true && !ShowsGoodNight ? ScreenTimeText.LastTitleNote(ScreenTime) : null;

    /// <summary>Screen time is over: the good-night screen shows instead of the next title or an error.</summary>
    public bool ShowsGoodNight
    {
        get => showsGoodNight;
        private set { if (SetProperty(ref showsGoodNight, value)) OnPropertyChanged(nameof(LastTitleNote)); }
    }

    /// <summary>Done on the good-night screen should end the profile: its whole profile is closed.</summary>
    public bool GoodNightEndsProfile => ShowsGoodNight && ScreenTime?.LockScope == ScreenTimeLockScope.WholeProfile;

    /// <summary>Raised after the player closed for a suggestion that should play now.</summary>
    public event Action<CatalogItemSummary>? SuggestionChosen;

    /// <summary>"Watch Credits" on the suggestion card: the credits play to the end, then the end screen follows.</summary>
    public void DismissSuggestion()
    {
        suggestionDismissed = true;
        OnPropertyChanged(nameof(ShowsSuggestion));
    }

    /// <summary>"Watch Now": this title counts as watched from its credits on, and the suggestion starts.</summary>
    public async Task PlaySuggestionAsync(CatalogItemSummary suggestion)
    {
        ArgumentNullException.ThrowIfNull(suggestion);
        if (closed) return;
        await DoneAsync();
        SuggestionChosen?.Invoke(suggestion);
    }

    /// <summary>"Done": closes the player; from the credits on the title counts as watched.</summary>
    public async Task DoneAsync()
    {
        finishOnClose = PlayerPolicy.NextFinishesCurrent(Position, Duration, ShowsSuggestion || ShowsEndScreen, Segments?.CreditsStartMilliseconds);
        await CloseAsync();
    }

    private void RequestSuggestions()
    {
        if (suggestionsRequested || offline is not null || Item is not { } current || !client.Library.Supports(ServerFeatures.Suggestions)
            || !PlayerPolicy.WantsSuggestions(Position, Duration, NextItem is not null)) return;
        suggestionsRequested = true;
        _ = LoadSuggestionsAsync(current.Id);
    }

    private async Task LoadSuggestionsAsync(Guid id)
    {
        try
        {
            var list = await client.SuggestionsAsync(id, 3, CancellationToken.None);
            post(() =>
            {
                if (Item?.Id != id) return;
                suggestions = [.. list.Where(entry => entry.Item.Id != id)];
                OnPropertyChanged(nameof(Suggestions));
                OnPropertyChanged(nameof(ShowsSuggestion));
            });
        }
        catch (AureliaApiException)
        {
            // An older server or a failed request: no suggestion, the player ends as before.
        }
        catch (HttpRequestException)
        {
        }
    }

    /// <summary>The intro and credits times of the playing title from the server ("media-segments-v2"); downloads have none.</summary>
    public MediaSegmentsDto? Segments => offline is null && ticket is { } current && current.MediaId == Item?.Id ? current.Segments : null;

    private long? CreditsStart => Preferences.UpNextAtCredits ? Segments?.CreditsStartMilliseconds : null;

    private (long Start, long End)? CurrentIntro =>
        PlayerPolicy.Intro(Segments) is { } intro && (Duration <= 0 || intro.End <= Duration) ? intro : null;

    /// <summary>Whether "Skip Intro" is offered now.</summary>
    public bool ShowsSkipIntro
    {
        get => showsSkipIntro;
        private set => SetProperty(ref showsSkipIntro, value);
    }

    /// <summary>Jumps to the end of the intro; Watch Together follows like any other seek.</summary>
    public void SkipIntro()
    {
        if (!ShowsSkipIntro || CurrentIntro is not { } intro) return;
        introSkipped = true;
        ShowsSkipIntro = false;
        SeekTo(intro.End);
    }

    private void UpdateSkipIntro()
    {
        if (Preferences.IntroSkipping == IntroSkipping.Off || CurrentIntro is not { } intro || State is not (PlayerState.Playing or PlayerState.Paused))
        {
            ShowsSkipIntro = false;
            return;
        }
        var shown = PlayerPolicy.ShowsSkipIntro(Position, intro.Start, intro.End);
        if (State == PlayerState.Playing && PlayerPolicy.SkipsIntroAutomatically(Preferences.IntroSkipping, introSkipped, movedIntoIntro, shown))
        {
            introSkipped = true;
            ShowsSkipIntro = false;
            SeekTo(intro.End);
            return;
        }
        ShowsSkipIntro = shown && UpNext is null;
    }

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
    /// <summary>Plays a download from this computer; it works while the server is out of reach.</summary>
    public async Task StartOfflineAsync(OfflineTitle title, OfflineDownloads store)
    {
        Record(PlaybackDiagnosticKind.Started);
        offline = (title, store);
        queue.Clear();
        previous.Clear();
        await LoadAsync(title.Item(), null);
    }

    public bool IsOffline => offline is not null;

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

    public async Task StartQueueAsync(IReadOnlyList<CatalogItemSummary> playlist, CatalogItemSummary target, bool resume, long? startAt = null)
    {
        Record(PlaybackDiagnosticKind.Started);
        queue.Clear();
        previous.Clear();
        var index = -1;
        for (var i = 0; i < playlist.Count; i++)
        {
            if (playlist[i].Id == target.Id)
            {
                index = i;
                break;
            }
        }
        if (index >= 0)
        {
            for (var i = 0; i < index; i++) previous.Push(playlist[i]);
            for (var i = index + 1; i < playlist.Count; i++) queue.Add(playlist[i]);
        }
        seriesId = target.Kind == MediaKind.Episode ? target.ParentId : null;
        await LoadAsync(target, startAt ?? (resume ? null : 0));
    }

    public void PlayPause()
    {
        if (State == PlayerState.Playing) Pause();
        else if (State == PlayerState.Paused) Play();
    }

    /// <summary>Watch Together listens here for play, pause and seek done on this computer.</summary>
    public event Action<PlaybackUserAction>? UserAction;

    public void Play()
    {
        if (engine is null || State != PlayerState.Paused) return;
        pauseAfterReopen = false;
        engine.Play();
        State = PlayerState.Playing;
        UserAction?.Invoke(new PlaybackUserAction(PlaybackUserActionKind.Play, Position));
    }

    public void Pause()
    {
        if (engine is null || State != PlayerState.Playing) return;
        engine.Pause();
        State = PlayerState.Paused;
        _ = SaveProgressAsync(finished: false);
        UserAction?.Invoke(new PlaybackUserAction(PlaybackUserActionKind.Pause, Position));
    }

    /// <summary>Seeks by the seek interval (Settings › Playback), forward or back.</summary>
    public void SeekBy(bool forward) => SeekTo(Position + (forward ? 1 : -1) * Preferences.SeekIntervalSeconds * 1000L);

    public void SeekTo(long milliseconds)
    {
        if (engine is null) return;
        var target = PlayerPolicy.Clamp(milliseconds, Duration);
        // Moving into the intro by hand means it should play; it is not skipped automatically then.
        if (!introSkipped && CurrentIntro is { } intro && target >= intro.Start && target < intro.End) movedIntoIntro = true;
        engine.Seek(target);
        Position = target;
        UserAction?.Invoke(new PlaybackUserAction(PlaybackUserActionKind.Seek, target));
        Record(PlaybackDiagnosticKind.Seeked);
        upNextDismissed = false;
        autoplayCancelled = false;
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

    /// <summary>The picture fills the window, cutting off its edges, instead of black bars. Remembered.</summary>
    public void SetFillsScreen(bool fills)
    {
        if (Preferences.FillsScreen == fills) return;
        Preferences = Preferences with { FillsScreen = fills };
        Preferences.Save(settings);
        OnPropertyChanged(nameof(Preferences));
    }

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

    /// <summary>
    /// "Cancel" on the Up Next card: this title plays to its end, then the player closes. "Watch Credits" (the card
    /// that appeared with the credits) hides it; the next episode still follows at the end.
    /// </summary>
    public void DismissUpNext()
    {
        if (!UpNextDuringCredits) autoplayCancelled = true;
        upNextDismissed = true;
        creditsAnchor = null;
        OnPropertyChanged(nameof(UpNext));
        OnPropertyChanged(nameof(UpNextDuringCredits));
    }

    /// <summary>Next Episode keeps this one's position, except from the credits on, where it counts as watched.</summary>
    public async Task NextAsync()
    {
        if (NextItem is not { } next || Item is not { } current) return;
        var finished = PlayerPolicy.NextFinishesCurrent(Position, Duration, UpNext is not null, CreditsStart);
        await SaveProgressAsync(finished: finished);
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
        await SaveProgressAsync(finished: finishOnClose);
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
        autoplayCancelled = false;
        creditsAnchor = null;
        suggestions = null;
        suggestionsRequested = false;
        suggestionDismissed = false;
        ShowsEndScreen = false;
        introSkipped = false;
        movedIntoIntro = false;
        ShowsSkipIntro = false;
        observedPlayback = false;
        AudioTracks = [];
        SubtitleTracks = [];
        Chapters = [];
        Chapter = -1;
        await ReleaseAsync(revoke: !keepTicket);
        try
        {
            PlaybackProgressResponse progress;
            if (offline is { } download)
            {
                var stored = download.Store.Find(download.Title.Id) ?? download.Title;
                progress = new PlaybackProgressResponse(stored.Id, stored.PositionMilliseconds, stored.DurationMilliseconds, stored.IsCompleted, null, null);
            }
            else
            {
                if (!keepTicket || ticket is null) ticket = await client.StartAsync(title.Id, CancellationToken.None);
                ScreenTime = ticket.ScreenTime;
                lastScreenTimeCheck = time.GetUtcNow();
                revision = ticket.Progress.Revision;
                progress = ticket.Progress;
            }
            var resumeAt = start ?? (Preferences.AutomaticResume && !progress.IsCompleted && progress.PositionMilliseconds >= Preferences.ResumeThresholdSeconds * 1000L
                ? progress.PositionMilliseconds
                : 0);
            Uri url;
            var quality = StreamingQuality.Original;
            if (offline is { } file)
            {
                url = new Uri(file.Store.FileOf(file.Title));
            }
            else
            {
                relay = new LoopbackStreamRelay(client.StreamConnection, client.StreamToken, client.StreamUri(ticket!));
                relay.Failed += status => post(() => _ = RecoverAsync($"The stream stopped ({status})."));
                quality = StreamingQualities.Effective(Preferences.StreamingQuality, client.Library.SupportsAdaptiveStreaming);
                url = StreamingQualities.PlaybackUrl(quality, relay.Start());
            }
            engine = engines.Create(Preferences.AudioProcessing);
            OnPropertyChanged(nameof(Engine));
            engine.Changed += OnEngineChanged;
            engine.Finished += OnEngineFinished;
            engine.Rate = Rate;
            engine.Volume = (int)Math.Round(Volume * 100);
            engine.Muted = Muted;
            engine.Open(url, resumeAt, pauseAfterReopen, StreamingQualities.VlcOptions(quality));
            Position = resumeAt;
            Duration = progress.DurationMilliseconds;
            openedAt = time.GetUtcNow();
            lastMovement = openedAt;
            lastClock = -1;
            lastSave = openedAt;
            if (offline is { } withSubtitles)
            {
                foreach (var subtitle in withSubtitles.Title.Subtitles)
                    engine.AddSubtitle(new Uri(Path.Combine(withSubtitles.Store.Folder(withSubtitles.Title.Id), subtitle.FileName)));
            }
            else
            {
                _ = AddSidecarSubtitlesAsync(ticket!, relay!);
            }
            StartClock();
        }
        catch (InvalidOperationException failure) { Fail(failure.Message); }
        catch (AureliaApiException failure) when (failure.Code is ScreenTimeCodes.Bedtime or ScreenTimeCodes.Limit)
        {
            // Screen time refused the title: the good-night screen, not an error.
            await RefreshScreenTimeAsync();
            await ShowGoodNightAsync();
        }
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
        if (State == PlayerState.Playing && ScreenTime is not null && !checkingScreenTime && now - lastScreenTimeCheck >= ScreenTimeText.RefreshInterval)
            _ = RefreshScreenTimeAsync();
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
        // The countdown starts where the card appeared: at the credits, or later when the person moved into them.
        if (UpNextDuringCredits) creditsAnchor ??= Position;
        else creditsAnchor = null;
        UpdateSkipIntro();
        RequestSuggestions();
        OnPropertyChanged(nameof(UpNext));
        OnPropertyChanged(nameof(UpNextDuringCredits));
        OnPropertyChanged(nameof(UpNextSeconds));
        OnPropertyChanged(nameof(ShowsSuggestion));
        system.Update(this);
        // The countdown ran out in the credits before the file ended: the next episode starts and this one counts as watched.
        if (UpNextDuringCredits && UpNextSeconds == 0 && State == PlayerState.Playing && Position < Duration && !advancing)
        {
            advancing = true;
            _ = AdvanceFromCreditsAsync();
        }
    }

    private bool advancing;

    private async Task AdvanceFromCreditsAsync()
    {
        try { await NextAsync(); }
        finally { advancing = false; }
    }

    private async Task FinishTitleAsync()
    {
        Record(PlaybackDiagnosticKind.Ended);
        await SaveProgressAsync(finished: true);
        // Screen time may have ended while this title played: no next episode, no suggestion.
        if (ScreenTime is not null)
        {
            await RefreshScreenTimeAsync();
            if (ScreenTime?.NoMoreTitles == true)
            {
                await ShowGoodNightAsync();
                return;
            }
        }
        if (SleepTimer.EndOfEpisode)
        {
            await SleepAsync();
            return;
        }
        if (NextItem is { } next && Preferences.AutoplayNextEpisode && !autoplayCancelled && Item is { } current)
        {
            queue.RemoveAt(0);
            previous.Push(current);
            await LoadAsync(next, null);
            return;
        }
        if (NextItem is null && Suggestions.Count > 0)
        {
            // After a movie or a series' last episode: only the person's own setting starts the suggestion.
            if (Preferences.PlaySuggestionsAutomatically && !autoplayCancelled)
            {
                await PlaySuggestionAsync(Suggestions[0].Item);
                return;
            }
            engine?.Pause();
            State = PlayerState.Paused;
            ShowsEndScreen = true;
            OnPropertyChanged(nameof(ShowsSuggestion));
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
        if (closed || Item is not { } current || State == PlayerState.Failed || ShowsGoodNight) return;
        // "Stop now" ends the stream at bedtime; that is the good-night screen, not a problem.
        if (ScreenTime is not null)
        {
            await RefreshScreenTimeAsync();
            if (ScreenTime?.State == ScreenTimeState.Closed)
            {
                await ShowGoodNightAsync();
                return;
            }
        }
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

    private async Task RefreshScreenTimeAsync()
    {
        if (offline is not null || checkingScreenTime) return;
        checkingScreenTime = true;
        lastScreenTimeCheck = time.GetUtcNow();
        try
        {
            var status = await client.ScreenTimeAsync(CancellationToken.None);
            if (!closed) ScreenTime = status;
        }
        catch (AureliaApiException)
        {
            // The last known state stays; a refused session shows on the next request that needs it.
        }
        catch (HttpRequestException)
        {
        }
        finally { checkingScreenTime = false; }
    }

    /// <summary>The friendly end of the day: nothing else starts; the view shows the moon and when Aurelia opens.</summary>
    private async Task ShowGoodNightAsync()
    {
        if (closed || ShowsGoodNight) return;
        if (State == PlayerState.Playing) await SaveProgressAsync(finished: false);
        engine?.Pause();
        State = PlayerState.Paused;
        Error = null;
        recoveryStarted = null;
        ShowsEndScreen = false;
        ShowsGoodNight = true;
        system.KeepAwake(false);
        OnPropertyChanged(nameof(UpNext));
        OnPropertyChanged(nameof(ShowsSuggestion));
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
        if (offline is { } download)
        {
            download.Store.SaveProgress(current.Id, finished ? Duration : Position, Duration, finished);
            return;
        }
        var pending = new PendingProgress(client.Library.Server.ServerId, client.Library.Profile.User.Id, current.Id,
            finished ? Duration : Position, Duration, finished, revision, Guid.NewGuid(), time.GetUtcNow());
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
