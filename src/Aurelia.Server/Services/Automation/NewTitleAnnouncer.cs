using System.Collections.Concurrent;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services.Automation;

/// <summary>
/// Announces new movies and shows to webhooks once, with their real names: right after TMDB found
/// them, or with the name from the file after ten minutes without a match. A scan that adds more
/// than twenty at once (a new drive) sends one "library.title_added" with only the count. Pending
/// titles live in memory; a restart in those ten minutes skips them.
/// </summary>
public sealed class NewTitleAnnouncer(
    AutomationEventBus bus,
    IServiceScopeFactory scopes,
    TimeProvider clock) : BackgroundService
{
    public const int MaximumSingle = 20;
    public static readonly TimeSpan WaitForInformation = TimeSpan.FromMinutes(10);
    private readonly ConcurrentDictionary<Guid, (DateTimeOffset Added, bool Matched)> pending = new();

    public void Added(IReadOnlyCollection<Guid> ids)
    {
        if (ids.Count > MaximumSingle)
        {
            bus.Publish(new AutomationEvent(AutomationEvents.TitleAdded, Guid.NewGuid(), clock.GetUtcNow(), Count: ids.Count));
            return;
        }
        var now = clock.GetUtcNow();
        foreach (var id in ids) pending.TryAdd(id, (now, false));
    }

    public void Matched(Guid id)
    {
        if (pending.TryGetValue(id, out var value)) pending.TryUpdate(id, value with { Matched = true }, value);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(3), clock, stoppingToken);
                await AnnounceDueAsync(stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    public async Task AnnounceDueAsync(CancellationToken cancellationToken)
    {
        var now = clock.GetUtcNow();
        var due = pending.Where(entry => entry.Value.Matched || now - entry.Value.Added >= WaitForInformation)
            .Select(entry => entry.Key).ToList();
        if (due.Count == 0) return;
        using var scope = scopes.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        foreach (var id in due)
        {
            if (!pending.TryRemove(id, out _)) continue;
            var media = await database.MediaItems.AsNoTracking().SingleOrDefaultAsync(value => value.Id == id, cancellationToken);
            if (media is null || media.Kind is not (MediaKind.Movie or MediaKind.Series)) continue;
            bus.Publish(new AutomationEvent(AutomationEvents.TitleAdded, Guid.NewGuid(), now,
                Media: await PlaybackActivityTracker.MediaAsync(database, media, cancellationToken), Count: 1));
        }
    }
}

/// <summary>Sends "server.started" once the server answers and "server.stopping" as it ends.</summary>
public sealed class ServerLifecycleEvents(AutomationEventBus bus, IHostApplicationLifetime lifetime, TimeProvider clock) : IHostedService
{
    public Task StartAsync(CancellationToken cancellationToken)
    {
        lifetime.ApplicationStarted.Register(() => bus.Publish(new AutomationEvent(AutomationEvents.ServerStarted, Guid.NewGuid(), clock.GetUtcNow())));
        lifetime.ApplicationStopping.Register(() => bus.Publish(new AutomationEvent(AutomationEvents.ServerStopping, Guid.NewGuid(), clock.GetUtcNow())));
        return Task.CompletedTask;
    }

    // Gives the dispatcher a moment to send "stopping" before the server is gone.
    public Task StopAsync(CancellationToken cancellationToken) => Task.Delay(TimeSpan.FromMilliseconds(800), cancellationToken)
        .ContinueWith(_ => { }, TaskScheduler.Default);
}
