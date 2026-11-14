using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Aurelia.Server.Services.Automation;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Endpoints;

/// <summary>
/// Smart Home ("automation-v1"): players' state reports, the owner's webhooks and integration
/// keys, turning the server off now, and the few calls Home Assistant or a shortcut makes with a
/// key. See docs/AUTOMATION.md.
/// </summary>
public static class AutomationEndpoints
{
    public static void MapAutomationEndpoints(this WebApplication app)
    {
        // A player says it plays, pauses, buffers, stops or finished, the moment that happens.
        app.MapPost("/api/v1/playback/{ticketId:guid}/state", (HttpContext context, Guid ticketId, PlaybackStateRequest request,
            PlaybackActivityTracker tracker) =>
        {
            if (!PlaybackStates.All.Contains(request.State))
                return Problem("invalid_playback_state", "Send playing, paused, buffering, stopped or finished.", 400);
            if (request.PositionSeconds is < 0 or > 864_000) return Problem("invalid_position", "The position is out of range.", 400);
            return tracker.Report(ticketId, context.User.RequireUserId(), request.State, request.PositionSeconds)
                ? Results.NoContent()
                : Problem("playback_not_found", "This playback ended or belongs to another profile.", 404);
        }).RequireAuthorization();

        var owner = app.MapGroup("/api/v1/server/automation").RequireAuthorization("Owner");
        owner.MapGet("", async (AutomationStore store, AureliaDbContext database, PowerNowService power, CancellationToken cancellationToken) =>
        {
            var now = DateTimeOffset.UtcNow;
            var devices = (await database.DeviceSessions.AsNoTracking()
                    .Where(value => value.RevokedAt == null && value.ExpiresAt > now).ToListAsync(cancellationToken))
                .OrderBy(value => value.DeviceName, StringComparer.OrdinalIgnoreCase)
                .Select(value => new AutomationChoice(value.Id, value.DeviceName, value.Platform)).ToList();
            var profiles = (await database.Users.AsNoTracking().ToListAsync(cancellationToken))
                .OrderBy(value => value.DisplayName ?? value.Username, StringComparer.OrdinalIgnoreCase)
                .Select(value => new AutomationChoice(value.Id, value.DisplayName ?? value.Username,
                    value.AgeLimit is { } age ? $"Children’s profile · {age}" : null)).ToList();
            return Results.Ok(new AutomationOverview(
                await store.WebhooksAsync(cancellationToken), await store.TokensAsync(cancellationToken), AutomationEvents.All,
                devices, profiles, WakeOnLan.LocalAddresses(), power.Actions));
        });
        owner.MapPost("/webhooks", (SaveAutomationWebhookRequest request, AutomationStore store, CancellationToken cancellationToken) =>
            Run(async () => Results.Ok(await store.CreateAsync(request, cancellationToken))));
        owner.MapPut("/webhooks/{id:guid}", (Guid id, SaveAutomationWebhookRequest request, AutomationStore store, CancellationToken cancellationToken) =>
            Run(async () => Results.Ok(await store.UpdateAsync(id, request, cancellationToken))));
        owner.MapDelete("/webhooks/{id:guid}", (Guid id, AutomationStore store, CancellationToken cancellationToken) =>
            Run(async () => { await store.DeleteAsync(id, cancellationToken); return Results.NoContent(); }));
        owner.MapPost("/webhooks/{id:guid}/secret", (Guid id, AutomationStore store, CancellationToken cancellationToken) =>
            Run(async () => Results.Ok(await store.RotateSecretAsync(id, cancellationToken))));
        owner.MapGet("/webhooks/{id:guid}/deliveries", (Guid id, int? limit, AutomationStore store, CancellationToken cancellationToken) =>
            Run(async () => Results.Ok(await store.DeliveriesAsync(id, limit ?? 50, cancellationToken))));
        owner.MapPost("/webhooks/{id:guid}/test", (Guid id, AutomationStore store, WebhookDispatcher dispatcher, CancellationToken cancellationToken) =>
            Run(async () => Results.Ok(await dispatcher.TestAsync(await store.TargetAsync(id, cancellationToken), cancellationToken))));
        owner.MapPost("/tokens", (HttpContext context, CreateIntegrationTokenRequest request, AutomationStore store, CancellationToken cancellationToken) =>
            Run(async () => Results.Ok(await store.CreateTokenAsync(context.User.RequireUserId(), request, cancellationToken))));
        owner.MapDelete("/tokens/{id:guid}", (Guid id, AutomationStore store, CancellationToken cancellationToken) =>
            Run(async () => { await store.RevokeTokenAsync(id, cancellationToken); return Results.NoContent(); }));

        app.MapPost("/api/v1/server/power/now", (PowerNowRequest request, PowerNowService power) =>
            Run(() => Task.FromResult(Results.Ok(power.Request(request))))).RequireAuthorization("Owner");

        // Home Assistant and shortcuts: a key, never a profile. Each call needs its own scope.
        var integration = app.MapGroup("/api/v1/integration").AllowAnonymous();
        integration.MapGet("/status", async (HttpContext context, AutomationStore store, PlaybackActivityTracker tracker,
            ServerRuntimeOptions runtime, PowerNowService power, CancellationToken cancellationToken) =>
        {
            if (await store.AuthorizeAsync(context.Request.Headers.Authorization, IntegrationScopes.Status, cancellationToken) is null)
                return Denied(context);
            return Results.Ok(new IntegrationStatusResponse(
                new AutomationServerInfo(runtime.ServerName, ServerProductVersion.Current),
                tracker.Current.Select(value => new NowPlayingEntry(value.State, value.Device, value.Profile, value.Media, value.Since)).ToList(),
                power.Actions));
        });
        integration.MapPost("/power", async (HttpContext context, PowerNowRequest request, AutomationStore store, PowerNowService power,
            SecurityLog log, CancellationToken cancellationToken) =>
        {
            var token = await store.AuthorizeAsync(context.Request.Headers.Authorization, IntegrationScopes.Power, cancellationToken);
            if (token is null) return Denied(context);
            return await Run(() =>
            {
                var response = power.Request(request);
                log.Record("power_now", SecurityLog.Changed, token.UserId, detail: $"{request.Action} · {token.Name}", identity: ClientIdentity.From(context));
                return Task.FromResult(Results.Ok(response));
            });
        });
        integration.MapGet("/players", async (HttpContext context, AutomationStore store, RemotePlaybackService players,
            CancellationToken cancellationToken) =>
        {
            var token = await store.AuthorizeAsync(context.Request.Headers.Authorization, IntegrationScopes.Playback, cancellationToken);
            return token is null ? Denied(context) : Results.Ok(players.GetActiveDevices(token.UserId));
        });
        integration.MapPost("/players/{deviceId}/commands", async (HttpContext context, string deviceId, RemotePlaybackCommandRequest request,
            AutomationStore store, RemotePlaybackService players, CancellationToken cancellationToken) =>
        {
            var token = await store.AuthorizeAsync(context.Request.Headers.Authorization, IntegrationScopes.Playback, cancellationToken);
            if (token is null) return Denied(context);
            try { return Results.Ok(players.SendCommand(token.UserId, deviceId, request)); }
            catch (AccountException exception) { return Problem(exception.Code, exception.Message, exception.StatusCode); }
        });
    }

    private static IResult Denied(HttpContext context)
    {
        context.Items["Aurelia.FailureRecorded"] = true;
        return Problem("integration_key_rejected", "This key is unknown, was removed, or may not do this.", 401);
    }

    private static async Task<IResult> Run(Func<Task<IResult>> action)
    {
        try { return await action(); }
        catch (AutomationException exception) { return Problem(exception.Code, exception.Message, exception.StatusCode); }
    }

    private static IResult Problem(string code, string message, int statusCode) =>
        Results.Json(new ApiProblem(code, message), statusCode: statusCode);
}
