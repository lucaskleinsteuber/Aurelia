using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services.Segments;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Finds intros and credits in the background by comparing the sound of the episodes of a season
/// (see <see cref="SeasonSegmentAnalyzer"/>). Sound and fingerprints exist only in memory; only
/// the resulting timestamps are stored, in the database. The work runs one short read at a time
/// at low priority and waits whenever anyone is watching or converting.
/// </summary>
public sealed partial class SegmentDetectionService : BackgroundService
{
    public const string SettingsFileName = "media-segment-settings.json";

    /// <summary>Raised whenever thresholds or rules change, so every episode is examined again.</summary>
    /// <remarks>2: credits are also found in pictures (text on black, pictures episodes share).</remarks>
    public const int AnalysisVersion = 2;

    /// <summary>Raised whenever the movie rules change; movies have their own so episodes are not examined again.</summary>
    /// <remarks>1: credits from chapters and from text on black in the last pictures (since 2.11.0).</remarks>
    public const int MovieAnalysisVersion = 1;

    /// <summary>The queue's season number for a movie, whose id stands in the series' place.</summary>
    private const int MovieEntry = int.MinValue;

    /// <summary>Shorter episodes have too little sound outside intro and credits to compare.</summary>
    public const double MinimumEpisodeSeconds = 180;

    private const int NeighbourReach = 8;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static readonly TimeSpan StatusLifetime = TimeSpan.FromSeconds(5);

    private readonly ServerRuntimeOptions runtime;
    private readonly IServiceScopeFactory scopes;
    private readonly LiveConversionService live;
    private readonly ActiveStreamRegistry streams;
    private readonly SegmentAudioReader reader;
    private readonly CatalogMutationGate mutations;
    private readonly ILogger<SegmentDetectionService> logger;
    private readonly TimeProvider clock;
    private readonly string settingsPath;
    private readonly object settingsGate = new();
    private readonly SemaphoreSlim workSignal = new(0, int.MaxValue);
    private readonly SemaphoreSlim processing = new(1, 1);
    private readonly ConcurrentQueue<(Guid Series, int Season)> queue = new();
    private readonly ConcurrentDictionary<(Guid Series, int Season), byte> queued = new();

    private StoredSettings settings;
    private int running;
    private int pausedForPlayback;
    private int rescanRequested;
    private (DateTimeOffset At, Counts Counts)? status;

    private sealed record StoredSettings(bool Enabled, bool Pictures = true);

    /// <summary>What the job is doing now, for the owner's progress display.</summary>
    private sealed record Activity(string Title, string Step);

    private Activity? activity;
    private double? secondsPerEpisode;

    private sealed record EpisodeState(Guid Id, Guid Series, int Season, long? FileSize, DateTimeOffset? FileModifiedAt);

    private sealed record MovieState(Guid Id, long? FileSize, DateTimeOffset? FileModifiedAt);

    private sealed record LibraryState(List<EpisodeState> Episodes, List<MovieState> Movies, Dictionary<Guid, RowState> Rows);

    private sealed record Counts(int Pending, int Analyzed, int NoResult, int Movies, int MoviesWithCredits, int MoviesPending);

    private sealed record RowState(Guid MediaItemId, MediaSegmentSource IntroSource, MediaSegmentSource CreditsSource, int AnalysisVersion,
        long? AnalyzedFileSize, DateTimeOffset? AnalyzedFileModifiedAt);

    private sealed class EpisodeInfo(MediaItem media)
    {
        public MediaItem Media { get; } = media;
        public bool Offline { get; set; }
        public double Duration { get; set; }
        public long Length { get; set; }
        public DateTimeOffset LastModified { get; set; }
        public ProbedAudio? Track { get; set; }
        public int? VideoIndex { get; set; }
        public string Label { get; set; } = string.Empty;
        public IReadOnlyList<SegmentChapter> Chapters { get; set; } = [];
    }

    public SegmentDetectionService(
        ServerRuntimeOptions runtime,
        IServiceScopeFactory scopes,
        LiveConversionService live,
        ActiveStreamRegistry streams,
        SegmentAudioReader reader,
        CatalogMutationGate mutations,
        ILogger<SegmentDetectionService> logger,
        TimeProvider? clock = null)
    {
        this.runtime = runtime;
        this.scopes = scopes;
        this.live = live;
        this.streams = streams;
        this.reader = reader;
        this.mutations = mutations;
        this.logger = logger;
        this.clock = clock ?? TimeProvider.System;
        settingsPath = Path.Combine(runtime.DataDirectory, SettingsFileName);
        settings = LoadSettings();
    }

    public override void Dispose()
    {
        base.Dispose();
        workSignal.Dispose();
        processing.Dispose();
    }

    public bool IsEnabled
    {
        get { lock (settingsGate) return settings.Enabled; }
    }

    /// <summary>Whether credits are also looked for in pictures, which takes much longer.</summary>
    public bool UsesPictures
    {
        get { lock (settingsGate) return settings.Pictures; }
    }

    /// <summary>The rules' version a title of this kind is examined with.</summary>
    public static int VersionFor(MediaKind kind) => kind == MediaKind.Movie ? MovieAnalysisVersion : AnalysisVersion;

    /// <summary>Whether a stored row still describes this file under the current rules.</summary>
    public static bool IsCurrent(MediaSegment row, MediaKind kind, long? fileSize, DateTimeOffset? fileModifiedAt)
    {
        ArgumentNullException.ThrowIfNull(row);
        return row.AnalysisVersion == VersionFor(kind) && row.AnalyzedFileSize == fileSize
            && row.AnalyzedFileModifiedAt?.ToUnixTimeMilliseconds() == fileModifiedAt?.ToUnixTimeMilliseconds();
    }

    /// <summary>Hook after a library scan: new or changed episodes are examined.</summary>
    public void NotifyScanCompleted()
    {
        if (!IsEnabled) return;
        Interlocked.Exchange(ref rescanRequested, 1);
        Signal();
    }

    /// <summary>Asks for one season to be examined soon, for example after a correction was removed.</summary>
    public void RequestSeason(Guid seriesId, int seasonNumber)
    {
        if (!IsEnabled) return;
        Enqueue(seriesId, seasonNumber);
        Signal();
    }

    /// <summary>Asks for one movie to be examined soon.</summary>
    public void RequestMovie(Guid movieId)
    {
        if (!IsEnabled) return;
        Enqueue(movieId, MovieEntry);
        Signal();
    }

    public async Task<MediaSegmentSettingsResponse> ReadSettingsAsync(CancellationToken cancellationToken)
    {
        var tools = await live.ToolsAsync();
        var counts = await CountsAsync(cancellationToken);
        var active = Volatile.Read(ref running) > 0;
        var current = activity;
        var waiting = counts.Pending + counts.MoviesPending;
        var estimate = secondsPerEpisode is { } each && waiting > 0 ? (int?)Math.Ceiling(each * waiting) : null;
        return new MediaSegmentSettingsResponse(
            tools is { Speech: not SpeechAudioSupport.None },
            IsEnabled,
            counts.Pending,
            counts.Analyzed,
            counts.NoResult,
            active,
            Volatile.Read(ref pausedForPlayback) > 0,
            UsesPictures,
            counts.Pending + counts.Analyzed + counts.NoResult,
            active ? current?.Title : null,
            active ? current?.Step : null,
            estimate,
            counts.Movies,
            counts.MoviesWithCredits,
            counts.MoviesPending);
    }

    public async Task<MediaSegmentSettingsResponse> UpdateSettingsAsync(UpdateMediaSegmentSettingsRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        StoredSettings previous;
        lock (settingsGate) previous = settings;
        var updated = new StoredSettings(request.Enabled, request.UsePictures ?? previous.Pictures);
        lock (settingsGate)
        {
            PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
            var temporary = settingsPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporary))
                {
                    JsonSerializer.Serialize(file, updated, Json);
                    file.Flush(flushToDisk: true);
                }
                File.Move(temporary, settingsPath, overwrite: true);
                PrivateFilePermissions.ProtectFile(settingsPath);
                settings = updated;
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        if (updated.Enabled && updated.Pictures && !previous.Pictures)
        {
            // Episodes examined without pictures are examined again with them.
            await MarkAllForAnalysisAsync(cancellationToken);
        }
        if (updated.Enabled)
        {
            Interlocked.Exchange(ref rescanRequested, 1);
            Signal();
        }
        else
        {
            ClearQueue();
        }
        return await ReadSettingsAsync(cancellationToken);
    }

    /// <summary>
    /// Marks the automatic times of a series, one season, or everything for a new analysis and
    /// queues it. Without a series, <paramref name="movies"/> chooses only movies (true), only
    /// episodes (false) or both (null). Times set by hand stay.
    /// </summary>
    public async Task<MediaSegmentSettingsResponse> ReanalyzeAsync(Guid? seriesId, int? seasonNumber, CancellationToken cancellationToken, bool? movies = null)
    {
        using (await mutations.EnterAsync(cancellationToken))
        {
            await using var scope = scopes.CreateAsyncScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            if (seriesId is { } series && !await database.MediaItems.IgnoreQueryFilters().AnyAsync(item => item.Id == series && item.Kind == MediaKind.Series, cancellationToken))
                throw new AccountException("media_not_found", "The series was not found.", 404);
            var episodes = seriesId is not null || movies != true;
            var films = seriesId is null && seasonNumber is null && movies != false;
            await database.MediaSegments.IgnoreQueryFilters()
                .Where(segment => (episodes && segment.MediaItem.Kind == MediaKind.Episode
                        && (seriesId == null || segment.MediaItem.ParentId == seriesId)
                        && (seasonNumber == null || (segment.MediaItem.SeasonNumber ?? 0) == seasonNumber))
                    || (films && segment.MediaItem.Kind == MediaKind.Movie))
                .ExecuteUpdateAsync(update => update.SetProperty(segment => segment.AnalysisVersion, 0), cancellationToken);
        }
        status = null;
        Interlocked.Exchange(ref rescanRequested, 1);
        Signal();
        return await ReadSettingsAsync(cancellationToken);
    }

    /// <summary>Examines one movie again; times set by hand stay.</summary>
    public async Task<MediaSegmentSettingsResponse> ReanalyzeMovieAsync(Guid movieId, CancellationToken cancellationToken)
    {
        using (await mutations.EnterAsync(cancellationToken))
        {
            await using var scope = scopes.CreateAsyncScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            await database.MediaSegments.IgnoreQueryFilters()
                .Where(segment => segment.MediaItemId == movieId && segment.MediaItem.Kind == MediaKind.Movie)
                .ExecuteUpdateAsync(update => update.SetProperty(segment => segment.AnalysisVersion, 0), cancellationToken);
        }
        status = null;
        RequestMovie(movieId);
        return await ReadSettingsAsync(cancellationToken);
    }

    private async Task MarkAllForAnalysisAsync(CancellationToken cancellationToken)
    {
        using (await mutations.EnterAsync(cancellationToken))
        {
            await using var scope = scopes.CreateAsyncScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            await database.MediaSegments.IgnoreQueryFilters()
                .ExecuteUpdateAsync(update => update.SetProperty(segment => segment.AnalysisVersion, 0), cancellationToken);
        }
        status = null;
    }

    /// <summary>For each series: its episodes, how many have an intro or credits, and how many are still to examine.</summary>
    public async Task<IReadOnlyList<MediaSegmentSeriesStatus>> SeriesStatusAsync(CancellationToken cancellationToken)
    {
        var (episodes, _, rows) = await LoadStateAsync(cancellationToken);
        Dictionary<Guid, string> titles;
        await using (var scope = scopes.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var ids = episodes.Select(episode => episode.Series).Distinct().ToArray();
            titles = await TitlesAsync(database, ids, cancellationToken);
        }
        var comparable = episodes.GroupBy(episode => (episode.Series, episode.Season)).Where(season => season.Count() >= 2)
            .SelectMany(season => season).Select(episode => episode.Id).ToHashSet();
        return [.. episodes.GroupBy(episode => episode.Series).Select(series => new MediaSegmentSeriesStatus(
                series.Key,
                titles.GetValueOrDefault(series.Key, string.Empty),
                series.Count(),
                series.Count(episode => !Needs(rows, episode) && rows[episode.Id].IntroSource != MediaSegmentSource.None),
                series.Count(episode => !Needs(rows, episode) && rows[episode.Id].CreditsSource != MediaSegmentSource.None),
                series.Count(episode => Needs(rows, episode) && comparable.Contains(episode.Id))))
            .OrderBy(series => series.Title, StringComparer.CurrentCultureIgnoreCase)];
    }

    private static async Task<Dictionary<Guid, string>> TitlesAsync(AureliaDbContext database, Guid[] ids, CancellationToken cancellationToken) =>
        await database.MediaItems.IgnoreQueryFilters().AsNoTracking().Where(item => ids.Contains(item.Id))
            .Select(item => new
            {
                item.Id,
                Title = database.MediaMetadata.Where(metadata => metadata.MediaItemId == item.Id)
                    .Select(metadata => metadata.ManualTitle ?? metadata.ProviderTitle).FirstOrDefault() ?? item.OverrideTitle ?? item.DetectedTitle,
            })
            .ToDictionaryAsync(item => item.Id, item => item.Title, cancellationToken);

    /// <summary>
    /// Queues every season with an episode, and every movie, that was not examined in its current
    /// file version. Seasons come first; movies follow.
    /// </summary>
    public async Task<int> QueuePendingSeasonsAsync(CancellationToken cancellationToken)
    {
        if (!IsEnabled) return 0;
        var (episodes, movies, rows) = await LoadStateAsync(cancellationToken);
        var added = 0;
        foreach (var season in episodes.GroupBy(episode => (episode.Series, episode.Season)))
        {
            if (season.Count() < 2 || !season.Any(episode => Needs(rows, episode))) continue;
            if (Enqueue(season.Key.Series, season.Key.Season)) added++;
        }
        foreach (var movie in movies)
        {
            if (Needs(rows, movie) && Enqueue(movie.Id, MovieEntry)) added++;
        }
        return added;
    }

    /// <summary>Examines every queued season; the background loop and tests call this.</summary>
    public async Task<int> ProcessPendingAsync(CancellationToken cancellationToken)
    {
        await processing.WaitAsync(cancellationToken);
        try
        {
            var analyzed = 0;
            while (IsEnabled && queue.TryDequeue(out var season))
            {
                queued.TryRemove(season, out _);
                cancellationToken.ThrowIfCancellationRequested();
                Interlocked.Increment(ref running);
                try
                {
                    analyzed += season.Season == MovieEntry
                        ? await AnalyzeMovieAsync(season.Series, cancellationToken)
                        : await AnalyzeSeasonAsync(season.Series, season.Season, cancellationToken);
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    if (season.Season == MovieEntry) LogMovieFailed(logger, season.Series, exception);
                    else LogSeasonFailed(logger, season.Series, season.Season, exception);
                }
                finally
                {
                    Interlocked.Decrement(ref running);
                    status = null;
                }
            }
            return analyzed;
        }
        finally
        {
            processing.Release();
        }
    }

    /// <summary>
    /// Examines the episodes of one season that need it and stores their times. Returns how many
    /// episodes were examined.
    /// </summary>
    public async Task<int> AnalyzeSeasonAsync(Guid seriesId, int seasonNumber, CancellationToken cancellationToken)
    {
        if (await live.ToolsAsync() is not { Speech: not SpeechAudioSupport.None } tools) return 0;

        List<MediaItem> episodes;
        Dictionary<Guid, MediaSegment> rows;
        await using (var scope = scopes.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            episodes = await database.MediaItems.IgnoreQueryFilters().AsNoTracking().Include(item => item.LibraryRoot)
                .Where(item => item.Kind == MediaKind.Episode && item.ParentId == seriesId && (item.SeasonNumber ?? 0) == seasonNumber
                    && item.Availability == MediaAvailability.Available)
                .ToListAsync(cancellationToken);
            var ids = episodes.Select(item => item.Id).ToArray();
            rows = await database.MediaSegments.IgnoreQueryFilters().AsNoTracking()
                .Where(segment => ids.Contains(segment.MediaItemId)).ToDictionaryAsync(segment => segment.MediaItemId, cancellationToken);
        }
        if (episodes.Count < 2) return 0;
        episodes = [.. episodes.OrderBy(item => item.EpisodeNumber ?? int.MaxValue).ThenBy(item => item.SourcePath, StringComparer.Ordinal)];

        bool NeedsAnalysis(MediaItem item) => !rows.TryGetValue(item.Id, out var row) || !IsCurrent(row, MediaKind.Episode, item.FileSize, item.FileModifiedAt);
        var needing = Enumerable.Range(0, episodes.Count).Where(index => NeedsAnalysis(episodes[index])).ToArray();
        if (needing.Length == 0) return 0;

        // Only the episodes to examine and their nearest neighbours are opened.
        var involved = Enumerable.Range(0, episodes.Count)
            .Where(index => needing.Any(needed => Math.Abs(needed - index) <= NeighbourReach)).ToArray();
        var infos = new EpisodeInfo[involved.Length];
        for (var index = 0; index < involved.Length; index++)
        {
            infos[index] = await DescribeAsync(tools, episodes[involved[index]], cancellationToken);
        }

        string seriesTitle;
        await using (var scope = scopes.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            seriesTitle = (await TitlesAsync(database, [seriesId], cancellationToken)).GetValueOrDefault(seriesId, string.Empty);
        }
        foreach (var info in infos)
        {
            info.Label = string.Create(CultureInfo.InvariantCulture,
                $"{seriesTitle} · S{seasonNumber:00}E{info.Media.EpisodeNumber ?? 0:00}");
        }

        var pictures = UsesPictures;
        var analyzer = new SeasonSegmentAnalyzer(
            [.. infos.Select(info => new SegmentEpisode(info.Duration, info.Chapters))],
            (index, kind, token) => LoadWindowAsync(tools, infos[index], kind, token),
            pictures ? (index, start, length, token) => LoadPicturesAsync(tools, infos[index], start, length, token) : null);
        var analyzed = 0;
        for (var index = 0; index < involved.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsEnabled) break;
            var info = infos[index];
            if (!NeedsAnalysis(info.Media) || info.Offline) continue;
            var started = clock.GetTimestamp();
            activity = new Activity(info.Label, "Comparing with other episodes");
            var result = info.Duration >= MinimumEpisodeSeconds
                ? await analyzer.AnalyzeAsync(index, cancellationToken)
                : DetectedSegments.Nothing;
            await SaveAsync(info.Media, result, AnalysisVersion, cancellationToken);
            analyzed++;
            status = null;
            // A running average, so the estimate follows this server's speed and the library's mix.
            var seconds = clock.GetElapsedTime(started).TotalSeconds;
            secondsPerEpisode = secondsPerEpisode is { } average ? average * 0.8 + seconds * 0.2 : seconds;
        }
        activity = null;
        return analyzed;
    }

    /// <summary>
    /// Examines one movie (see <see cref="MovieSegmentAnalyzer"/>): credits from a chapter or its
    /// last pictures, an intro only from a chapter. Returns 1 when it was examined.
    /// </summary>
    public async Task<int> AnalyzeMovieAsync(Guid movieId, CancellationToken cancellationToken)
    {
        if (await live.ToolsAsync() is not { Speech: not SpeechAudioSupport.None } tools) return 0;
        MediaItem? movie;
        MediaSegment? row;
        string title;
        await using (var scope = scopes.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            movie = await database.MediaItems.IgnoreQueryFilters().AsNoTracking().Include(item => item.LibraryRoot)
                .SingleOrDefaultAsync(item => item.Id == movieId && item.Kind == MediaKind.Movie && item.Availability == MediaAvailability.Available, cancellationToken);
            if (movie is null) return 0;
            row = await database.MediaSegments.IgnoreQueryFilters().AsNoTracking().SingleOrDefaultAsync(segment => segment.MediaItemId == movieId, cancellationToken);
            title = (await TitlesAsync(database, [movieId], cancellationToken)).GetValueOrDefault(movieId, string.Empty);
        }
        if (row is not null && IsCurrent(row, MediaKind.Movie, movie.FileSize, movie.FileModifiedAt)) return 0;
        var started = clock.GetTimestamp();
        var info = await DescribeAsync(tools, movie, cancellationToken);
        if (info.Offline) return 0;
        info.Label = title;
        activity = new Activity(title, "Looking for the credits");
        try
        {
            var analyzer = new MovieSegmentAnalyzer(new SegmentEpisode(info.Duration, info.Chapters),
                UsesPictures ? (start, length, token) => LoadPicturesAsync(tools, info, start, length, token) : null);
            var result = await analyzer.AnalyzeAsync(cancellationToken);
            if (!IsEnabled) return 0;
            await SaveAsync(movie, result, MovieAnalysisVersion, cancellationToken);
        }
        finally
        {
            activity = null;
        }
        status = null;
        var seconds = clock.GetElapsedTime(started).TotalSeconds;
        secondsPerEpisode = secondsPerEpisode is { } average ? average * 0.8 + seconds * 0.2 : seconds;
        return 1;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            // Let the server finish starting before any sound is read.
            await Task.Delay(TimeSpan.FromSeconds(45), stoppingToken);
            Interlocked.Exchange(ref rescanRequested, 1);
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    if (Interlocked.Exchange(ref rescanRequested, 0) == 1) await QueuePendingSeasonsAsync(stoppingToken);
                    await ProcessPendingAsync(stoppingToken);
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    LogLoopFailed(logger, exception);
                    await Task.Delay(TimeSpan.FromMinutes(1), stoppingToken);
                }
                if (Volatile.Read(ref rescanRequested) == 0) await workSignal.WaitAsync(stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    private async Task<EpisodeInfo> DescribeAsync(FfmpegTools tools, MediaItem media, CancellationToken cancellationToken)
    {
        var info = new EpisodeInfo(media);
        OpenMediaFile file;
        try
        {
            file = MediaFileAccess.OpenRead(media);
        }
        catch (PlaybackException)
        {
            info.Offline = true;
            return info;
        }
        await using var stream = file.Stream;
        info.Length = file.Length;
        info.LastModified = file.LastModified;
        try
        {
            var probe = await live.ProbeAsync(tools, file, Path.GetFullPath(media.SourcePath), media.Id, cancellationToken);
            info.Duration = probe.DurationSeconds ?? 0;
            info.Track = LiveSpeechAudio.Choose(probe.Audio, null);
            info.VideoIndex = probe.Video?.Index;
            info.Chapters = [.. (probe.Chapters ?? []).Select(chapter => new SegmentChapter(chapter.StartSeconds, chapter.EndSeconds, chapter.Title))];
        }
        catch (PlaybackException)
        {
            // An unreadable header: stored as "nothing found" so it is not tried on every scan.
        }
        catch (IOException)
        {
            info.Offline = true;
        }
        return info;
    }

    private async Task<SegmentWindow?> LoadWindowAsync(FfmpegTools tools, EpisodeInfo info, SegmentKind kind, CancellationToken cancellationToken)
    {
        if (info.Offline || info.Track is not { } track || info.Duration < MinimumEpisodeSeconds) return null;
        var (start, length) = kind switch
        {
            SegmentKind.Intro => (0, SegmentRules.IntroWindowSeconds(info.Duration)),
            SegmentKind.LateIntro => (SegmentRules.LateIntroStartSeconds(info.Duration), SegmentRules.LateIntroLengthSeconds(info.Duration)),
            _ => (Math.Max(0, info.Duration - SegmentRules.CreditsWindowSeconds(info.Duration)), SegmentRules.CreditsWindowSeconds(info.Duration)),
        };
        if (length <= 0) return null;

        activity = new Activity(info.Label, kind switch
        {
            SegmentKind.Intro => "Listening to the beginning",
            SegmentKind.LateIntro => "Listening further for a late intro",
            _ => "Listening to the ending",
        });
        IDisposable? slot = null;
        while (slot is null)
        {
            await WaitWhilePlaybackBusyAsync(cancellationToken);
            slot = await live.EnterAsync(encodesVideo: false, cancellationToken);
        }
        short[]? samples;
        try
        {
            OpenMediaFile file;
            try
            {
                file = MediaFileAccess.OpenRead(info.Media);
            }
            catch (PlaybackException)
            {
                return null;
            }
            await using var stream = file.Stream;
            if (file.Length != info.Length || file.LastModified != info.LastModified) return null;
            samples = await reader.ReadAsync(tools, file, Path.GetFullPath(info.Media.SourcePath), track, start, length, cancellationToken);
        }
        finally
        {
            slot.Dispose();
        }
        if (samples is null || samples.Length < AudioFingerprint.SampleRate * 30) return null;
        return await FingerprintAsync(samples, start);
    }

    /// <summary>
    /// Pictures of the episode, two a second. Decoding them is the slowest part, so it
    /// stops as soon as someone starts watching and begins again once they are done.
    /// </summary>
    private async Task<PictureWindow?> LoadPicturesAsync(FfmpegTools tools, EpisodeInfo info, double start, double length, CancellationToken cancellationToken)
    {
        if (info.Offline || info.VideoIndex is not { } video || info.Duration < MinimumEpisodeSeconds || length <= 0) return null;
        var step = start < info.Duration / 2 ? "Looking at the beginning's pictures" : "Looking at the ending's pictures";
        while (true)
        {
            activity = new Activity(info.Label, step);
            await WaitWhilePlaybackBusyAsync(cancellationToken);
            using var slot = await live.EnterAsync(encodesVideo: false, cancellationToken);
            if (slot is null) continue;
            OpenMediaFile file;
            try
            {
                file = MediaFileAccess.OpenRead(info.Media);
            }
            catch (PlaybackException)
            {
                return null;
            }
            await using var stream = file.Stream;
            if (file.Length != info.Length || file.LastModified != info.LastModified) return null;
            using var interrupt = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var watcher = WatchForPlaybackAsync(interrupt);
            PictureWindow? window = null;
            try
            {
                window = await reader.ReadPicturesAsync(tools, file, Path.GetFullPath(info.Media.SourcePath), video, start, length, interrupt.Token);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                // Someone started watching; the pictures are read again later.
            }
            var interrupted = interrupt.IsCancellationRequested;
            await interrupt.CancelAsync();
            await watcher;
            cancellationToken.ThrowIfCancellationRequested();
            if (!interrupted) return window;
        }
    }

    /// <summary>Cancels <paramref name="interrupt"/> when someone starts watching.</summary>
    private async Task WatchForPlaybackAsync(CancellationTokenSource interrupt)
    {
        try
        {
            while (!interrupt.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(2), interrupt.Token);
                if (IsBusyWithPlayback())
                {
                    await interrupt.CancelAsync();
                    return;
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Fingerprints on its own low-priority thread, so requests are never kept waiting.</summary>
    private static Task<SegmentWindow> FingerprintAsync(short[] samples, double start) => Task.Factory.StartNew(() =>
    {
        try { Thread.CurrentThread.Priority = ThreadPriority.BelowNormal; }
        catch (Exception exception) when (exception is ThreadStateException or PlatformNotSupportedException) { }
        return SegmentWindow.FromPcm(samples, start);
    }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);

    private async Task SaveAsync(MediaItem media, DetectedSegments result, int version, CancellationToken cancellationToken)
    {
        using var lease = await mutations.EnterAsync(cancellationToken);
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var row = await database.MediaSegments.IgnoreQueryFilters().SingleOrDefaultAsync(segment => segment.MediaItemId == media.Id, cancellationToken);
        if (row is null)
        {
            if (!await database.MediaItems.IgnoreQueryFilters().AnyAsync(item => item.Id == media.Id, cancellationToken)) return;
            row = new MediaSegment { MediaItemId = media.Id };
            database.MediaSegments.Add(row);
        }
        // A correction made by hand always wins over automatic results.
        if (row.IntroSource != MediaSegmentSource.Manual)
        {
            row.IntroStartMilliseconds = Milliseconds(result.IntroStart);
            row.IntroEndMilliseconds = Milliseconds(result.IntroEnd);
            row.IntroSource = result.IntroSource;
            row.IntroConfidence = result.IntroConfidence;
        }
        if (row.CreditsSource != MediaSegmentSource.Manual)
        {
            row.CreditsStartMilliseconds = Milliseconds(result.CreditsStart);
            row.CreditsSource = result.CreditsSource;
            row.CreditsConfidence = result.CreditsConfidence;
        }
        row.AnalysisVersion = version;
        row.AnalyzedFileSize = media.FileSize;
        row.AnalyzedFileModifiedAt = media.FileModifiedAt;
        row.UpdatedAt = clock.GetUtcNow();
        try
        {
            await database.SaveChangesAsync(cancellationToken);
        }
        catch (DbUpdateException)
        {
            // The title was removed while it was examined; its times go with it.
        }
    }

    private static long? Milliseconds(double? seconds) => seconds is { } value ? (long)Math.Round(value * 1000) : null;

    private async Task<Counts> CountsAsync(CancellationToken cancellationToken)
    {
        if (status is { } cached && clock.GetUtcNow() - cached.At < StatusLifetime) return cached.Counts;
        var (episodes, movies, rows) = await LoadStateAsync(cancellationToken);
        int pending = 0, analyzed = 0, noResult = 0;
        foreach (var season in episodes.GroupBy(episode => (episode.Series, episode.Season)))
        {
            var comparable = season.Count() >= 2;
            foreach (var episode in season)
            {
                if (Needs(rows, episode))
                {
                    if (comparable) pending++;
                }
                else if (rows[episode.Id] is { IntroSource: MediaSegmentSource.None, CreditsSource: MediaSegmentSource.None })
                {
                    noResult++;
                }
                else
                {
                    analyzed++;
                }
            }
        }
        var moviesPending = movies.Count(movie => Needs(rows, movie));
        var moviesWithCredits = movies.Count(movie => !Needs(rows, movie) && rows[movie.Id].CreditsSource != MediaSegmentSource.None);
        var counts = new Counts(pending, analyzed, noResult, movies.Count, moviesWithCredits, moviesPending);
        status = (clock.GetUtcNow(), counts);
        return counts;
    }

    private async Task<LibraryState> LoadStateAsync(CancellationToken cancellationToken)
    {
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var episodes = await database.MediaItems.IgnoreQueryFilters().AsNoTracking()
            .Where(item => item.Kind == MediaKind.Episode && item.ParentId != null && item.Availability == MediaAvailability.Available)
            .Select(item => new EpisodeState(item.Id, item.ParentId!.Value, item.SeasonNumber ?? 0, item.FileSize, item.FileModifiedAt))
            .ToListAsync(cancellationToken);
        var movies = await database.MediaItems.IgnoreQueryFilters().AsNoTracking()
            .Where(item => item.Kind == MediaKind.Movie && item.Availability == MediaAvailability.Available)
            .Select(item => new MovieState(item.Id, item.FileSize, item.FileModifiedAt))
            .ToListAsync(cancellationToken);
        var rows = await database.MediaSegments.IgnoreQueryFilters().AsNoTracking()
            .Select(segment => new RowState(segment.MediaItemId, segment.IntroSource, segment.CreditsSource, segment.AnalysisVersion,
                segment.AnalyzedFileSize, segment.AnalyzedFileModifiedAt))
            .ToDictionaryAsync(segment => segment.MediaItemId, cancellationToken);
        return new LibraryState(episodes, movies, rows);
    }

    private static bool Needs(Dictionary<Guid, RowState> rows, EpisodeState episode) =>
        Needs(rows, episode.Id, AnalysisVersion, episode.FileSize, episode.FileModifiedAt);

    private static bool Needs(Dictionary<Guid, RowState> rows, MovieState movie) =>
        Needs(rows, movie.Id, MovieAnalysisVersion, movie.FileSize, movie.FileModifiedAt);

    private static bool Needs(Dictionary<Guid, RowState> rows, Guid id, int version, long? fileSize, DateTimeOffset? fileModifiedAt) =>
        !rows.TryGetValue(id, out var row) || row.AnalysisVersion != version || row.AnalyzedFileSize != fileSize
        || row.AnalyzedFileModifiedAt?.ToUnixTimeMilliseconds() != fileModifiedAt?.ToUnixTimeMilliseconds();

    private bool IsBusyWithPlayback() => streams.PlaybackCount > 0 || live.Running > 0;

    private async Task WaitWhilePlaybackBusyAsync(CancellationToken cancellationToken)
    {
        if (!IsBusyWithPlayback()) return;
        Interlocked.Increment(ref pausedForPlayback);
        try
        {
            while (IsBusyWithPlayback())
            {
                cancellationToken.ThrowIfCancellationRequested();
                await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
            }
        }
        finally
        {
            Interlocked.Decrement(ref pausedForPlayback);
        }
    }

    private bool Enqueue(Guid seriesId, int seasonNumber)
    {
        if (!queued.TryAdd((seriesId, seasonNumber), 1)) return false;
        queue.Enqueue((seriesId, seasonNumber));
        return true;
    }

    private void ClearQueue()
    {
        while (queue.TryDequeue(out _)) { }
        queued.Clear();
    }

    private void Signal()
    {
        try { workSignal.Release(); }
        catch (Exception exception) when (exception is SemaphoreFullException or ObjectDisposedException) { }
    }

    private StoredSettings LoadSettings()
    {
        try
        {
            if (File.Exists(settingsPath) && JsonSerializer.Deserialize<StoredSettings>(File.ReadAllText(settingsPath), Json) is { } stored) return stored;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { }
        return new StoredSettings(Enabled: true);
    }

    [LoggerMessage(LogLevel.Warning, "Intro and credits detection failed for season {Season} of series {Series}.")]
    private static partial void LogSeasonFailed(ILogger logger, Guid series, int season, Exception exception);

    [LoggerMessage(LogLevel.Warning, "Credits detection failed for movie {Movie}.")]
    private static partial void LogMovieFailed(ILogger logger, Guid movie, Exception exception);

    [LoggerMessage(LogLevel.Warning, "Intro and credits detection stopped and will retry.")]
    private static partial void LogLoopFailed(ILogger logger, Exception exception);
}
