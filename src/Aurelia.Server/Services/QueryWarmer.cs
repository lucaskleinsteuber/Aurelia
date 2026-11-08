using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Runs Home and the first library page once, read-only, shortly after the server starts. EF Core
/// translates each query the first time it runs in a process (about 200 ms for Home on a Mac), so
/// without this the first app to open Home after every start paid for it.
/// </summary>
public sealed partial class QueryWarmer(IServiceScopeFactory scopes, ILogger<QueryWarmer> logger) : BackgroundService
{
    internal static readonly TimeSpan StartDelay = TimeSpan.FromSeconds(2);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            await Task.Delay(StartDelay, stoppingToken);
            await WarmAsync(stoppingToken);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DbUpdateException or Microsoft.Data.Sqlite.SqliteException or InvalidOperationException or MetadataException)
        {
            // Optional: the first request then translates its queries itself.
            WarmingSkipped(logger);
        }
    }

    internal async Task<bool> WarmAsync(CancellationToken token)
    {
        using var scope = scopes.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var userId = await database.Users.AsNoTracking().OrderBy(user => user.CreatedAt).Select(user => (Guid?)user.Id).FirstOrDefaultAsync(token);
        if (userId is not { } user) return false;
        var presentation = scope.ServiceProvider.GetRequiredService<PresentationService>();
        await presentation.HomeAsync(user, token);
        await presentation.CatalogAsync(user, MediaKind.Movie, 0, 60, token);
        return true;
    }

    [LoggerMessage(Level = LogLevel.Debug, Message = "Query warm-up skipped; the first request prepares its queries.")]
    private static partial void WarmingSkipped(ILogger logger);
}
