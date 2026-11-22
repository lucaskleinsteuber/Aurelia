using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Once per server: titles matched before the apps showed German FSK ratings get their rating
/// again from their known TMDB match. Only the age rating changes; matches, titles, artwork and
/// manual edits stay as they are. A failure (no network, TMDB busy) leaves the rest for the next
/// start; a <c>content-ratings-v1</c> file in the data folder marks it done.
/// </summary>
public sealed partial class ContentRatingRefresh(
    IServiceScopeFactory scopes,
    ServerRuntimeOptions runtime,
    ILogger<ContentRatingRefresh> logger) : BackgroundService
{
    public const string MarkerName = "content-ratings-v1";
    private const string ProgressName = "content-ratings-v1.progress";
    private static readonly TimeSpan StartDelay = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan Pause = TimeSpan.FromMilliseconds(300);
    private static readonly TimeSpan MaximumRateLimitWait = TimeSpan.FromSeconds(60);

    private string MarkerPath => Path.Combine(runtime.DataDirectory, MarkerName);
    private string ProgressPath => Path.Combine(runtime.DataDirectory, ProgressName);

    private static readonly Action<ILogger, Exception?> UnexpectedFailure = LoggerMessage.Define(
        LogLevel.Warning, new EventId(4412, nameof(UnexpectedFailure)), "Age rating refresh stopped after an unexpected failure.");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            if (File.Exists(MarkerPath)) return;
            await Task.Delay(StartDelay, stoppingToken);
            await RunAsync(Pause, stoppingToken);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            UnexpectedFailure(logger, exception);
        }
    }

    /// <summary>Refreshes the ratings. True when every title was handled and the marker was written.</summary>
    public async Task<bool> RunAsync(TimeSpan pause, CancellationToken token)
    {
        if (File.Exists(MarkerPath)) return true;
        using var work = ServerWorkSignal.Begin(scopes, keepAwake: false);
        await using var scope = scopes.CreateAsyncScope();
        var settings = scope.ServiceProvider.GetRequiredService<MetadataProviderSettingsStore>().Load();
        if (!settings.Enabled || settings.Token is null) return false;
        var tmdb = scope.ServiceProvider.GetRequiredService<ITmdbClient>();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var matched = await database.MediaMetadata
            .Where(metadata => metadata.ProviderMediaId != null
                && (metadata.MediaItem.Kind == MediaKind.Movie || metadata.MediaItem.Kind == MediaKind.Series))
            .OrderBy(metadata => metadata.MediaItemId)
            .Select(metadata => new { metadata.MediaItemId, metadata.Provider, metadata.ProviderMediaId, metadata.ProviderMediaType, metadata.MediaItem.Kind })
            .ToListAsync(token);
        var completed = LoadProgress(ProgressPath);
        var changed = 0;
        foreach (var title in matched)
        {
            if (completed.Contains(title.MediaItemId)) continue;
            if (title.Provider is { } provider && !provider.Equals("tmdb", StringComparison.OrdinalIgnoreCase))
            {
                await RecordProgressAsync(ProgressPath, runtime.DataDirectory, title.MediaItemId, token);
                completed.Add(title.MediaItemId);
                continue;
            }
            var mediaType = title.ProviderMediaType ?? (title.Kind == MediaKind.Movie ? "movie" : "tv");
            var retriedRateLimit = false;
            while (true)
            {
                try
                {
                    var rating = (await tmdb.GetAsync(settings.Token, settings.Language, mediaType, title.ProviderMediaId!, token)).ContentRating;
                    changed += await database.MediaMetadata
                        .Where(metadata => metadata.MediaItemId == title.MediaItemId && metadata.ProviderMediaId == title.ProviderMediaId
                            && metadata.ProviderContentRating != rating)
                        .ExecuteUpdateAsync(update => update.SetProperty(metadata => metadata.ProviderContentRating, rating), token);
                    break;
                }
                catch (MetadataProviderException exception) when (exception.RetryAfter is { } retryAfter && !retriedRateLimit && !token.IsCancellationRequested)
                {
                    retriedRateLimit = true;
                    var delay = retryAfter < TimeSpan.FromSeconds(1)
                        ? TimeSpan.FromSeconds(1)
                        : retryAfter > MaximumRateLimitWait ? MaximumRateLimitWait : retryAfter;
                    await Task.Delay(delay, token);
                }
                catch (MetadataException exception) when (exception.StatusCode is StatusCodes.Status404NotFound or StatusCodes.Status400BadRequest)
                {
                    break;
                }
                catch (Exception exception) when (exception is MetadataException or HttpRequestException or TaskCanceledException && !token.IsCancellationRequested)
                {
                    Postponed(logger, exception.GetType().Name);
                    return false;
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    UnexpectedFailure(logger, exception);
                    return false;
                }
            }
            await RecordProgressAsync(ProgressPath, runtime.DataDirectory, title.MediaItemId, token);
            completed.Add(title.MediaItemId);
            if (pause > TimeSpan.Zero) await Task.Delay(pause, token);
        }

        PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
        await File.WriteAllTextAsync(MarkerPath, changed.ToString(System.Globalization.CultureInfo.InvariantCulture), token);
        DeleteProgress(ProgressPath);
        Finished(logger, matched.Count, changed);
        return true;
    }

    internal static HashSet<Guid> LoadProgress(string path)
    {
        var completed = new HashSet<Guid>();
        try
        {
            if (!File.Exists(path)) return completed;
            foreach (var line in File.ReadLines(path))
            {
                if (Guid.TryParse(line.Trim(), out var id)) completed.Add(id);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        return completed;
    }

    internal static async Task RecordProgressAsync(string path, string dataDirectory, Guid mediaItemId, CancellationToken token)
    {
        try
        {
            PrivateFilePermissions.CreatePrivateDirectory(dataDirectory);
            await File.AppendAllTextAsync(path, mediaItemId.ToString("N") + "\n", token);
            PrivateFilePermissions.ProtectFile(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    internal static void DeleteProgress(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    [LoggerMessage(LogLevel.Warning, "Age ratings could not be refreshed yet ({ErrorType}); trying again at the next start.")]
    private static partial void Postponed(ILogger logger, string errorType);

    [LoggerMessage(LogLevel.Information, "Age ratings refreshed for {Titles} matched titles; {Changed} changed.")]
    private static partial void Finished(ILogger logger, int titles, int changed);
}
