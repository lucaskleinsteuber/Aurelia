using System.Globalization;
using System.Text.Json.Nodes;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Management;

/// <summary>Security ("security-v1", server 2.15.0): the log, devices, the block list and confirming an unlock elsewhere.</summary>
public sealed partial class ManagementClient
{
    public Task<SecurityEventPage> SecurityEventsAsync(string? outcome = null, DateTimeOffset? before = null, int limit = 50)
    {
        var query = new List<string>();
        if (!string.IsNullOrEmpty(outcome) && outcome != "all") query.Add("outcome=" + Uri.EscapeDataString(outcome));
        if (before is { } value) query.Add("before=" + Uri.EscapeDataString(value.ToString("O", CultureInfo.InvariantCulture)));
        query.Add("limit=" + limit.ToString(CultureInfo.InvariantCulture));
        return GetAsync<SecurityEventPage>("/api/v1/server/security/events?" + string.Join('&', query));
    }

    public Task<IReadOnlyList<SecurityDeviceSummary>> SecurityDevicesAsync() =>
        GetAsync<IReadOnlyList<SecurityDeviceSummary>>("/api/v1/server/security/devices");

    public Task AcknowledgeDeviceAsync(Guid id) => SendAsync<JsonNode>(HttpMethod.Post, $"/api/v1/server/security/devices/{id}/acknowledge", null);

    public Task<BlockDeviceResponse> BlockDeviceAsync(Guid id) => SendAsync<BlockDeviceResponse>(HttpMethod.Post, $"/api/v1/server/security/devices/{id}/block", null);

    public Task<IReadOnlyList<BlockedDeviceSummary>> BlockedDevicesAsync() =>
        GetAsync<IReadOnlyList<BlockedDeviceSummary>>("/api/v1/server/security/blocked");

    public Task UnblockDeviceAsync(Guid id) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/server/security/blocked/{id}", null);

    public Task<SecuritySettingsResponse> SecuritySettingsAsync() => GetAsync<SecuritySettingsResponse>("/api/v1/server/security/settings");

    public Task<SecuritySettingsResponse> SaveSecuritySettingsAsync(UpdateSecuritySettingsRequest request) =>
        SendAsync<SecuritySettingsResponse>(HttpMethod.Put, "/api/v1/server/security/settings", request);

    /// <summary>New devices for the owner; waits up to <paramref name="waitSeconds"/> for a change after <paramref name="version"/>.</summary>
    public Task<SecurityAlertsResponse> SecurityAlertsAsync(long version, int waitSeconds, CancellationToken cancellation = default) =>
        GetAsync<SecurityAlertsResponse>(
            $"/api/v1/server/security/alerts?version={version.ToString(CultureInfo.InvariantCulture)}&waitSeconds={waitSeconds.ToString(CultureInfo.InvariantCulture)}",
            cancellation);

    /// <summary>Asks an iPhone, iPad or Mac with Face ID or Touch ID to unlock management here.</summary>
    public async Task<RemoteUnlockStartResponse> StartRemoteUnlockAsync(CancellationToken cancellation = default) =>
        await AureliaApi.SendAsync<RemoteUnlockStartResponse>(Pinned, HttpMethod.Post, "/api/v1/management/remote-unlock", Library.Profile.Token,
            null, false, cancellation);

    public async Task<RemoteUnlockStatusResponse> RemoteUnlockStatusAsync(Guid id, CancellationToken cancellation = default) =>
        await AureliaApi.SendAsync<RemoteUnlockStatusResponse>(Pinned, HttpMethod.Get, $"/api/v1/management/remote-unlock/{id}", Library.Profile.Token,
            null, false, cancellation);

    /// <summary>
    /// Polls a confirmation request until the other device answers or it expires. True only when it
    /// was approved; management is then unlocked for ten minutes.
    /// </summary>
    public async Task<bool> WaitForRemoteUnlockAsync(Guid id, TimeSpan interval, CancellationToken cancellation = default)
    {
        while (true)
        {
            var status = await RemoteUnlockStatusAsync(id, cancellation);
            if (SecurityText.RemoteUnlockFinished(status.State)) return status.State == "approved";
            await Task.Delay(interval, cancellation);
        }
    }
}
