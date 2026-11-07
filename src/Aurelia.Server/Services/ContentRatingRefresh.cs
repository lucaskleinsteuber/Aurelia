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
    private static readonly TimeSpan StartDelay = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan Pause = TimeSpan.FromMilliseconds(300);

    private string MarkerPath => Path.Combine(runtime.DataDirectory, MarkerName);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            if (File.Exists(MarkerPath)) return;
            await Task.Delay(StartDelay, stoppingToken);
            await RunAsync(Pause, stoppingToken);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    /// <summary>Refreshes the ratings. True when every title was handled and the marker was written.</summary>
    public async Task<bool> RunAsync(TimeSpan pause, CancellationToken token)
    {
        if (File.Exists(MarkerPath)) return true;
        await using var scope = scopes.CreateAsyncScope();
        var settings = scope.ServiceProvider.GetRequiredService<MetadataProviderSettingsStore>().Load();
        if (!settings.Enabled || settings.Token is null) return false;
        var tmdb = scope.ServiceProvider.GetRequiredService<ITmdbClient>();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var matched = await database.MediaMetadata
            .Where(metadata => metadata.ProviderMediaId != null
                && (metadata.MediaItem.Kind == MediaKind.Movie || metadata.MediaItem.Kind == MediaKind.Series))
            .Select(metadata => new { metadata.MediaItemId, metadata.Provider, metadata.ProviderMediaId, metadata.ProviderMediaType, metadata.MediaItem.Kind })
            .ToListAsync(token);
        var changed = 0;
        foreach (var title in matched)
        {
            if (title.Provider is { } provider && !provider.Equals("tmdb", StringComparison.OrdinalIgnoreCase)) continue;
            var mediaType = title.ProviderMediaType ?? (title.Kind == MediaKind.Movie ? "movie" : "tv");
            string? rating;
            try
            {
                rating = (await tmdb.GetAsync(settings.Token, settings.Language, mediaType, title.ProviderMediaId!, token)).ContentRating;
            }
            catch (MetadataException exception) when (exception.StatusCode is StatusCodes.Status404NotFound or StatusCodes.Status400BadRequest)
            {
                continue;
            }
            catch (Exception exception) when (exception is MetadataException or HttpRequestException or TaskCanceledException && !token.IsCancellationRequested)
            {
                Postponed(logger, exception.GetType().Name);
                return false;
            }
            changed += await database.MediaMetadata
                .Where(metadata => metadata.MediaItemId == title.MediaItemId && metadata.ProviderMediaId == title.ProviderMediaId
                    && metadata.ProviderContentRating != rating)
                .ExecuteUpdateAsync(update => update.SetProperty(metadata => metadata.ProviderContentRating, rating), token);
            if (pause > TimeSpan.Zero) await Task.Delay(pause, token);
        }

        PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
        await File.WriteAllTextAsync(MarkerPath, changed.ToString(System.Globalization.CultureInfo.InvariantCulture), token);
        Finished(logger, matched.Count, changed);
        return true;
    }

    [LoggerMessage(LogLevel.Warning, "Age ratings could not be refreshed yet ({ErrorType}); trying again at the next start.")]
    private static partial void Postponed(ILogger logger, string errorType);

    [LoggerMessage(LogLevel.Information, "Age ratings refreshed for {Titles} matched titles; {Changed} changed.")]
    private static partial void Finished(ILogger logger, int titles, int changed);
}
