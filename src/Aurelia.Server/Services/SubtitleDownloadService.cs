using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>What OpenSubtitles last said about today's downloads, kept in memory only.</summary>
public sealed class SubtitleQuota(TimeProvider clock)
{
    private readonly object gate = new();
    public int? Remaining { get; private set; }
    public DateTimeOffset? ResetsAt { get; private set; }
    public DateTimeOffset? LastAutomaticRunAt { get; set; }

    public void Update(int? remaining, DateTimeOffset? resetsAt)
    {
        lock (gate)
        {
            Remaining = remaining;
            ResetsAt = resetsAt;
        }
    }

    /// <summary>True while the provider said no downloads are left and the reset has not come yet.</summary>
    public bool Exhausted
    {
        get
        {
            lock (gate)
            {
                if (Remaining is not <= 0) return false;
                return ResetsAt is null ? LastAutomaticRunAt is { } run && clock.GetUtcNow() - run < TimeSpan.FromHours(12) : ResetsAt > clock.GetUtcNow();
            }
        }
    }
}

/// <summary>
/// Searches and downloads subtitles for one movie or episode, lists and removes them, and runs the
/// optional automatic download for titles that lack a chosen language. The media file is only
/// read (its hash and header), never changed.
/// </summary>
public sealed partial class SubtitleDownloadService(
    AureliaDbContext database,
    SubtitleProviderSettingsStore settings,
    DownloadedSubtitleStore store,
    IOpenSubtitlesClient provider,
    SubtitleQuota quota,
    LiveConversionService live,
    TimeProvider clock,
    ILogger<SubtitleDownloadService> logger)
{
    public const string ProviderName = "OpenSubtitles";
    /// <summary>Subtitles a device wrote from the title's speech.</summary>
    public const string SpeechProviderName = "Speech";
    /// <summary>A copy of one of the title's subtitles that a device moved to fit its speech.</summary>
    public const string SyncedProviderName = "Synced";
    public const string Attribution = "Subtitles from OpenSubtitles.com";
    public static readonly TimeSpan RecheckAfter = TimeSpan.FromDays(7);

    public SubtitleProviderStatus Status()
    {
        var current = settings.Load();
        return new SubtitleProviderStatus(current.Enabled, current.ApiKey is not null, current.AccountName is not null, current.AccountName,
            current.Languages, current.Automatic, ProviderName, Attribution, quota.Remaining, quota.ResetsAt, quota.LastAutomaticRunAt, store.Count());
    }

    public SubtitleProviderStatus Configure(UpdateSubtitleProviderRequest request)
    {
        settings.Save(request);
        return Status();
    }

    public SubtitleProviderStatus RemoveKey()
    {
        settings.RemoveKey();
        return Status();
    }

    public SubtitleProviderStatus RemoveAccount()
    {
        settings.RemoveAccount();
        return Status();
    }

    public async Task<IReadOnlyList<DownloadedSubtitle>> ListAsync(Guid mediaId, CancellationToken token)
    {
        await RequireTitleAsync(mediaId, token);
        return store.List(mediaId).Select(subtitle => subtitle.Describe()).ToList();
    }

    public async Task<IReadOnlyList<SubtitleCandidate>> SearchAsync(Guid mediaId, string? language, CancellationToken token)
    {
        var configuration = RequireEnabled();
        var title = await RequireTitleAsync(mediaId, token);
        var languages = language is { Length: > 0 }
            ? SubtitleProviderSettingsStore.NormalizeLanguages([language])
            : configuration.Languages;
        var search = await SearchForAsync(title, languages, token);
        return await provider.SearchAsync(configuration.ApiKey!, search, token);
    }

    public async Task<DownloadedSubtitle> DownloadAsync(Guid mediaId, DownloadSubtitleRequest request, CancellationToken token)
    {
        var configuration = RequireEnabled();
        await RequireTitleAsync(mediaId, token);
        var language = SubtitleProviderSettingsStore.NormalizeLanguages([request.Language])[0];
        var stored = await FetchAsync(configuration, mediaId, request.FileId, language, request.Release, request.HearingImpaired, request.ForeignPartsOnly, automatic: false, token);
        return stored.Describe();
    }

    /// <summary>
    /// Keeps subtitles that a device wrote from the title's speech, as SubRip text. They replace
    /// earlier ones in the same language and need no OpenSubtitles setup.
    /// </summary>
    public Task<DownloadedSubtitle> AddFromSpeechAsync(Guid mediaId, string language, string text, CancellationToken token) =>
        AddWrittenAsync(mediaId, language, text, SpeechProviderName, token);

    /// <summary>
    /// Keeps subtitles written by a device: from speech, or a copy synced to the speech. They
    /// replace earlier ones of the same kind in the same language; the original stays as it is.
    /// </summary>
    public async Task<DownloadedSubtitle> AddWrittenAsync(Guid mediaId, string language, string text, string provider, CancellationToken token)
    {
        if (provider is not (SpeechProviderName or SyncedProviderName))
            throw new ArgumentOutOfRangeException(nameof(provider));
        await RequireTitleAsync(mediaId, token);
        if (!SidecarSubtitles.TryParseLanguage(language.Trim(), out var code))
            throw new MetadataException("invalid_subtitle_language", "Choose the language the subtitles are in.", StatusCodes.Status400BadRequest);
        var clean = text.Replace("\r\n", "\n", StringComparison.Ordinal).Trim();
        if (clean.Length == 0 || !clean.Contains("-->", StringComparison.Ordinal) || clean.Contains('\0', StringComparison.Ordinal))
            throw new MetadataException("subtitle_unreadable", "The subtitles are not SubRip text.", StatusCodes.Status422UnprocessableEntity);
        var subtitle = new StoredSubtitle(Guid.NewGuid(), code, HearingImpaired: false, Forced: false, provider,
            ProviderFileId: code, Release: null, clock.GetUtcNow(), Automatic: false);
        return store.Replace(mediaId, subtitle, System.Text.Encoding.UTF8.GetBytes(clean + "\n")).Describe();
    }

    public async Task RemoveAsync(Guid mediaId, Guid subtitleId, CancellationToken token)
    {
        await RequireTitleAsync(mediaId, token);
        if (!store.Remove(mediaId, subtitleId))
            throw new MetadataException("subtitle_not_found", "The subtitle was not found.", StatusCodes.Status404NotFound);
    }

    /// <summary>
    /// One pass of the automatic download: movies and episodes that are online and matched, without
    /// a subtitle in a chosen language (in the file, beside it or downloaded), each language looked
    /// for at most once a week per file. Stops at <paramref name="limit"/> downloads or when today's
    /// downloads are used up. Returns how many subtitles were downloaded.
    /// </summary>
    public async Task<int> AutomaticRunAsync(int limit, CancellationToken token)
    {
        var configuration = settings.Load();
        if (!configuration.Enabled || !configuration.Automatic || configuration.ApiKey is null || quota.Exhausted) return 0;
        quota.LastAutomaticRunAt = clock.GetUtcNow();
        var titles = await database.MediaItems.AsNoTracking()
            .Where(item => (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Episode) && item.Availability == MediaAvailability.Available)
            .OrderByDescending(item => item.CreatedAt)
            .Select(item => new { item.Id, item.FileSize, item.FileModifiedAt })
            .ToListAsync(token);
        store.Prune(await database.MediaItems.AsNoTracking().Select(item => item.Id).ToHashSetAsync(token));
        var downloaded = 0;
        var searches = 0;
        foreach (var candidate in titles)
        {
            // Searches are bounded too, so a large library without matches is spread over many passes.
            if (downloaded >= limit || searches >= limit * SearchesPerDownload || quota.Exhausted) break;
            var fileKey = string.Create(CultureInfo.InvariantCulture, $"{candidate.FileSize}:{candidate.FileModifiedAt?.UtcTicks}");
            var now = clock.GetUtcNow();
            var due = configuration.Languages.Where(language => store.LastChecked(candidate.Id, fileKey, language) is not { } at || now - at >= RecheckAfter).ToList();
            if (due.Count == 0) continue;
            var title = await TitleAsync(candidate.Id, token);
            if (title is null || !Matched(title)) continue;
            var present = await LanguagesPresentAsync(title, token);
            var missing = due.Where(language => !present.Contains(language)).ToList();
            foreach (var language in due.Except(missing)) store.MarkChecked(candidate.Id, fileKey, language, now);
            if (missing.Count == 0) continue;
            IReadOnlyList<SubtitleCandidate> found;
            searches++;
            try
            {
                found = await provider.SearchAsync(configuration.ApiKey, await SearchForAsync(title, missing, token), token);
            }
            catch (MetadataProviderException exception)
            {
                Postponed(logger, exception.Message);
                break;
            }
            foreach (var language in missing)
            {
                var best = found.FirstOrDefault(subtitle => subtitle.Language == language && !subtitle.MachineTranslated && !subtitle.ForeignPartsOnly);
                if (best is not null)
                {
                    try
                    {
                        await FetchAsync(configuration, candidate.Id, best.FileId, language, best.Release, best.HearingImpaired, false, automatic: true, token);
                        downloaded++;
                    }
                    catch (SubtitleQuotaException)
                    {
                        Postponed(logger, "today's downloads are used up");
                        return downloaded;
                    }
                    catch (MetadataException exception)
                    {
                        Postponed(logger, exception.Message);
                        return downloaded;
                    }
                }
                store.MarkChecked(candidate.Id, fileKey, language, now);
                if (downloaded >= limit) break;
            }
        }
        if (downloaded > 0) Downloaded(logger, downloaded);
        return downloaded;
    }

    /// <summary>The downloaded subtitles a stream offers, as sidecar tracks from index 2000.</summary>
    public static IEnumerable<LiveSubtitleTrack> Tracks(DownloadedSubtitleStore store, Guid mediaId) =>
        store.List(mediaId).Select((subtitle, index) => new LiveSubtitleTrack(
            DownloadedTrackBase + index, "subrip", subtitle.Language, DownloadedSubtitleStore.TrackTitle(subtitle),
            IsDefault: false, subtitle.Forced, Supported: true, IsSidecar: true, IsSdh: subtitle.HearingImpaired));

    public const int DownloadedTrackBase = 2000;

    /// <summary>An automatic pass searches at most this many titles per allowed download.</summary>
    public const int SearchesPerDownload = 4;

    private async Task<StoredSubtitle> FetchAsync(SubtitleProviderConfiguration configuration, Guid mediaId, string fileId, string language,
        string? release, bool hearingImpaired, bool forced, bool automatic, CancellationToken token)
    {
        if (store.List(mediaId).FirstOrDefault(entry => entry.Provider == ProviderName && entry.ProviderFileId == fileId) is { } existing)
            return existing;
        SubtitleFile file;
        try
        {
            file = await provider.DownloadAsync(configuration.ApiKey!, configuration.AccountName, configuration.AccountPassword, fileId, token);
        }
        catch (SubtitleQuotaException exception)
        {
            quota.Update(0, exception.ResetsAt);
            throw;
        }
        quota.Update(file.Remaining, file.ResetsAt);
        var text = SidecarSubtitles.DecodeText(file.Content);
        if (!text.Contains("-->", StringComparison.Ordinal))
            throw new MetadataException("subtitle_unreadable", "The downloaded file is not a subtitle.", StatusCodes.Status422UnprocessableEntity);
        var cleanRelease = release is null ? null : new string(release.Where(character => !char.IsControl(character)).Take(200).ToArray());
        return store.Add(mediaId, new StoredSubtitle(Guid.NewGuid(), language, hearingImpaired, forced, ProviderName, fileId, cleanRelease, clock.GetUtcNow(), automatic),
            System.Text.Encoding.UTF8.GetBytes(text));
    }

    private SubtitleProviderConfiguration RequireEnabled()
    {
        var configuration = settings.Load();
        if (!configuration.Enabled || configuration.ApiKey is null)
            throw new MetadataException("subtitles_disabled", "Turn on subtitle downloads in the server's metadata settings first.", StatusCodes.Status409Conflict);
        return configuration;
    }

    private sealed record Title(MediaItem Item, MediaMetadata? Metadata, MediaMetadata? SeriesMetadata, string Name);

    private async Task<Title> RequireTitleAsync(Guid mediaId, CancellationToken token) =>
        await TitleAsync(mediaId, token) ?? throw new MetadataException("media_not_found", "Subtitles can be downloaded for movies and episodes only.", StatusCodes.Status404NotFound);

    private async Task<Title?> TitleAsync(Guid mediaId, CancellationToken token)
    {
        var item = await database.MediaItems.AsNoTracking().Include(media => media.LibraryRoot).Include(media => media.Metadata)
            .FirstOrDefaultAsync(media => media.Id == mediaId && (media.Kind == MediaKind.Movie || media.Kind == MediaKind.Episode), token);
        if (item is null) return null;
        MediaMetadata? series = null;
        string? seriesName = null;
        if (item.Kind == MediaKind.Episode && item.ParentId is { } parent)
        {
            var show = await database.MediaItems.AsNoTracking().Include(media => media.Metadata).FirstOrDefaultAsync(media => media.Id == parent, token);
            series = show?.Metadata;
            seriesName = show?.Metadata?.ProviderTitle ?? show?.OverrideTitle ?? show?.DetectedTitle;
        }
        var name = item.Kind == MediaKind.Episode
            ? seriesName ?? item.DetectedTitle
            : item.Metadata?.ProviderTitle ?? item.OverrideTitle ?? item.DetectedTitle;
        return new Title(item, item.Metadata, series, name);
    }

    private static bool Matched(Title title) =>
        (title.Item.Kind == MediaKind.Movie ? title.Metadata?.ProviderMediaId : title.SeriesMetadata?.ProviderMediaId) is not null
        && (title.Item.Kind == MediaKind.Movie || title.Item is { SeasonNumber: not null, EpisodeNumber: not null });

    private static async Task<SubtitleSearch> SearchForAsync(Title title, IReadOnlyList<string> languages, CancellationToken token)
    {
        var tmdb = title.Item.Kind == MediaKind.Movie
            ? TmdbId(title.Metadata)
            : TmdbId(title.SeriesMetadata);
        return new SubtitleSearch(title.Item.Kind, title.Name, title.Item.Year, tmdb, title.Item.SeasonNumber, title.Item.EpisodeNumber,
            await HashAsync(title.Item, token), languages);
    }

    private static string? TmdbId(MediaMetadata? metadata) =>
        metadata?.Provider is null or "tmdb" ? metadata?.ProviderMediaId : null;

    private static Task<string?> HashAsync(MediaItem item, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        try
        {
            var file = MediaFileAccess.OpenRead(item);
            using var stream = file.Stream;
            return Task.FromResult(OpenSubtitlesHash.Compute(stream));
        }
        catch (Exception exception) when (exception is PlaybackException or IOException or UnauthorizedAccessException)
        {
            return Task.FromResult<string?>(null);
        }
    }

    /// <summary>Languages the title already has: in the file (not forced-only), beside it, or downloaded.</summary>
    private async Task<HashSet<string>> LanguagesPresentAsync(Title title, CancellationToken token)
    {
        var present = new HashSet<string>(StringComparer.Ordinal);
        foreach (var subtitle in store.List(title.Item.Id).Where(subtitle => !subtitle.Forced)) present.Add(subtitle.Language);
        foreach (var sidecar in SidecarSubtitles.Discover(title.Item.SourcePath).Where(sidecar => !sidecar.IsForced))
            if (sidecar.Language is { } language) present.Add(language);
        if (await live.ToolsAsync() is { } tools)
        {
            try
            {
                var file = MediaFileAccess.OpenRead(title.Item);
                await using var stream = file.Stream;
                var probe = await live.ProbeAsync(tools, file, title.Item.SourcePath, title.Item.Id, token);
                foreach (var track in probe.Subtitles ?? [])
                    if (!track.IsForced && track.Language is { } code && SidecarSubtitles.TryParseLanguage(code, out var language)) present.Add(language);
            }
            catch (Exception exception) when (exception is PlaybackException or IOException or UnauthorizedAccessException)
            {
                // An unreadable file only means its own subtitles are unknown.
            }
        }
        return present;
    }

    [LoggerMessage(LogLevel.Information, "Automatic subtitle download paused: {Reason}.")]
    private static partial void Postponed(ILogger logger, string reason);

    [LoggerMessage(LogLevel.Information, "Downloaded {Count} subtitles automatically.")]
    private static partial void Downloaded(ILogger logger, int count);
}

/// <summary>Runs the automatic subtitle download a few minutes after start and then every six hours.</summary>
public sealed class SubtitleAutoDownloader(IServiceScopeFactory scopes) : BackgroundService
{
    private static readonly TimeSpan StartDelay = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan Interval = TimeSpan.FromHours(6);
    public const int DownloadsPerRun = 25;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            await Task.Delay(StartDelay, stoppingToken);
            while (!stoppingToken.IsCancellationRequested)
            {
                await using (var scope = scopes.CreateAsyncScope())
                {
                    try
                    {
                        await scope.ServiceProvider.GetRequiredService<SubtitleDownloadService>().AutomaticRunAsync(DownloadsPerRun, stoppingToken);
                    }
                    catch (Exception exception) when (exception is MetadataException or IOException or DbUpdateException)
                    {
                        // A failed pass is tried again at the next interval.
                    }
                }
                await Task.Delay(Interval, stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }
}
