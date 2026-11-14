using System.Text.Json.Nodes;
using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Management;

/// <summary>Smart Home ("automation-v1", server 2.16.0): webhooks, integration keys and turning the server off now.</summary>
public sealed partial class ManagementClient
{
    public Task<AutomationOverview> AutomationOverviewAsync() => GetAsync<AutomationOverview>("/api/v1/server/automation");

    public Task<AutomationWebhookCreated> CreateWebhookAsync(SaveAutomationWebhookRequest request) =>
        SendAsync<AutomationWebhookCreated>(HttpMethod.Post, "/api/v1/server/automation/webhooks", request);

    public Task<AutomationWebhookSummary> SaveWebhookAsync(Guid id, SaveAutomationWebhookRequest request) =>
        SendAsync<AutomationWebhookSummary>(HttpMethod.Put, $"/api/v1/server/automation/webhooks/{id}", request);

    public Task DeleteWebhookAsync(Guid id) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/server/automation/webhooks/{id}", null);

    public Task<AutomationDeliverySummary> TestWebhookAsync(Guid id) =>
        SendAsync<AutomationDeliverySummary>(HttpMethod.Post, $"/api/v1/server/automation/webhooks/{id}/test", null);

    public Task<IReadOnlyList<AutomationDeliverySummary>> WebhookDeliveriesAsync(Guid id) =>
        GetAsync<IReadOnlyList<AutomationDeliverySummary>>($"/api/v1/server/automation/webhooks/{id}/deliveries?limit=50");

    public Task<AutomationSecretResponse> RotateWebhookSecretAsync(Guid id) =>
        SendAsync<AutomationSecretResponse>(HttpMethod.Post, $"/api/v1/server/automation/webhooks/{id}/secret", null);

    public Task<IntegrationTokenCreated> CreateIntegrationTokenAsync(CreateIntegrationTokenRequest request) =>
        SendAsync<IntegrationTokenCreated>(HttpMethod.Post, "/api/v1/server/automation/tokens", request);

    public Task RevokeIntegrationTokenAsync(Guid id) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/server/automation/tokens/{id}", null);

    public Task<PowerNowResponse> PowerNowAsync(string action, bool force = false) =>
        SendAsync<PowerNowResponse>(HttpMethod.Post, "/api/v1/server/power/now", new PowerNowRequest(action, force));
}

/// <summary>The words and rules of Settings › Smart Home, the same as in the other apps.</summary>
public static class AutomationText
{
    public static readonly IReadOnlyList<(string Id, string Title, string Detail)> Scopes =
    [
        (IntegrationScopes.Status, "Read What Plays", "What is playing where, and whether the server can turn off."),
        (IntegrationScopes.Power, "Turn the Server Off", "Sleep, turn off or stop the server, for example from a Home Assistant button."),
        (IntegrationScopes.Playback, "Control Players", "Play, pause or stop on your own devices that have Aurelia open."),
    ];

    public static string PowerTitle(string action) => action switch
    {
        PowerNowActions.Sleep => "Sleep Now",
        PowerNowActions.Shutdown => "Turn Off Now",
        _ => "Stop Aurelia Now",
    };

    public static string PowerDetail(string action) => action switch
    {
        PowerNowActions.Sleep => "The computer sleeps; Wake-on-LAN wakes it in about 10 to 20 seconds.",
        PowerNowActions.Shutdown => "The computer turns off; Wake-on-LAN starts it in about 30 to 60 seconds.",
        _ => "Only Aurelia Server stops.",
    };

    /// <summary>Home Assistant's webhook address from its address and the trigger's ID; null when invalid.</summary>
    public static string? HomeAssistantUrl(string address, string webhookId)
    {
        var trimmed = (address ?? "").Trim().TrimEnd('/');
        var id = (webhookId ?? "").Trim();
        if (trimmed.Length == 0 || id.Length == 0 || id.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-' && c != '_')) return null;
        var withScheme = trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
            ? trimmed : "http://" + trimmed;
        if (!Uri.TryCreate(withScheme, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)) return null;
        var hasPort = withScheme.Split('/')[2].Contains(':', StringComparison.Ordinal);
        var port = hasPort || uri.Scheme == "https" ? uri.Port : 8123;
        var host = uri.HostNameType == UriHostNameType.IPv6 ? $"[{uri.Host.Trim('[', ']')}]" : uri.Host;
        var defaultPort = (uri.Scheme == "https" && port == 443) || (uri.Scheme == "http" && port == 80);
        return $"{uri.Scheme}://{host}{(defaultPort ? "" : ":" + port.ToString(System.Globalization.CultureInfo.InvariantCulture))}/api/webhook/{id}";
    }

    public static (string Address, string WebhookId) SplitHomeAssistantUrl(string url)
    {
        var index = (url ?? "").IndexOf("/api/webhook/", StringComparison.Ordinal);
        return index < 0 ? ("", "") : (url![..index], url[(index + "/api/webhook/".Length)..]);
    }

    public static string Host(string url) => Uri.TryCreate(url, UriKind.Absolute, out var uri) ? uri.Authority : url;

    /// <summary>One line about the last delivery.</summary>
    public static (bool Warning, string Text) Status(AutomationWebhookSummary webhook)
    {
        if (!webhook.Enabled) return (false, "Off");
        if (webhook.PausedReason is not null) return (true, "Paused after failed deliveries");
        if (webhook.LastDelivery is not { } last) return (false, "Nothing sent yet");
        return last.State == AutomationDeliveryStates.Succeeded
            ? (false, $"Last delivery {last.DurationMilliseconds ?? 0} ms")
            : (true, last.Error ?? "The last delivery failed");
    }

    public static string HomeAssistantExample(string webhookId) =>
        ExampleTemplate.Replace("WEBHOOK_ID", webhookId.Length == 0 ? "aurelia" : webhookId, StringComparison.Ordinal);

    private const string ExampleTemplate = """
        alias: Aurelia – movie lights
        triggers:
          - trigger: webhook
            webhook_id: WEBHOOK_ID
            allowed_methods: [POST]
            local_only: true
        actions:
          - choose:
              - conditions:
                  - condition: template
                    value_template: "{{ trigger.json.event in ['playback.started', 'playback.resumed'] }}"
                sequence:
                  - action: light.turn_on
                    target: { area_id: living_room }
                    data: { brightness_pct: 10, transition: 2 }
              - conditions:
                  - condition: template
                    value_template: "{{ trigger.json.event in ['playback.paused', 'playback.stopped', 'playback.finished'] }}"
                sequence:
                  - action: light.turn_on
                    target: { area_id: living_room }
                    data: { brightness_pct: 70, transition: 2 }

        """;
}
