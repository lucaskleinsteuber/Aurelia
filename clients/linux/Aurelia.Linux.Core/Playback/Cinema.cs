using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Playback;

/// <summary>Aurelia's made-up cinema ads (as on the Mac and in the browser). Nothing is for sale.</summary>
public enum CinemaAd
{
    IceCream,
    Popcorn,
    Phones,
}

/// <summary>One line of an ad: shown from <see cref="From"/> until <see cref="Until"/> seconds.</summary>
public sealed record CinemaBeat(double From, double Until, string Text, bool Big = false, bool Fine = false);

/// <summary>One part of the pre-show, in a cinema's order: ad, trailers, then the curtain.</summary>
public abstract record CinemaAct
{
    public sealed record Ad(CinemaAd Which) : CinemaAct;

    public sealed record Trailer(CinemaTrailer Entry) : CinemaAct;

    /// <summary>"Aurelia Cinema Presents": the curtain opens onto the film.</summary>
    public sealed record Feature(string Title) : CinemaAct;
}

/// <summary>Cinema mode's rules, matching the Mac app's CinemaPreShowPlan.</summary>
public static class CinemaPlan
{
    /// <summary>The ads are timed as 15-second scripts and played slower, so there is time to read them.</summary>
    public const double Pace = 1.4;
    public const double AdSeconds = 15 * Pace;
    public const double ComingUpSeconds = 2.5;
    public const double CurtainEarliestOpening = 3.3;
    public const double CurtainLongestWait = 10;
    public const double CurtainOpeningSeconds = 4;
    public const double TrailerStartSeconds = 15;
    public const double TrailerLongestSeconds = 300;
    public const string LastAdKey = "playback.cinema.lastAd";

    /// <summary>A film (no series queue), cinema mode on with ads or trailers, a server that lists trailers, nobody watching along.</summary>
    public static bool Wanted(PlaybackPreferences preferences, MediaKind kind, bool serverListsTrailers, bool watchingTogether) =>
        preferences.CinemaMode && (preferences.CinemaAds || preferences.CinemaTrailers > 0)
        && kind == MediaKind.Movie && serverListsTrailers && !watchingTogether;

    /// <summary>Only a film that starts from its beginning gets a pre-show.</summary>
    public static bool StartsAtBeginning(bool resume, long? startAt, PlaybackProgressResponse? progress, PlaybackPreferences preferences)
    {
        if (startAt is { } at) return at <= 0;
        if (!resume || !preferences.AutomaticResume || progress is null || progress.IsCompleted) return true;
        return progress.PositionMilliseconds < preferences.ResumeThresholdSeconds * 1000L;
    }

    /// <summary>The ad, the trailers that aren't for the film itself, then the curtain; nothing without either.</summary>
    public static IReadOnlyList<CinemaAct> Acts(CinemaAd? ad, IEnumerable<CinemaTrailer> trailers, Guid film, string title)
    {
        var acts = new List<CinemaAct>();
        if (ad is { } which) acts.Add(new CinemaAct.Ad(which));
        acts.AddRange(trailers.Where(t => t.Title.Id != film && t.Trailer.ParentId != film).Select(t => new CinemaAct.Trailer(t)));
        if (acts.Count > 0) acts.Add(new CinemaAct.Feature(title));
        return acts;
    }

    /// <summary>The ads take turns, so the same one never runs twice in a row.</summary>
    public static CinemaAd NextAd(CinemaAd? last) => last switch
    {
        CinemaAd.IceCream => CinemaAd.Popcorn,
        CinemaAd.Popcorn => CinemaAd.Phones,
        _ => CinemaAd.IceCream,
    };

    /// <summary>The ad's lines with their times (scaled by <see cref="Pace"/>), from the browser's and the Mac's scripts.</summary>
    public static IReadOnlyList<CinemaBeat> Script(CinemaAd ad)
    {
        CinemaBeat[] beats = ad switch
        {
            CinemaAd.Popcorn =>
            [
                new(0.4, 5, "Aurelia Popcorn", Big: true),
                new(5, 9.5, "Louder than the film."),
                new(9.5, 13, "Now with extra crunch for the quiet scenes."),
                new(13, 16, "Crunch responsibly."),
                new(0, 16, "*Rustling the bag in the dark is included at no extra cost.", Fine: true),
            ],
            CinemaAd.Phones =>
            [
                new(0.2, 4, "A MESSAGE FROM YOUR CINEMA"),
                new(4, 8, "Mum: are you there · Group chat (48) · Battery 3% · Mum: ???"),
                new(8, 11, "Thank you.", Big: true),
                new(11, 14, "Phones off. Yes, yours too."),
                new(13.2, 16, "The group chat will survive. Probably."),
            ],
            _ =>
            [
                new(0.3, 3.4, "Feeling warm?"),
                new(3.4, 6.6, "Ninety minutes is a long t."),
                new(6.6, 11, "Aurelia Ice · Three scoops. Zero plot holes.", Big: true),
                new(11, 16, "ONLY 4.50! Now in the foyer."),
                new(0, 16, "*The foyer is your kitchen. Aurelia does not sell ice cream and never has.", Fine: true),
            ],
        };
        return [.. beats.Select(beat => beat with { From = beat.From * Pace, Until = beat.Until * Pace })];
    }

    public static string Title(CinemaAd ad) => ad switch
    {
        CinemaAd.Popcorn => "Aurelia Popcorn, a made-up ad",
        CinemaAd.Phones => "A made-up message from your cinema about phones",
        _ => "Aurelia Ice, a made-up ad",
    };
}

/// <summary>
/// Runs the pre-show before a film: ad, trailers through their own decoder and relay, then the
/// curtain while the film starts behind it. <see cref="Act"/> is what the view shows; the film
/// starts through <see cref="Feature"/>. Skip moves on, Start Film ends it, Stop when the player closes.
/// </summary>
public sealed class CinemaPreShow
{
    private readonly IReadOnlyList<CinemaAct> acts;
    private readonly PlaybackClient client;
    private readonly IVideoEngineFactory engines;
    private readonly TimeProvider time;
    private readonly Action<Action> post;
    private TaskCompletionSource? actDone;
    private bool finished;
    private bool skipped;
    private bool filmShowing;
    private bool waitingForFilm;

    public CinemaPreShow(IReadOnlyList<CinemaAct> acts, PlaybackClient client, IVideoEngineFactory engines, TimeProvider time, Action<Action> post)
    {
        this.acts = acts;
        this.client = client;
        this.engines = engines;
        this.time = time;
        this.post = post;
    }

    /// <summary>Raised on the UI thread whenever the act or its state changes.</summary>
    public event Action? Changed;

    /// <summary>Starts the film behind the curtain.</summary>
    public Func<Task>? Feature { get; set; }

    public CinemaAct? Act { get; private set; }

    public DateTimeOffset ActStarted { get; private set; }

    /// <summary>The trailer's decoder while one plays.</summary>
    public IVideoEngine? TrailerEngine { get; private set; }

    public bool TrailerPlaying { get; private set; }

    /// <summary>Seconds into the curtain at which it opens, once the film plays behind it.</summary>
    public double? CurtainOpensAt { get; private set; }

    public IReadOnlyList<CinemaAct> Acts => acts;

    /// <summary>The pre-show for <paramref name="film"/>, or null when it gets none. A slow server never holds up the film for more than five seconds.</summary>
    public static async Task<CinemaPreShow?> PrepareAsync(PlaybackClient client, IVideoEngineFactory engines, TimeProvider time, Action<Action> post,
        CatalogItemSummary film, bool resume, long? startAt, PlaybackPreferences preferences, Settings.ISettingsStore settings, bool watchingTogether)
    {
        if (!CinemaPlan.Wanted(preferences, film.Kind, client.Library.Supports(ServerFeatures.CinemaTrailers), watchingTogether)) return null;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        IReadOnlyList<CinemaTrailer> trailers;
        try
        {
            var progress = resume && startAt is null ? await client.ProgressAsync(film.Id, timeout.Token) : null;
            if (!CinemaPlan.StartsAtBeginning(resume, startAt, progress, preferences)) return null;
            trailers = preferences.CinemaTrailers > 0 ? await client.CinemaTrailersAsync(film.Id, preferences.CinemaTrailers, timeout.Token) : [];
        }
        catch (Exception failure) when (failure is Api.AureliaApiException or OperationCanceledException or HttpRequestException)
        {
            return null;
        }
        CinemaAd? ad = null;
        if (preferences.CinemaAds)
        {
            var last = settings.Read<string>(CinemaPlan.LastAdKey);
            ad = CinemaPlan.NextAd(Enum.TryParse<CinemaAd>(last, out var parsed) ? parsed : null);
            settings.Write(CinemaPlan.LastAdKey, ad.Value.ToString());
        }
        var acts = CinemaPlan.Acts(ad, trailers, film.Id, film.Title);
        return acts.Count == 0 ? null : new CinemaPreShow(acts, client, engines, time, post);
    }

    /// <summary>Plays every part; returns when the pre-show is over, ended or stopped.</summary>
    public async Task RunAsync()
    {
        foreach (var act in acts)
        {
            if (finished) break;
            Act = act;
            ActStarted = time.GetUtcNow();
            TrailerPlaying = false;
            skipped = false;
            Raise();
            switch (act)
            {
                case CinemaAct.Ad:
                    await WaitAsync(CinemaPlan.AdSeconds);
                    break;
                case CinemaAct.Trailer trailer:
                    await PlayAsync(trailer.Entry);
                    break;
                case CinemaAct.Feature:
                    await FeatureAsync();
                    break;
            }
        }
        Act = null;
        Raise();
    }

    public void Skip()
    {
        skipped = true;
        EndAct();
    }

    /// <summary>Straight to the film.</summary>
    public void StartFilm()
    {
        finished = true;
        skipped = true;
        EndAct();
    }

    /// <summary>The player closed.</summary>
    public void Stop()
    {
        finished = true;
        EndAct();
    }

    /// <summary>The film's picture is moving behind the curtain.</summary>
    public void FilmStarted()
    {
        filmShowing = true;
        if (waitingForFilm) EndAct();
    }

    private async Task FeatureAsync()
    {
        CurtainOpensAt = null;
        if (Feature is { } start) _ = start();
        await WaitAsync(CinemaPlan.CurtainEarliestOpening);
        if (skipped || finished) return;
        if (!filmShowing)
        {
            waitingForFilm = true;
            await WaitAsync(CinemaPlan.CurtainLongestWait - CinemaPlan.CurtainEarliestOpening);
            waitingForFilm = false;
            if (skipped || finished) return;
        }
        CurtainOpensAt = (time.GetUtcNow() - ActStarted).TotalSeconds;
        Raise();
        await WaitAsync(CinemaPlan.CurtainOpeningSeconds);
    }

    private async Task PlayAsync(CinemaTrailer entry)
    {
        PlaybackSourceResponse ticket;
        try { ticket = await client.StartAsync(entry.Trailer.Id, CancellationToken.None); }
        catch (Api.AureliaApiException) { return; }
        if (finished)
        {
            _ = RevokeAsync(ticket.Id);
            return;
        }
        await using var relay = new LoopbackStreamRelay(client.StreamConnection, client.StreamToken, client.StreamUri(ticket));
        var engine = engines.Create(nightMode: false);
        void Changed() => post(() =>
        {
            if (TrailerPlaying || !engine.IsPlaying || engine.Time <= 0) return;
            TrailerPlaying = true;
            Raise();
        });
        void Finished(EngineEnd _) => post(EndAct);
        engine.Changed += Changed;
        engine.Finished += Finished;
        TrailerEngine = engine;
        Raise();
        try
        {
            engine.Open(relay.Start(), 0);
            var started = time.GetUtcNow();
            using var check = time.CreateTimer(_ => post(() =>
            {
                if (!TrailerPlaying && time.GetUtcNow() - started >= TimeSpan.FromSeconds(CinemaPlan.TrailerStartSeconds)) EndAct();
            }), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
            await WaitAsync(CinemaPlan.TrailerLongestSeconds);
        }
        finally
        {
            engine.Changed -= Changed;
            engine.Finished -= Finished;
            TrailerEngine = null;
            engine.Unload();
            engine.Dispose();
            Raise();
            _ = RevokeAsync(ticket.Id);
        }
    }

    private async Task RevokeAsync(Guid ticket)
    {
        try { await client.RevokeAsync(ticket, CancellationToken.None); }
        catch (Api.AureliaApiException) { }
    }

    private Task WaitAsync(double seconds)
    {
        if (finished) return Task.CompletedTask;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        actDone = done;
        var timer = time.CreateTimer(_ => post(() => { if (actDone == done) EndAct(); }), null, TimeSpan.FromSeconds(seconds), Timeout.InfiniteTimeSpan);
        return done.Task.ContinueWith(_ => timer.Dispose(), TaskScheduler.Default);
    }

    private void EndAct()
    {
        var done = actDone;
        actDone = null;
        done?.TrySetResult();
    }

    private void Raise() => Changed?.Invoke();
}
