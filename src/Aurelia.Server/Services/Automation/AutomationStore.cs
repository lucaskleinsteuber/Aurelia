using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services.Automation;

public sealed class AutomationException(string code, string message, int statusCode = 400) : Exception(message)
{
    public string Code { get; } = code;
    public int StatusCode { get; } = statusCode;
}

/// <summary>A webhook as the dispatcher needs it: its filters and its secret, decrypted.</summary>
public sealed record WebhookTarget(
    Guid Id,
    string Url,
    IReadOnlySet<string> Events,
    IReadOnlySet<Guid> DeviceIds,
    IReadOnlySet<Guid> ProfileIds,
    bool IncludeTitles,
    bool ExcludeChildren,
    string Secret)
{
    public bool Wants(AutomationEvent value)
    {
        if (value.Kind != AutomationEvents.Test && !Events.Contains(value.Kind)) return false;
        if (value.Device is { } device && DeviceIds.Count > 0 && !DeviceIds.Contains(device.Id)) return false;
        if (value.ProfileId is { } profile && ProfileIds.Count > 0 && !ProfileIds.Contains(profile)) return false;
        return !(ExcludeChildren && value.Profile?.IsChild == true);
    }
}

/// <summary>Counts changes to webhooks, so the dispatcher reloads them only when one changed.</summary>
public sealed class AutomationWebhookCache
{
    private int version;
    public int Version => Volatile.Read(ref version);
    public void Changed() => Interlocked.Increment(ref version);
}

/// <summary>The owner's webhooks and integration tokens.</summary>
public sealed class AutomationStore(
    AureliaDbContext database,
    IDataProtectionProvider protection,
    TokenService tokens,
    AutomationWebhookCache cache,
    TimeProvider clock)
{
    public const int MaximumWebhooks = 20;
    public const int MaximumTokens = 20;
    public const string TokenPrefix = "aur_it_";
    private const string SecretPurpose = "Aurelia.Automation.WebhookSecret.v1";

    public async Task<IReadOnlyList<AutomationWebhookSummary>> WebhooksAsync(CancellationToken cancellationToken)
    {
        var hooks = await database.AutomationWebhooks.AsNoTracking().OrderBy(value => value.CreatedAt).ToListAsync(cancellationToken);
        var ids = hooks.Select(value => value.Id).ToList();
        var last = (await database.AutomationDeliveries.AsNoTracking()
                .Where(value => ids.Contains(value.WebhookId) && value.State != AutomationDeliveryStates.Pending)
                .ToListAsync(cancellationToken))
            .GroupBy(value => value.WebhookId)
            .ToDictionary(group => group.Key, group => group.OrderByDescending(value => value.CreatedAt).First());
        return hooks.Select(hook => Summary(hook, last.GetValueOrDefault(hook.Id))).ToList();
    }

    public async Task<IReadOnlyList<IntegrationTokenSummary>> TokensAsync(CancellationToken cancellationToken) =>
        (await database.IntegrationTokens.AsNoTracking().OrderBy(value => value.CreatedAt).ToListAsync(cancellationToken))
            .Select(Summary).ToList();

    public async Task<AutomationWebhookCreated> CreateAsync(SaveAutomationWebhookRequest request, CancellationToken cancellationToken)
    {
        Validate(request);
        if (await database.AutomationWebhooks.CountAsync(cancellationToken) >= MaximumWebhooks)
            throw new AutomationException("too_many_webhooks", $"A server keeps up to {MaximumWebhooks} webhooks.", 409);
        var now = clock.GetUtcNow();
        var secret = WebhookSigner.CreateSecret();
        var hook = new AutomationWebhook
        {
            Id = Guid.NewGuid(),
            Name = request.Name.Trim(),
            Url = request.Url.Trim(),
            Preset = request.Preset,
            Events = string.Join(',', request.Events.Distinct()),
            ProtectedSecret = string.Empty,
            CreatedAt = now,
            UpdatedAt = now,
        };
        Apply(hook, request);
        hook.ProtectedSecret = Protector(hook.Id).Protect(secret);
        database.AutomationWebhooks.Add(hook);
        await database.SaveChangesAsync(cancellationToken);
        cache.Changed();
        return new AutomationWebhookCreated(Summary(hook, null), secret);
    }

    public async Task<AutomationWebhookSummary> UpdateAsync(Guid id, SaveAutomationWebhookRequest request, CancellationToken cancellationToken)
    {
        Validate(request);
        var hook = await FindAsync(id, cancellationToken);
        hook.Name = request.Name.Trim();
        hook.Url = request.Url.Trim();
        hook.Preset = request.Preset;
        hook.Events = string.Join(',', request.Events.Distinct());
        Apply(hook, request);
        // Saving again resumes a webhook that was paused after failed deliveries.
        hook.PausedReason = null;
        hook.ConsecutiveFailures = 0;
        hook.UpdatedAt = clock.GetUtcNow();
        await database.SaveChangesAsync(cancellationToken);
        cache.Changed();
        return Summary(hook, null);
    }

    public async Task DeleteAsync(Guid id, CancellationToken cancellationToken)
    {
        var hook = await FindAsync(id, cancellationToken);
        database.AutomationWebhooks.Remove(hook);
        await database.AutomationDeliveries.Where(value => value.WebhookId == id).ExecuteDeleteAsync(cancellationToken);
        await database.SaveChangesAsync(cancellationToken);
        cache.Changed();
    }

    public async Task<AutomationSecretResponse> RotateSecretAsync(Guid id, CancellationToken cancellationToken)
    {
        var hook = await FindAsync(id, cancellationToken);
        var secret = WebhookSigner.CreateSecret();
        hook.ProtectedSecret = Protector(hook.Id).Protect(secret);
        hook.UpdatedAt = clock.GetUtcNow();
        await database.SaveChangesAsync(cancellationToken);
        cache.Changed();
        return new AutomationSecretResponse(secret);
    }

    public async Task<IReadOnlyList<AutomationDeliverySummary>> DeliveriesAsync(Guid id, int limit, CancellationToken cancellationToken)
    {
        _ = await FindAsync(id, cancellationToken);
        return (await database.AutomationDeliveries.AsNoTracking().Where(value => value.WebhookId == id)
                .ToListAsync(cancellationToken))
            .OrderByDescending(value => value.CreatedAt).Take(Math.Clamp(limit, 1, 100)).Select(Summary).ToList();
    }

    /// <summary>The enabled, unpaused webhooks with their secrets, for the dispatcher.</summary>
    public async Task<IReadOnlyList<WebhookTarget>> TargetsAsync(CancellationToken cancellationToken)
    {
        var hooks = await database.AutomationWebhooks.AsNoTracking()
            .Where(value => value.Enabled && value.PausedReason == null).ToListAsync(cancellationToken);
        var targets = new List<WebhookTarget>();
        foreach (var hook in hooks)
        {
            if (Secret(hook) is not { } secret) continue;
            targets.Add(Target(hook, secret));
        }
        return targets;
    }

    public async Task<WebhookTarget> TargetAsync(Guid id, CancellationToken cancellationToken)
    {
        var hook = await FindAsync(id, cancellationToken);
        return Target(hook, Secret(hook) ?? throw new AutomationException("webhook_secret_lost",
            "This webhook's secret can't be read on this server (it was restored elsewhere). Create a new secret.", 409));
    }

    private static WebhookTarget Target(AutomationWebhook hook, string secret) => new(
        hook.Id, hook.Url, Split(hook.Events).ToHashSet(), Ids(hook.DeviceIds).ToHashSet(), Ids(hook.ProfileIds).ToHashSet(),
        hook.IncludeTitles, hook.ExcludeChildren, secret);

    private string? Secret(AutomationWebhook hook)
    {
        try { return Protector(hook.Id).Unprotect(hook.ProtectedSecret); }
        catch (System.Security.Cryptography.CryptographicException) { return null; }
    }

    public async Task<IntegrationTokenCreated> CreateTokenAsync(Guid ownerId, CreateIntegrationTokenRequest request, CancellationToken cancellationToken)
    {
        var name = (request.Name ?? string.Empty).Trim();
        if (name.Length is < 1 or > 64) throw new AutomationException("invalid_token_name", "Give the key a name of up to 64 characters.");
        var scopes = (request.Scopes ?? []).Distinct().ToList();
        if (scopes.Count == 0 || scopes.Any(scope => !IntegrationScopes.All.Contains(scope)))
            throw new AutomationException("invalid_token_scopes", "Choose what the key may do.");
        if (await database.IntegrationTokens.CountAsync(cancellationToken) >= MaximumTokens)
            throw new AutomationException("too_many_tokens", $"A server keeps up to {MaximumTokens} keys.", 409);
        var value = TokenPrefix + tokens.CreateDeviceToken();
        var token = new IntegrationToken
        {
            Id = Guid.NewGuid(),
            Name = name,
            TokenHash = tokens.Hash(value),
            Scopes = string.Join(',', scopes),
            UserId = ownerId,
            CreatedAt = clock.GetUtcNow(),
        };
        database.IntegrationTokens.Add(token);
        await database.SaveChangesAsync(cancellationToken);
        return new IntegrationTokenCreated(Summary(token), value);
    }

    public async Task RevokeTokenAsync(Guid id, CancellationToken cancellationToken)
    {
        var token = await database.IntegrationTokens.SingleOrDefaultAsync(value => value.Id == id, cancellationToken)
            ?? throw new AutomationException("token_not_found", "This key was already removed.", 404);
        database.IntegrationTokens.Remove(token);
        await database.SaveChangesAsync(cancellationToken);
    }

    /// <summary>The token a request carries, if it is valid and allows this scope.</summary>
    public async Task<IntegrationToken?> AuthorizeAsync(string? header, string scope, CancellationToken cancellationToken)
    {
        if (header is null || !header.StartsWith("Bearer " + TokenPrefix, StringComparison.Ordinal)) return null;
        var raw = header["Bearer ".Length..].Trim();
        if (raw.Length is < 40 or > 128) return null;
        var hash = tokens.Hash(raw);
        var token = await database.IntegrationTokens.SingleOrDefaultAsync(value => value.TokenHash == hash, cancellationToken);
        if (token is null || !Split(token.Scopes).Contains(scope)) return null;
        var now = clock.GetUtcNow();
        if (token.LastUsedAt is not { } used || now - used > TimeSpan.FromMinutes(1))
        {
            token.LastUsedAt = now;
            await database.SaveChangesAsync(cancellationToken);
        }
        return token;
    }

    private async Task<AutomationWebhook> FindAsync(Guid id, CancellationToken cancellationToken) =>
        await database.AutomationWebhooks.SingleOrDefaultAsync(value => value.Id == id, cancellationToken)
        ?? throw new AutomationException("webhook_not_found", "This webhook was removed.", 404);

    private static void Apply(AutomationWebhook hook, SaveAutomationWebhookRequest request)
    {
        hook.DeviceIds = string.Join(',', (request.DeviceIds ?? []).Distinct().Select(value => value.ToString("D")));
        hook.ProfileIds = string.Join(',', (request.ProfileIds ?? []).Distinct().Select(value => value.ToString("D")));
        hook.IncludeTitles = request.IncludeTitles;
        hook.ExcludeChildren = request.ExcludeChildren;
        hook.Enabled = request.Enabled;
    }

    public static void Validate(SaveAutomationWebhookRequest request)
    {
        var name = (request.Name ?? string.Empty).Trim();
        if (name.Length is < 1 or > 64) throw new AutomationException("invalid_webhook_name", "Give the webhook a name of up to 64 characters.");
        if (WebhookTargetPolicy.Problem(request.Url) is { } problem) throw new AutomationException("invalid_webhook_url", problem);
        if (request.Preset is not (AutomationPresets.Generic or AutomationPresets.HomeAssistant))
            throw new AutomationException("invalid_webhook_preset", "Choose Home Assistant or another receiver.");
        if (request.Events is not { Count: > 0 } || request.Events.Any(kind => !AutomationEvents.IsKnown(kind)))
            throw new AutomationException("invalid_webhook_events", "Choose at least one event.");
        if ((request.DeviceIds?.Count ?? 0) > 50 || (request.ProfileIds?.Count ?? 0) > 50)
            throw new AutomationException("invalid_webhook_filter", "Choose up to 50 devices and profiles.");
    }

    private IDataProtector Protector(Guid id) => protection.CreateProtector(SecretPurpose, id.ToString("D"));

    private static string[] Split(string value) => value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    private static IEnumerable<Guid> Ids(string value) => Split(value).Select(text => Guid.TryParse(text, out var id) ? id : Guid.Empty)
        .Where(id => id != Guid.Empty);

    public static AutomationWebhookSummary Summary(AutomationWebhook hook, AutomationDelivery? last) => new(
        hook.Id, hook.Name, hook.Url, hook.Preset, Split(hook.Events).ToList(), Ids(hook.DeviceIds).ToList(), Ids(hook.ProfileIds).ToList(),
        hook.IncludeTitles, hook.ExcludeChildren, hook.Enabled, hook.PausedReason, hook.ConsecutiveFailures,
        last is null ? null : Summary(last), hook.CreatedAt);

    public static AutomationDeliverySummary Summary(AutomationDelivery value) => new(
        value.Id, value.WebhookId, value.Event, value.CreatedAt, value.Attempt, value.State, value.StatusCode,
        value.DurationMilliseconds, value.Error);

    public static IntegrationTokenSummary Summary(IntegrationToken token) => new(
        token.Id, token.Name, Split(token.Scopes).ToList(), token.CreatedAt, token.LastUsedAt);
}
