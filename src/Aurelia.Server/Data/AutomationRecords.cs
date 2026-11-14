namespace Aurelia.Server.Data;

/// <summary>
/// A webhook the owner set up for Home Assistant or another automation. Lists are stored as
/// comma-separated values; the signing secret only encrypted with the server's data protection keys.
/// </summary>
public sealed class AutomationWebhook
{
    public Guid Id { get; set; }
    public required string Name { get; set; }
    public required string Url { get; set; }
    public required string Preset { get; set; }
    public required string Events { get; set; }
    public string DeviceIds { get; set; } = string.Empty;
    public string ProfileIds { get; set; } = string.Empty;
    public bool IncludeTitles { get; set; } = true;
    public bool ExcludeChildren { get; set; }
    public bool Enabled { get; set; } = true;
    public string? PausedReason { get; set; }
    public int ConsecutiveFailures { get; set; }
    public required string ProtectedSecret { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

/// <summary>
/// One delivery of an event to a webhook. Pending rows hold the body until it was delivered or
/// given up (an hour at most); finished rows keep only the outcome, for the delivery log.
/// </summary>
public sealed class AutomationDelivery
{
    public Guid Id { get; set; }
    public Guid WebhookId { get; set; }
    public Guid EventId { get; set; }
    public required string Event { get; set; }
    public required string State { get; set; }
    public int Attempt { get; set; }
    public string? Payload { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? NextAttemptAt { get; set; }
    public DateTimeOffset? CompletedAt { get; set; }
    public int? StatusCode { get; set; }
    public int? DurationMilliseconds { get; set; }
    public string? Error { get; set; }
}

/// <summary>A long-lived key for Home Assistant or a shortcut; only its SHA-256 is stored.</summary>
public sealed class IntegrationToken
{
    public Guid Id { get; set; }
    public required string Name { get; set; }
    public required string TokenHash { get; set; }
    public required string Scopes { get; set; }
    /// <summary>The owner's profile, whose players the "playback" scope may control.</summary>
    public Guid UserId { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? LastUsedAt { get; set; }
}
