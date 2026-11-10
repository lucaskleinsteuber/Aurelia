using Aurelia.Linux.Core.Playback;

namespace Aurelia.Linux.Tests;

/// <summary>
/// A decoder that plays nothing: tests move its clock and decide when it ends or fails. It goes
/// through the same player logic and views as VLC, with no real video, audio or media files.
/// </summary>
internal sealed class SimulatedEngine : IVideoEngine
{
    public event Action? Changed;

    public event Action<EngineEnd>? Finished;

    public Uri? OpenedUrl { get; private set; }

    public IReadOnlyList<string> OpenedOptions { get; private set; } = [];

    public void Open(Uri url, long startMilliseconds, bool paused, IReadOnlyList<string> options)
    {
        OpenedOptions = options;
        ((IVideoEngine)this).Open(url, startMilliseconds, paused);
    }

    public long OpenedAt { get; private set; } = -1;

    public List<Uri> AddedSubtitles { get; } = [];

    public bool Unloaded { get; private set; }

    public bool NightMode { get; init; }
    public DialogueBoost DialogueBoost { get; set; }
    public bool SupportsDialogue { get; set; } = true;
    public AudioChangeResult TrySetDialogueBoost(DialogueBoost mode)
    {
        if (!SupportsDialogue) return AudioChangeResult.Unavailable;
        if (NightMode) return AudioChangeResult.ReloadRequired;
        DialogueBoost = mode;
        return AudioChangeResult.Applied;
    }

    public long Time { get; private set; }

    public long Length { get; set; } = 3_600_000;

    public bool IsPlaying { get; private set; }

    public double Rate { get; set; } = 1;

    public int Volume { get; set; } = 100;

    public bool Muted { get; set; }

    public IReadOnlyList<MediaTrack> AudioTracks { get; set; } = [new(1, "Track 1 - [English]", "English"), new(2, "Track 2 - [German]", "German")];

    public IReadOnlyList<MediaTrack> SubtitleTracks { get; set; } = [new(3, "English - [eng]", "eng"), new(4, "Deutsch - [ger]", "ger")];

    public int AudioTrack { get; set; } = 1;

    public int SubtitleTrack { get; set; } = -1;

    public IReadOnlyList<PlaybackChapter> Chapters { get; set; } = [];

    public int Chapter { get; set; } = -1;

    public void Open(Uri url, long startMilliseconds)
    {
        OpenedUrl = url;
        OpenedAt = startMilliseconds;
        Time = startMilliseconds;
        IsPlaying = true;
        Changed?.Invoke();
    }

    public void Play()
    {
        IsPlaying = true;
        Changed?.Invoke();
    }

    public void Pause()
    {
        IsPlaying = false;
        Changed?.Invoke();
    }

    public void Unload()
    {
        Unloaded = true;
        IsPlaying = false;
    }

    public void Seek(long milliseconds)
    {
        Time = milliseconds;
        Changed?.Invoke();
    }

    public void AddSubtitle(Uri url) => AddedSubtitles.Add(url);

    /// <summary>Moves the clock as if the title played on.</summary>
    public void Advance(long milliseconds)
    {
        Time = Math.Min(Length, Time + milliseconds);
        Changed?.Invoke();
    }

    public void End() => Finished?.Invoke(EngineEnd.Ended);

    public void Fail() => Finished?.Invoke(EngineEnd.Failed);

    public void Dispose()
    {
    }
}

internal sealed class SimulatedEngines : IVideoEngineFactory
{
    public List<SimulatedEngine> Created { get; } = [];

    public SimulatedEngine Last => Created[^1];

    public IVideoEngine Create(AudioProcessing processing)
    {
        var engine = new SimulatedEngine { NightMode = processing.Leveling != VolumeLeveling.Off, DialogueBoost = processing.Dialogue };
        Created.Add(engine);
        return engine;
    }

    public IVideoEngine Create(bool nightMode)
    {
        var engine = new SimulatedEngine { NightMode = nightMode };
        Created.Add(engine);
        return engine;
    }
}

/// <summary>A clock the test moves by hand; timers and delays fire when their time comes.</summary>
internal sealed class ManualTime : TimeProvider
{
    private readonly Lock gate = new();
    private readonly List<ManualTimer> timers = [];
    private DateTimeOffset now = DateTimeOffset.UtcNow;

    public override DateTimeOffset GetUtcNow()
    {
        lock (gate) return now;
    }

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new ManualTimer(this, callback, state);
        timer.Change(dueTime, period);
        return timer;
    }

    /// <summary>Moves time forward step by step, firing every timer whose time came.</summary>
    public void Advance(TimeSpan by, TimeSpan? step = null)
    {
        var target = GetUtcNow() + by;
        var increment = step ?? TimeSpan.FromMilliseconds(250);
        while (GetUtcNow() < target)
        {
            lock (gate) now = now + increment > target ? target : now + increment;
            Fire();
        }
    }

    private void Fire()
    {
        List<ManualTimer> due;
        lock (gate) due = [.. timers.Where(t => t.Due is { } at && at <= now)];
        foreach (var timer in due) timer.Run();
    }

    private sealed class ManualTimer(ManualTime time, TimerCallback callback, object? state) : ITimer
    {
        private TimeSpan period = Timeout.InfiniteTimeSpan;

        public DateTimeOffset? Due { get; private set; }

        public bool Change(TimeSpan dueTime, TimeSpan period)
        {
            lock (time.gate)
            {
                this.period = period;
                Due = dueTime == Timeout.InfiniteTimeSpan ? null : time.now + dueTime;
                if (!time.timers.Contains(this)) time.timers.Add(this);
            }
            return true;
        }

        public void Run()
        {
            lock (time.gate) Due = period == Timeout.InfiniteTimeSpan || period == TimeSpan.Zero ? null : Due + period;
            callback(state);
        }

        public void Dispose()
        {
            lock (time.gate)
            {
                Due = null;
                time.timers.Remove(this);
            }
        }

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
