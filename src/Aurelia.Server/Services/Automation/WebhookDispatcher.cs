using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Channels;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services.Automation;

/// <summary>How long a webhook waits and how often it tries again; tests make these short.</summary>
public sealed class AutomationOptions
{
    /// <summary>Playback events go stale fast: a light dimmed a minute late is wrong, so they are tried for seconds only.</summary>
    public IReadOnlyList<TimeSpan> PlaybackRetries { get; init; } = [TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(10)];

    /// <summary>A new title or a server start still matters later; these are kept and tried for an hour.</summary>
    public IReadOnlyList<TimeSpan> DurableRetries { get; init; } =
        [TimeSpan.FromSeconds(30), TimeSpan.FromMinutes(2), TimeSpan.FromMinutes(10), TimeSpan.FromHours(1)];

    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(5);
    public TimeSpan DurablePoll { get; init; } = TimeSpan.FromSeconds(5);
    public int PauseAfterFailures { get; init; } = 20;
}

/// <summary>
/// Delivers events to the owner's webhooks the moment they happen. Each webhook has its own queue,
/// so a slow receiver delays only its own events and every receiver gets them in order. The body
/// is signed (<see cref="WebhookSigner"/>); redirects are not followed; only the status counts.
/// Every outcome lands in the delivery log (without the body); after many failures in a row the
/// webhook pauses until the owner saves it again.
/// </summary>
public sealed partial class WebhookDispatcher(
    IServiceScopeFactory scopes,
    AutomationEventBus bus,
    AutomationWebhookCache cache,
    IHttpClientFactory clients,
    ServerRuntimeOptions runtime,
    AutomationOptions options,
    TimeProvider clock,
    ILogger<WebhookDispatcher> logger) : BackgroundService
{
    public const string ClientName = "Aurelia.Webhooks";
    public const string PausedReason = "Paused after 20 failed deliveries in a row. Check the address and the receiver, then save the webhook to resume.";
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly ConcurrentDictionary<Guid, Channel<Work>> queues = new();
    private IReadOnlyList<WebhookTarget> targets = [];
    private int loadedVersion = -1;
    private DateTimeOffset nextPrune = DateTimeOffset.MinValue;

    private sealed record Work(WebhookTarget Target, AutomationEvent Event, string Body);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var durable = DurableLoopAsync(stoppingToken);
        try
        {
            await foreach (var value in bus.Reader.ReadAllAsync(stoppingToken))
            {
                try
                {
                    foreach (var target in await TargetsAsync(stoppingToken))
                    {
                        if (!target.Wants(value)) continue;
                        Queue(target.Id, stoppingToken).Writer.TryWrite(new Work(target, value, Body(value, target)));
                    }
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    DispatchFailed(logger, exception);
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        await durable;
    }

    /// <summary>Sends a test event to one webhook now, once, and says how it went.</summary>
    public async Task<AutomationDeliverySummary> TestAsync(WebhookTarget target, CancellationToken cancellationToken)
    {
        var value = new AutomationEvent(AutomationEvents.Test, Guid.NewGuid(), clock.GetUtcNow());
        var outcome = await SendAsync(target, value.Kind, value.Id, Body(value, target), cancellationToken);
        return AutomationStore.Summary(await RecordAsync(target.Id, value.Kind, value.Id, 1, outcome, cancellationToken, countFailure: false));
    }

    private async Task<IReadOnlyList<WebhookTarget>> TargetsAsync(CancellationToken cancellationToken)
    {
        var version = cache.Version;
        if (version == loadedVersion) return targets;
        using var scope = scopes.CreateScope();
        targets = await scope.ServiceProvider.GetRequiredService<AutomationStore>().TargetsAsync(cancellationToken);
        loadedVersion = version;
        return targets;
    }

    private Channel<Work> Queue(Guid id, CancellationToken stoppingToken) => queues.GetOrAdd(id, key =>
    {
        var channel = Channel.CreateBounded<Work>(new BoundedChannelOptions(256) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });
        _ = Task.Run(() => DrainAsync(channel, stoppingToken), stoppingToken);
        return channel;
    });

    private async Task DrainAsync(Channel<Work> channel, CancellationToken stoppingToken)
    {
        try
        {
            await foreach (var work in channel.Reader.ReadAllAsync(stoppingToken))
            {
                try { await DeliverAsync(work, stoppingToken); }
                catch (Exception exception) when (exception is not OperationCanceledException) { DispatchFailed(logger, exception); }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    private async Task DeliverAsync(Work work, CancellationToken stoppingToken)
    {
        var playback = AutomationEvents.IsPlayback(work.Event.Kind);
        var attempt = 1;
        while (true)
        {
            var outcome = await SendAsync(work.Target, work.Event.Kind, work.Event.Id, work.Body, stoppingToken);
            if (outcome.Succeeded || !outcome.Retry)
            {
                await RecordAsync(work.Target.Id, work.Event.Kind, work.Event.Id, attempt, outcome, stoppingToken);
                return;
            }
            if (!playback)
            {
                // Kept in the database and tried again by the durable loop, even after a restart.
                await KeepAsync(work, attempt, outcome, stoppingToken);
                return;
            }
            if (attempt > options.PlaybackRetries.Count || outcome.RetryAfter > TimeSpan.FromSeconds(30))
            {
                await RecordAsync(work.Target.Id, work.Event.Kind, work.Event.Id, attempt, outcome, stoppingToken);
                return;
            }
            var wait = options.PlaybackRetries[attempt - 1];
            if (outcome.RetryAfter is { } after && after > wait) wait = after;
            await Task.Delay(wait, clock, stoppingToken);
            attempt++;
        }
    }

    private async Task DurableLoopAsync(CancellationToken stoppingToken)
    {
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                await Task.Delay(options.DurablePoll, clock, stoppingToken);
                try { await RetryDueAsync(stoppingToken); await PruneAsync(stoppingToken); }
                catch (Exception exception) when (exception is not OperationCanceledException) { DispatchFailed(logger, exception); }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    private async Task RetryDueAsync(CancellationToken cancellationToken)
    {
        using var scope = scopes.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = clock.GetUtcNow();
        var due = (await database.AutomationDeliveries.Where(value => value.State == AutomationDeliveryStates.Pending).ToListAsync(cancellationToken))
            .Where(value => value.NextAttemptAt <= now).OrderBy(value => value.CreatedAt).Take(50).ToList();
        if (due.Count == 0) return;
        var current = (await TargetsAsync(cancellationToken)).ToDictionary(value => value.Id);
        foreach (var delivery in due)
        {
            delivery.Attempt++;
            if (!current.TryGetValue(delivery.WebhookId, out var target) || delivery.Payload is null)
            {
                Finish(delivery, AutomationDeliveryStates.Dropped, null, null, "The webhook was paused or removed.", now);
                continue;
            }
            var outcome = await SendAsync(target, delivery.Event, delivery.EventId, delivery.Payload, cancellationToken);
            if (outcome.Succeeded || !outcome.Retry || delivery.Attempt > options.DurableRetries.Count)
            {
                Finish(delivery, outcome.Succeeded ? AutomationDeliveryStates.Succeeded : AutomationDeliveryStates.Failed,
                    outcome.Status, outcome.Milliseconds, outcome.Error, clock.GetUtcNow());
                await CountAsync(database, delivery.WebhookId, outcome.Succeeded, cancellationToken);
            }
            else
            {
                delivery.StatusCode = outcome.Status;
                delivery.DurationMilliseconds = outcome.Milliseconds;
                delivery.Error = outcome.Error;
                var wait = options.DurableRetries[delivery.Attempt - 1];
                delivery.NextAttemptAt = clock.GetUtcNow() + (outcome.RetryAfter is { } after && after > wait ? after : wait);
            }
        }
        await database.SaveChangesAsync(cancellationToken);
    }

    private static void Finish(AutomationDelivery delivery, string state, int? status, int? milliseconds, string? error, DateTimeOffset now)
    {
        delivery.State = state;
        delivery.StatusCode = status ?? delivery.StatusCode;
        delivery.DurationMilliseconds = milliseconds ?? delivery.DurationMilliseconds;
        delivery.Error = error;
        delivery.Payload = null;
        delivery.NextAttemptAt = null;
        delivery.CompletedAt = now;
    }

    private async Task KeepAsync(Work work, int attempt, Outcome outcome, CancellationToken cancellationToken)
    {
        using var scope = scopes.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = clock.GetUtcNow();
        var wait = options.DurableRetries[0];
        database.AutomationDeliveries.Add(new AutomationDelivery
        {
            Id = Guid.NewGuid(),
            WebhookId = work.Target.Id,
            EventId = work.Event.Id,
            Event = work.Event.Kind,
            State = AutomationDeliveryStates.Pending,
            Attempt = attempt,
            Payload = work.Body,
            CreatedAt = now,
            NextAttemptAt = now + (outcome.RetryAfter is { } after && after > wait ? after : wait),
            StatusCode = outcome.Status,
            DurationMilliseconds = outcome.Milliseconds,
            Error = outcome.Error,
        });
        await database.SaveChangesAsync(cancellationToken);
    }

    private async Task<AutomationDelivery> RecordAsync(Guid webhookId, string kind, Guid eventId, int attempt, Outcome outcome,
        CancellationToken cancellationToken, bool countFailure = true)
    {
        using var scope = scopes.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = clock.GetUtcNow();
        var delivery = new AutomationDelivery
        {
            Id = Guid.NewGuid(),
            WebhookId = webhookId,
            EventId = eventId,
            Event = kind,
            State = outcome.Succeeded ? AutomationDeliveryStates.Succeeded : AutomationDeliveryStates.Failed,
            Attempt = attempt,
            CreatedAt = now,
            CompletedAt = now,
            StatusCode = outcome.Status,
            DurationMilliseconds = outcome.Milliseconds,
            Error = outcome.Error,
        };
        database.AutomationDeliveries.Add(delivery);
        if (countFailure || outcome.Succeeded) await CountAsync(database, webhookId, outcome.Succeeded, cancellationToken);
        await database.SaveChangesAsync(cancellationToken);
        return delivery;
    }

    private async Task CountAsync(AureliaDbContext database, Guid webhookId, bool succeeded, CancellationToken cancellationToken)
    {
        var hook = await database.AutomationWebhooks.SingleOrDefaultAsync(value => value.Id == webhookId, cancellationToken);
        if (hook is null) return;
        if (succeeded)
        {
            hook.ConsecutiveFailures = 0;
            return;
        }
        hook.ConsecutiveFailures++;
        if (hook.ConsecutiveFailures >= options.PauseAfterFailures && hook.PausedReason is null)
        {
            hook.PausedReason = PausedReason;
            cache.Changed();
        }
    }

    private async Task PruneAsync(CancellationToken cancellationToken)
    {
        var now = clock.GetUtcNow();
        if (now < nextPrune) return;
        nextPrune = now + TimeSpan.FromHours(1);
        using var scope = scopes.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var cutoff = now - TimeSpan.FromDays(7);
        var all = await database.AutomationDeliveries.Where(value => value.State != AutomationDeliveryStates.Pending)
            .Select(value => new { value.Id, value.WebhookId, value.CreatedAt }).ToListAsync(cancellationToken);
        var remove = all.Where(value => value.CreatedAt < cutoff)
            .Concat(all.GroupBy(value => value.WebhookId).SelectMany(group => group.OrderByDescending(value => value.CreatedAt).Skip(100)))
            .Select(value => value.Id).Distinct().ToList();
        foreach (var batch in remove.Chunk(500))
            await database.AutomationDeliveries.Where(value => batch.Contains(value.Id)).ExecuteDeleteAsync(cancellationToken);
    }

    private sealed record Outcome(bool Succeeded, bool Retry, int? Status, int? Milliseconds, string? Error, TimeSpan? RetryAfter);

    private async Task<Outcome> SendAsync(WebhookTarget target, string kind, Guid eventId, string body, CancellationToken cancellationToken)
    {
        var started = Stopwatch.GetTimestamp();
        int Elapsed() => (int)Math.Min(int.MaxValue, Stopwatch.GetElapsedTime(started).TotalMilliseconds);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(options.Timeout);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, target.Url)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
            request.Headers.TryAddWithoutValidation(WebhookSigner.SignatureHeader,
                WebhookSigner.Sign(target.Secret, clock.GetUtcNow().ToUnixTimeSeconds(), body));
            request.Headers.TryAddWithoutValidation(WebhookSigner.EventHeader, kind);
            request.Headers.TryAddWithoutValidation(WebhookSigner.DeliveryHeader, eventId.ToString("D"));
            request.Headers.UserAgent.ParseAdd($"Aurelia-Server/{ServerProductVersion.Current}");
            using var response = await clients.CreateClient(ClientName)
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            var status = (int)response.StatusCode;
            var retryAfter = response.Headers.RetryAfter?.Delta;
            if (response.IsSuccessStatusCode) return new Outcome(true, false, status, Elapsed(), null, null);
            var retry = status is 408 or 429 or >= 500;
            return new Outcome(false, retry, status, Elapsed(), $"The receiver answered {status} {response.ReasonPhrase}".Trim(), retryAfter);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new Outcome(false, true, null, Elapsed(), $"No answer within {options.Timeout.TotalSeconds:0} seconds.", null);
        }
        catch (HttpRequestException exception)
        {
            return new Outcome(false, true, null, Elapsed(), Short(exception.Message), null);
        }
    }

    private static string Short(string value) => value.Length <= 200 ? value : value[..200];

    private string Body(AutomationEvent value, WebhookTarget target) => JsonSerializer.Serialize(new AutomationPayload(
        value.Kind,
        value.Id,
        value.OccurredAt,
        new AutomationServerInfo(runtime.ServerName, ServerProductVersion.Current),
        value.Device,
        target.IncludeTitles ? value.Profile : null,
        value.Media is null ? null : target.IncludeTitles ? value.Media
            : value.Media with { Title = string.Empty, SeriesTitle = null, Year = null },
        value.Count), Json);

    [LoggerMessage(LogLevel.Warning, "A webhook delivery could not be handled.")]
    private static partial void DispatchFailed(ILogger logger, Exception exception);
}

/// <summary>Registers the webhook client: no redirects, no proxy, every connection checked.</summary>
public static class WebhookClientRegistration
{
    public static IHttpClientBuilder AddWebhookClient(this IServiceCollection services) =>
        services.AddHttpClient(WebhookDispatcher.ClientName)
            .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
            {
                AllowAutoRedirect = false,
                UseProxy = false,
                UseCookies = false,
                ConnectCallback = WebhookTargetPolicy.ConnectAsync,
                ConnectTimeout = TimeSpan.FromSeconds(4),
                PooledConnectionLifetime = TimeSpan.FromMinutes(2),
                // Home Assistant and many home devices use a certificate made for themselves: one
                // is accepted at home (a local name or a private address), never on the internet.
                SslOptions = { RemoteCertificateValidationCallback = (sender, _, _, errors) =>
                    errors == System.Net.Security.SslPolicyErrors.None || IsHome(sender) },
            });

    private static bool IsHome(object sender)
    {
        var host = sender switch
        {
            System.Net.Security.SslStream stream => stream.TargetHostName,
            HttpRequestMessage message => message.RequestUri?.Host,
            _ => null,
        };
        if (string.IsNullOrEmpty(host)) return false;
        return System.Net.IPAddress.TryParse(host.Trim('[', ']'), out var address)
            ? WebhookTargetPolicy.IsPrivate(address) : WebhookTargetPolicy.IsLocalName(host);
    }
}
