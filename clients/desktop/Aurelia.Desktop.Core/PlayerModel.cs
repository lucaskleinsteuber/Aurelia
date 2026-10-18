using System.ComponentModel;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>"Up Next" in a title's last seconds.</summary>
public sealed record UpNextCard(string Title, string? Subtitle, int Seconds);

/// <summary>
/// One playback session, like the Mac player: it opens a ticket and the stream relay, starts at
/// the resume position, saves progress, applies remembered tracks, counts down to the next
/// episode and continues with it, and reconnects once when the stream breaks. Everything the
/// player screen shows lives here; the decoder is behind <see cref="IVideoEngine"/>.
/// </summary>
public sealed class PlayerModel : INotifyPropertyChanged, IAsyncDisposable
{
    private readonly ILibraryApi api;
    private readonly IVideoEngineFactory engines;
    private readonly PlaybackSettingsStore settingsStore;
    private readonly Action<Action> dispatch;
    private readonly Func<DateTimeOffset> clock;
    private readonly Func<StreamSource, string?, IStreamRelay> relays;
    private readonly List<CatalogItemSummary> queue;
    private readonly Guid? seriesId;
    private readonly SemaphoreSlim saving = new(1, 1);
    private PlaybackSettings settings;
    private CatalogItemSummary current;
    private PlaybackSourceResponse? ticket;
    private IStreamRelay? relay;
    private IStreamRelay? previewRelay;
    private Uri? localUrl;
    private long revision;
    private long resume;
    private bool resumeApplied;
    private bool observedPlayback;
    private bool tracksApplied;
    private bool finished;
    private bool upNextDismissed;
    private bool autoplayCancelled;
    private bool recovered;
    private bool closed;
    private bool wantsPlayback = true;
    private DateTimeOffset lastSave;
    private CancellationTokenSource? sleepTimer;

    public PlayerModel(ILibraryApi api, IVideoEngineFactory engines, PlaybackSettingsStore settingsStore, PlaybackRequest request,
        Action<Action> dispatch, Func<DateTimeOffset>? clock = null, Func<StreamSource, string?, IStreamRelay>? relays = null)
    {
        this.api = api;
        this.engines = engines;
        this.settingsStore = settingsStore;
        this.dispatch = dispatch;
        this.clock = clock ?? (() => DateTimeOffset.UtcNow);
        this.relays = relays ?? ((source, purpose) => new LoopbackStreamRelay(source, purpose));
        settings = settingsStore.Load();
        current = request.Target;
        queue = [.. request.Queue.Where(item => item.Id != request.Target.Id)];
        seriesId = request.SeriesId ?? (request.Target.Kind == MediaKind.Episode ? request.Target.ParentId : null);
        Engine = engines.Create(settings.NightMode);
        Attach(Engine);
        UpdateTitles();
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    /// <summary>The player asks its window to close: the person left, or the last title ended.</summary>
    public event Action? CloseRequested;

    public IVideoEngine Engine { get; private set => Set(ref field, value); }
    public string Title { get; private set => Set(ref field, value); } = "";
    public string? Subtitle { get; private set => Set(ref field, value); }
    public Guid MediaId => current.Id;
    public bool IsStarting { get; private set => Set(ref field, value); } = true;
    public bool IsPlaying { get; private set => Set(ref field, value, nameof(IsPlaying), [nameof(PlayPauseLabel)]); }
    public string PlayPauseLabel => IsPlaying ? "Pause" : "Play";
    public long Position { get; private set => Set(ref field, value, nameof(Position), TimeProperties); }
    public long Duration { get; private set => Set(ref field, value, nameof(Duration), TimeProperties); }
    public string PositionLabel => PlayerPolicy.TimeLabel(Position);
    public string DurationLabel => PlayerPolicy.TimeLabel(Duration);
    public string? EndsAtLabel => PlayerPolicy.EndTimeLabel(Position, Duration, Rate, clock());
    public double Progress => Duration > 0 ? Math.Clamp((double)Position / Duration, 0, 1) : 0;
    public string? Error { get; private set => Set(ref field, value, nameof(Error), [nameof(HasError)]); }
    public bool HasError => Error is not null;
    public string? Message { get; private set => Set(ref field, value); }
    public int Volume { get; private set => Set(ref field, value); }
    public bool Muted { get; private set => Set(ref field, value, nameof(Muted), [nameof(MuteLabel)]); }
    public string MuteLabel => Muted ? "Unmute" : "Mute";
    public double Rate { get; private set => Set(ref field, value, nameof(Rate), [nameof(RateLabel), nameof(EndsAtLabel)]); } = 1;
    public string RateLabel => Rate == 1 ? "1×" : $"{Rate:0.##}×";
    public bool NightMode => settings.NightMode;
    public IReadOnlyList<MediaTrack> AudioTracks { get; private set => Set(ref field, value); } = [];
    public IReadOnlyList<MediaTrack> SubtitleTracks { get; private set => Set(ref field, value); } = [];
    public int SelectedAudio { get; private set => Set(ref field, value); } = -1;
    public int SelectedSubtitle { get; private set => Set(ref field, value); } = -1;
    public UpNextCard? UpNext { get; private set => Set(ref field, value, nameof(UpNext), [nameof(HasUpNext)]); }
    public bool HasUpNext => UpNext is not null;
    /// <summary>0 = off, -1 = end of this episode, otherwise minutes.</summary>
    public int SleepMinutes { get; private set => Set(ref field, value); }
    /// <summary>The preview relay's address once it runs; timeline frames are read through it.</summary>
    public Uri? PreviewSource { get; private set => Set(ref field, value); }
    public bool PreviewsParallel { get; private set => Set(ref field, value); }

    private static readonly string[] TimeProperties =
        [nameof(PositionLabel), nameof(DurationLabel), nameof(EndsAtLabel), nameof(Progress)];

    public async Task StartAsync()
    {
        Volume = settings.Volume;
        Engine.Volume = settings.Volume;
        try
        {
            var features = await api.CapabilitiesAsync(CancellationToken.None);
            PreviewsParallel = features.Contains(ScrubPreviewPlan.ServerFeature);
        }
        catch (AureliaApiException) { }
        await OpenAsync(current, resumeAt: null);
    }

    public void TogglePlay()
    {
        if (closed || HasError) return;
        if (IsPlaying) Pause();
        else
        {
            wantsPlayback = true;
            Engine.Play();
        }
    }

    public void Pause()
    {
        wantsPlayback = false;
        IsStarting = false;
        Engine.Pause();
        _ = SaveProgressAsync(finished: false);
    }

    public void Seek(long milliseconds)
    {
        if (Duration <= 0) return;
        var target = PlayerPolicy.Clamp(milliseconds, Duration);
        Engine.Seek(target);
        Position = target;
    }

    public void SkipBy(long milliseconds) => Seek(Position + milliseconds);

    public void SetVolume(int volume)
    {
        Volume = Math.Clamp(volume, 0, 125);
        Engine.Volume = Volume;
        if (Volume > 0 && Muted) ToggleMute();
        settings = settingsStore.Update(saved => saved with { Volume = Volume });
    }

    public void ToggleMute()
    {
        Muted = !Muted;
        Engine.Muted = Muted;
    }

    public void SetRate(double rate)
    {
        if (!PlayerPolicy.Rates.Contains(rate)) return;
        Engine.Rate = rate;
        Rate = rate;
    }

    public void SelectAudio(MediaTrack track)
    {
        Engine.AudioTrack = track.Id;
        SelectedAudio = track.Id;
        settings = settingsStore.Remember(seriesId, audio: TrackChoice.From(track.Name));
    }

    /// <summary>`null` turns subtitles off, which is remembered as a choice too.</summary>
    public void SelectSubtitle(MediaTrack? track)
    {
        Engine.SubtitleTrack = track?.Id ?? -1;
        SelectedSubtitle = track?.Id ?? -1;
        settings = settingsStore.Remember(seriesId, subtitle: track is null ? null : TrackChoice.From(track.Name), subtitleChosen: true);
    }

    /// <summary>Night mode is fixed when a decoder is made, so the title reopens at the same position.</summary>
    public void SetNightMode(bool enabled)
    {
        if (settings.NightMode == enabled) return;
        settings = settingsStore.Update(saved => saved with { NightMode = enabled });
        OnPropertyChanged(nameof(NightMode));
        if (localUrl is null) return;
        var position = Position;
        var old = Engine;
        Detach(old);
        old.Unload();
        Engine = engines.Create(enabled);
        Attach(Engine);
        Engine.Volume = Volume;
        Engine.Muted = Muted;
        Engine.Rate = Rate;
        BeginOpen(position);
        Engine.Open(localUrl, position);
        old.Dispose();
    }

    public void SetSleepTimer(int minutes)
    {
        sleepTimer?.Cancel();
        sleepTimer = null;
        SleepMinutes = minutes;
        if (minutes <= 0) return;
        var source = sleepTimer = new CancellationTokenSource();
        _ = Task.Delay(TimeSpan.FromMinutes(minutes), source.Token).ContinueWith(task =>
        {
            if (task.IsCanceled) return;
            dispatch(() =>
            {
                if (sleepTimer != source) return;
                SleepMinutes = 0;
                Pause();
            });
        }, TaskScheduler.Default);
    }

    public async Task PlayNextNowAsync()
    {
        if (closed || queue.Count == 0) return;
        finished = true;
        UpNext = null;
        await SaveProgressAsync(finished: true);
        await AdvanceAsync();
    }

    /// <summary>Hides Up Next; this title then stops at its end instead of continuing.</summary>
    public void DismissUpNext()
    {
        upNextDismissed = true;
        autoplayCancelled = true;
        UpNext = null;
    }

    public Task RetryAsync()
    {
        Error = null;
        recovered = false;
        return OpenAsync(current, Position);
    }

    /// <summary>Saves progress, releases the ticket and stops the decoder.</summary>
    public async Task CloseAsync()
    {
        if (closed) return;
        await SaveProgressAsync(finished);
        closed = true;
        sleepTimer?.Cancel();
        Detach(Engine);
        Engine.Unload();
        await ReleaseStreamAsync();
    }

    public async ValueTask DisposeAsync()
    {
        await CloseAsync();
        Engine.Dispose();
        saving.Dispose();
    }

    private async Task OpenAsync(CatalogItemSummary item, long? resumeAt)
    {
        IsStarting = true;
        Error = null;
        try
        {
            await ReleaseStreamAsync();
            var opened = await api.CreatePlaybackAsync(item.Id, CancellationToken.None);
            if (closed)
            {
                await RevokeAsync(opened.Id);
                return;
            }
            ticket = opened;
            revision = opened.Progress.Revision;
            var playback = relays(api.StreamSource(opened), null);
            playback.Failed += status => dispatch(() => StreamFailed(status));
            relay = playback;
            localUrl = playback.Start();
            var start = resumeAt ?? (opened.Progress.IsCompleted ? 0 : opened.Progress.PositionMilliseconds);
            BeginOpen(start);
            Engine.Open(localUrl, start);
            StartPreviewRelay(opened);
        }
        catch (AureliaApiException error)
        {
            IsStarting = false;
            Error = error.Message;
        }
    }

    private void BeginOpen(long start)
    {
        resume = Math.Max(0, start);
        resumeApplied = resume == 0;
        observedPlayback = false;
        tracksApplied = false;
        lastSave = clock();
        IsStarting = true;
        wantsPlayback = true;
        Position = resume;
    }

    private void StartPreviewRelay(PlaybackSourceResponse opened)
    {
        try
        {
            var preview = relays(api.StreamSource(opened), "preview");
            previewRelay = preview;
            PreviewSource = preview.Start();
        }
        catch (Exception error) when (error is System.Net.Sockets.SocketException or AureliaApiException)
        {
            // Without previews the timeline still works.
        }
    }

    private void Attach(IVideoEngine engine)
    {
        engine.Changed += EngineChanged;
        engine.Finished += EngineFinished;
    }

    private void Detach(IVideoEngine engine)
    {
        engine.Changed -= EngineChanged;
        engine.Finished -= EngineFinished;
    }

    private void EngineChanged() => dispatch(Update);

    private void EngineFinished(EngineEnd end) => dispatch(() => _ = HandleEndAsync(end));

    private void Update()
    {
        if (closed) return;
        var engine = Engine;
        var time = engine.Time;
        if (engine.Length > 0) Duration = engine.Length;
        if (!resumeApplied && time > 0 && Duration > 0)
        {
            resumeApplied = true;
            // Some containers ignore the start position; their clock starts at the beginning.
            if (!PlayerPolicy.OpenedAtResume(time, resume)) engine.Seek(resume);
        }
        if (resumeApplied) Position = time;
        IsPlaying = engine.IsPlaying;
        if (IsPlaying && resumeApplied && time > resume + 250)
        {
            observedPlayback = true;
            IsStarting = false;
        }
        if (!tracksApplied && (engine.AudioTracks.Count > 0 || engine.SubtitleTracks.Count > 0)) ApplyTrackChoices(engine);
        AudioTracks = engine.AudioTracks;
        SubtitleTracks = engine.SubtitleTracks;
        SelectedAudio = engine.AudioTrack;
        SelectedSubtitle = engine.SubtitleTrack;
        var next = queue.FirstOrDefault();
        UpNext = PlayerPolicy.ShowsUpNext(Position, Duration, next is not null, settings.AutoplayNext, SleepMinutes == -1, upNextDismissed || finished)
            ? new UpNextCard(next!.Title, Describe(next), PlayerPolicy.UpNextSeconds(Position, Duration))
            : null;
        if (IsPlaying && clock() - lastSave >= PlayerPolicy.ProgressInterval) _ = SaveProgressAsync(finished: false);
        if (!wantsPlayback && IsPlaying) engine.Pause();
    }

    private void ApplyTrackChoices(IVideoEngine engine)
    {
        tracksApplied = true;
        var series = seriesId is { } id ? settings.Series?.GetValueOrDefault(id) : null;
        var audio = series?.Audio ?? settings.Audio;
        if (audio?.Match(engine.AudioTracks) is { } track) engine.AudioTrack = track.Id;
        var subtitleChosen = series?.SubtitleChosen == true || settings.SubtitleChosen;
        if (!subtitleChosen) return;
        var subtitle = series?.SubtitleChosen == true ? series.Subtitle : settings.Subtitle;
        engine.SubtitleTrack = subtitle?.Match(engine.SubtitleTracks)?.Id ?? -1;
    }

    private async Task HandleEndAsync(EngineEnd end)
    {
        if (closed || finished && end == EngineEnd.Ended) return;
        Update();
        if (end == EngineEnd.Ended && PlayerPolicy.IsNaturalCompletion(Math.Max(Position, Engine.Time), Duration, observedPlayback))
        {
            finished = true;
            UpNext = null;
            Position = Duration;
            await SaveProgressAsync(finished: true);
            if (SleepMinutes != -1 && settings.AutoplayNext && !autoplayCancelled && queue.Count > 0) await AdvanceAsync();
            else
            {
                SleepMinutes = 0;
                CloseRequested?.Invoke();
            }
            return;
        }
        await RecoverAsync("The stream was interrupted.");
    }

    private void StreamFailed(int status)
    {
        if (closed || finished) return;
        _ = RecoverAsync(status is 401 or 403 ? "Playback access ended." : "The connection to the server was interrupted.");
    }

    /// <summary>One automatic reconnect at the same position; after that, Try Again is offered.</summary>
    private async Task RecoverAsync(string reason)
    {
        if (closed) return;
        if (recovered)
        {
            IsStarting = false;
            Error = reason + " Check the server, then try again.";
            Engine.Unload();
            return;
        }
        recovered = true;
        Message = reason + " Reconnecting…";
        var position = Math.Max(Position, resume);
        Engine.Unload();
        await OpenAsync(current, position);
        Message = null;
    }

    private async Task AdvanceAsync()
    {
        if (queue.Count == 0) return;
        var next = queue[0];
        queue.RemoveAt(0);
        if (next.Availability != MediaAvailability.Available)
        {
            Error = $"{next.Title} is unavailable. Check that its drive is connected to the server.";
            return;
        }
        Engine.Unload();
        current = next;
        finished = false;
        upNextDismissed = false;
        autoplayCancelled = false;
        recovered = false;
        Duration = 0;
        UpdateTitles();
        OnPropertyChanged(nameof(MediaId));
        await OpenAsync(next, resumeAt: null);
    }

    private async Task SaveProgressAsync(bool finished)
    {
        var position = Position;
        var duration = Duration;
        var item = current;
        if (ticket is null || duration <= 0 || (!finished && (position <= 0 || !observedPlayback))) return;
        lastSave = clock();
        await saving.WaitAsync();
        try
        {
            var saved = await api.SaveProgressAsync(item.Id, finished ? duration : Math.Min(position, duration), duration, finished,
                revision, Guid.NewGuid(), CancellationToken.None);
            if (item.Id == current.Id) revision = saved.Revision;
        }
        catch (AureliaApiException error) when (error.Status == 409)
        {
            // Another device saved newer progress for this title; keep it instead of overwriting.
            try
            {
                var server = await api.ProgressAsync(item.Id, CancellationToken.None);
                if (item.Id == current.Id) revision = server.Revision;
                Message = "Progress changed on another device. Its newer position has been kept.";
            }
            catch (AureliaApiException) { }
        }
        catch (AureliaApiException)
        {
            Message = "Playback progress could not be saved on the server.";
        }
        finally
        {
            saving.Release();
        }
    }

    private async Task ReleaseStreamAsync()
    {
        if (relay is not null) await relay.DisposeAsync();
        if (previewRelay is not null) await previewRelay.DisposeAsync();
        relay = null;
        previewRelay = null;
        PreviewSource = null;
        localUrl = null;
        if (ticket is { } old)
        {
            ticket = null;
            await RevokeAsync(old.Id);
        }
    }

    private async Task RevokeAsync(Guid id)
    {
        try { await api.RevokePlaybackAsync(id, CancellationToken.None); }
        catch (AureliaApiException) { }
    }

    private void UpdateTitles()
    {
        Title = current.Title;
        Subtitle = Describe(current);
    }

    private static string? Describe(CatalogItemSummary item) =>
        item.Kind == MediaKind.Episode
            ? string.Join(" · ", new[] { item.ParentTitle, LibraryModel.EpisodeLabel(item) }.Where(part => !string.IsNullOrEmpty(part)))
            : item.Year?.ToString(System.Globalization.CultureInfo.InvariantCulture);

    private void OnPropertyChanged(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private void Set<T>(ref T field, T value, [CallerMemberName] string name = "", string[]? also = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        OnPropertyChanged(name);
        if (also is not null) foreach (var other in also) OnPropertyChanged(other);
    }
}

/// <summary>A local relay for one stream; <see cref="LoopbackStreamRelay"/> in the app.</summary>
public interface IStreamRelay : IAsyncDisposable
{
    event Action<int>? Failed;
    Uri Start();
}
