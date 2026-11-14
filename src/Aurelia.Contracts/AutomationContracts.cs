namespace Aurelia.Contracts;

/// <summary>A player's state, sent the moment it changes ("automation-v1").</summary>
public sealed record PlaybackStateRequest(string State, double? PositionSeconds = null, DateTimeOffset? At = null);

public static class PlaybackStates
{
    public const string Playing = "playing";
    public const string Paused = "paused";
    public const string Buffering = "buffering";
    public const string Stopped = "stopped";
    public const string Finished = "finished";

    public static IReadOnlyList<string> All { get; } = Array.AsReadOnly(new[] { Playing, Paused, Buffering, Stopped, Finished });
}

/// <summary>The events a webhook can receive, with the words every app shows for them.</summary>
public static class AutomationEvents
{
    public const string PlaybackStarted = "playback.started";
    public const string PlaybackPaused = "playback.paused";
    public const string PlaybackResumed = "playback.resumed";
    public const string PlaybackStopped = "playback.stopped";
    public const string PlaybackFinished = "playback.finished";
    public const string TitleAdded = "library.title_added";
    public const string ServerStarted = "server.started";
    public const string ServerStopping = "server.stopping";
    public const string Test = "test";

    public static IReadOnlyList<AutomationEventDescription> All { get; } = Array.AsReadOnly(new[]
    {
        new AutomationEventDescription(PlaybackStarted, "Playback Starts", "A movie or episode starts playing, after any buffering."),
        new AutomationEventDescription(PlaybackPaused, "Playback Pauses", "Someone pauses."),
        new AutomationEventDescription(PlaybackResumed, "Playback Continues", "A paused title plays again."),
        new AutomationEventDescription(PlaybackStopped, "Playback Stops", "The player closes before the end."),
        new AutomationEventDescription(PlaybackFinished, "Playback Ends", "A title was watched to its end or its credits."),
        new AutomationEventDescription(TitleAdded, "New Title", "A new movie or show arrives in the library."),
        new AutomationEventDescription(ServerStarted, "Server Starts", "Aurelia Server started, for example after waking."),
        new AutomationEventDescription(ServerStopping, "Server Stops", "Aurelia Server is stopping, sleeping or turning off."),
    });

    public static bool IsPlayback(string kind) => kind.StartsWith("playback.", StringComparison.Ordinal);
    public static bool IsKnown(string kind) => All.Any(value => value.Kind == kind);
}

public sealed record AutomationEventDescription(string Kind, string Title, string Detail);

public static class AutomationPresets
{
    public const string Generic = "generic";
    public const string HomeAssistant = "homeAssistant";
}

/// <summary>What a webhook receives about a title. Absent when the webhook leaves titles out.</summary>
public sealed record AutomationMedia(
    Guid Id,
    string Kind,
    string Title,
    string? SeriesTitle,
    int? Season,
    int? Episode,
    int? Year,
    double? DurationSeconds,
    double? PositionSeconds);

public sealed record AutomationDeviceInfo(Guid Id, string Name, string? Platform);

public sealed record AutomationProfileInfo(string Name, bool IsChild);

public sealed record AutomationServerInfo(string Name, string Version);

/// <summary>The JSON body every webhook receives; signed with X-Aurelia-Signature.</summary>
public sealed record AutomationPayload(
    string Event,
    Guid EventId,
    DateTimeOffset OccurredAt,
    AutomationServerInfo Server,
    AutomationDeviceInfo? Device = null,
    AutomationProfileInfo? Profile = null,
    AutomationMedia? Media = null,
    int? Count = null);

public sealed record AutomationWebhookSummary(
    Guid Id,
    string Name,
    string Url,
    string Preset,
    IReadOnlyList<string> Events,
    IReadOnlyList<Guid> DeviceIds,
    IReadOnlyList<Guid> ProfileIds,
    bool IncludeTitles,
    bool ExcludeChildren,
    bool Enabled,
    string? PausedReason,
    int ConsecutiveFailures,
    AutomationDeliverySummary? LastDelivery,
    DateTimeOffset CreatedAt);

public sealed record SaveAutomationWebhookRequest(
    string Name,
    string Url,
    string Preset,
    IReadOnlyList<string> Events,
    IReadOnlyList<Guid>? DeviceIds = null,
    IReadOnlyList<Guid>? ProfileIds = null,
    bool IncludeTitles = true,
    bool ExcludeChildren = false,
    bool Enabled = true);

/// <summary>A new webhook with its signing secret, shown this once.</summary>
public sealed record AutomationWebhookCreated(AutomationWebhookSummary Webhook, string Secret);

public sealed record AutomationSecretResponse(string Secret);

public sealed record AutomationDeliverySummary(
    Guid Id,
    Guid WebhookId,
    string Event,
    DateTimeOffset At,
    int Attempt,
    string State,
    int? StatusCode,
    int? DurationMilliseconds,
    string? Error);

public static class AutomationDeliveryStates
{
    public const string Pending = "pending";
    public const string Succeeded = "succeeded";
    public const string Failed = "failed";
    public const string Dropped = "dropped";
}

public static class IntegrationScopes
{
    public const string Status = "status";
    public const string Power = "power";
    public const string Playback = "playback";

    public static IReadOnlyList<string> All { get; } = Array.AsReadOnly(new[] { Status, Power, Playback });
}

public sealed record IntegrationTokenSummary(
    Guid Id,
    string Name,
    IReadOnlyList<string> Scopes,
    DateTimeOffset CreatedAt,
    DateTimeOffset? LastUsedAt);

public sealed record CreateIntegrationTokenRequest(string Name, IReadOnlyList<string> Scopes);

/// <summary>A new token, shown this once; only its hash stays on the server.</summary>
public sealed record IntegrationTokenCreated(IntegrationTokenSummary Token, string Value);

public sealed record AutomationChoice(Guid Id, string Name, string? Detail);

public sealed record AutomationOverview(
    IReadOnlyList<AutomationWebhookSummary> Webhooks,
    IReadOnlyList<IntegrationTokenSummary> Tokens,
    IReadOnlyList<AutomationEventDescription> Events,
    IReadOnlyList<AutomationChoice> Devices,
    IReadOnlyList<AutomationChoice> Profiles,
    IReadOnlyList<string> WakeOnLanAddresses,
    IReadOnlyList<string> PowerActions);

public static class PowerNowActions
{
    public const string Sleep = "sleep";
    public const string Shutdown = "shutdown";
    public const string Stop = "stop";
}

public sealed record PowerNowRequest(string Action, bool Force = false);

public sealed record PowerNowResponse(string Action, string Message);

public sealed record NowPlayingEntry(
    string State,
    AutomationDeviceInfo Device,
    AutomationProfileInfo? Profile,
    AutomationMedia Media,
    DateTimeOffset Since);

/// <summary>What Home Assistant or a shortcut reads with a "status" token.</summary>
public sealed record IntegrationStatusResponse(
    AutomationServerInfo Server,
    IReadOnlyList<NowPlayingEntry> Playing,
    IReadOnlyList<string> PowerActions);
