using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Prepares the artwork widths the Apple TV requests in the background, one image at
/// a time, so browsing shows cached variants instead of waiting for resizes. It stays
/// within half of the variant cache limit, so warming never evicts files in use.
/// </summary>
public sealed partial class ArtworkVariantWarmer(IServiceScopeFactory scopes, ArtworkStore artwork,
    ArtworkVariantStore variants, ILogger<ArtworkVariantWarmer> logger) : BackgroundService
{
    internal static readonly TimeSpan StartDelay = TimeSpan.FromSeconds(30);
    internal static readonly TimeSpan Interval = TimeSpan.FromMinutes(30);
    internal const long WarmBudgetBytes = ArtworkVariantStore.MaximumCacheBytes / 2;

    internal static int[] Widths(ArtworkKind kind) => kind switch
    {
        ArtworkKind.Poster => [640],
        ArtworkKind.Backdrop => [1280, 1920],
        ArtworkKind.Still => [1280],
        ArtworkKind.Profile => [320],
        _ => [],
    };

    private static int Priority(ArtworkKind kind) => kind switch
    {
        ArtworkKind.Poster => 0,
        ArtworkKind.Backdrop => 1,
        ArtworkKind.Still => 2,
        _ => 3,
    };

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var failureReported = false;
        try
        {
            await Task.Delay(StartDelay, stoppingToken);
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    await WarmAsync(TimeSpan.FromMilliseconds(25), stoppingToken);
                    failureReported = false;
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { return; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException
                    or DbUpdateException or Microsoft.Data.Sqlite.SqliteException or InvalidOperationException)
                {
                    // Warming is optional; requests still generate variants on demand.
                    if (!failureReported) WarmingUnavailable(logger);
                    failureReported = true;
                }
                await Task.Delay(Interval, stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    /// <returns>The number of variants generated in this pass.</returns>
    internal async Task<int> WarmAsync(TimeSpan pause, CancellationToken token)
    {
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var assets = (await database.ArtworkAssets.AsNoTracking()
                .Select(asset => new { asset.Id, asset.Kind, asset.Revision }).ToListAsync(token))
            .OrderBy(asset => Priority(asset.Kind)).ThenBy(asset => asset.Id).ToList();
        var used = variants.MeasureUsedBytes();
        var prepared = 0;
        foreach (var asset in assets)
        {
            foreach (var width in Widths(asset.Kind))
            {
                token.ThrowIfCancellationRequested();
                if (used >= WarmBudgetBytes) return prepared;
                if (variants.IsCached(asset.Id, asset.Revision, width)) continue;
                var source = await artwork.OpenAsync(asset.Id, database, token);
                if (source is null) continue;
                await using (source.Stream)
                {
                    var variant = await variants.OpenAsync(asset.Id, source.Revision, width, source, database, token);
                    if (variant is null) continue;
                    used += variant.ContentLength;
                    prepared++;
                    await variant.Stream.DisposeAsync();
                }
                // Leave the processor to playback and requests between images.
                if (pause > TimeSpan.Zero) await Task.Delay(pause, token);
            }
        }
        return prepared;
    }

    [LoggerMessage(LogLevel.Warning, "Artwork preparation could not finish and will be retried. Artwork is still generated on request.")]
    private static partial void WarmingUnavailable(ILogger logger);
}
