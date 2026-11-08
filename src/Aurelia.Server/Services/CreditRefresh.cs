using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Once per server: titles matched while Aurelia kept only 40 actors and a few crew jobs get their
/// whole cast and crew from their known TMDB match (a series from all its seasons) and join their
/// shared universes (<see cref="MediaUniverses"/>). Matches, texts,
/// artwork and hand-edited credits stay. A failure (no network, TMDB busy) leaves the rest for the
/// next start; a <c>credits-v2</c> file in the data folder marks it done.
/// </summary>
public sealed partial class CreditRefresh(
    IServiceScopeFactory scopes,
    ServerRuntimeOptions runtime,
    ILogger<CreditRefresh> logger) : BackgroundService
{
    public const string MarkerName = "credits-v2";
    private static readonly TimeSpan StartDelay = TimeSpan.FromMinutes(2);
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

    /// <summary>Refreshes the credits. True when every title was handled and the marker was written.</summary>
    public async Task<bool> RunAsync(TimeSpan pause, CancellationToken token)
    {
        if (File.Exists(MarkerPath)) return true;
        List<(Guid Id, string? Provider, string ProviderId, string MediaType)> matched;
        MetadataProviderConfiguration settings;
        await using (var scope = scopes.CreateAsyncScope())
        {
            settings = scope.ServiceProvider.GetRequiredService<MetadataProviderSettingsStore>().Load();
            if (!settings.Enabled || settings.Token is null) return false;
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            matched = (await database.MediaMetadata
                .Where(metadata => metadata.ProviderMediaId != null
                    && (metadata.MediaItem.Kind == MediaKind.Movie || metadata.MediaItem.Kind == MediaKind.Series))
                .Select(metadata => new { metadata.MediaItemId, metadata.Provider, metadata.ProviderMediaId, metadata.ProviderMediaType, metadata.MediaItem.Kind })
                .ToListAsync(token))
                .Select(title => (title.MediaItemId, title.Provider, title.ProviderMediaId!, title.ProviderMediaType ?? (title.Kind == MediaKind.Movie ? "movie" : "tv")))
                .ToList();
        }

        var changed = 0;
        foreach (var title in matched)
        {
            if (title.Provider is { } provider && !provider.Equals("tmdb", StringComparison.OrdinalIgnoreCase)) continue;
            // A fresh scope per title keeps the change tracker small over a large library.
            await using var scope = scopes.CreateAsyncScope();
            try
            {
                var details = await scope.ServiceProvider.GetRequiredService<ITmdbClient>()
                    .GetAsync(settings.Token, settings.Language, title.MediaType, title.ProviderId, token);
                if (await scope.ServiceProvider.GetRequiredService<MetadataService>().RefreshCreditsAsync(title.Id, details, token)) changed++;
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
            if (pause > TimeSpan.Zero) await Task.Delay(pause, token);
        }

        PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
        await File.WriteAllTextAsync(MarkerPath, changed.ToString(System.Globalization.CultureInfo.InvariantCulture), token);
        Finished(logger, matched.Count, changed);
        return true;
    }

    [LoggerMessage(LogLevel.Warning, "Cast and crew could not be refreshed yet ({ErrorType}); trying again at the next start.")]
    private static partial void Postponed(ILogger logger, string errorType);

    [LoggerMessage(LogLevel.Information, "Cast and crew refreshed for {Changed} of {Titles} matched titles.")]
    private static partial void Finished(ILogger logger, int titles, int changed);
}
