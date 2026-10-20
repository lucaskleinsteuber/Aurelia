using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>A network change the server is trying; it must be confirmed before the deadline or it rolls back.</summary>
public sealed record ServerOperationStatus(Guid Id, string Kind, string State, DateTimeOffset? ConfirmBefore, int? HttpsPort);

/// <summary>The stored server settings as the server sends them, kept whole so a change keeps every other field.</summary>
public sealed record ServerSettingsDocument(JsonObject Stored, bool RestartRequired)
{
    public string ServerName => Stored["serverName"]?.GetValue<string>() ?? "";
    public bool LanAccessEnabled => Stored["lanAccessEnabled"]?.GetValue<bool>() ?? false;
    public int LanHttpsPort => Stored["lanHttpsPort"]?.GetValue<int>() ?? ServerAddress.DefaultPort;
}

/// <summary>What the owner manages on their own server; tests replace it with a scripted one.</summary>
public interface IServerManagement : IAdministrationClient
{
    Task<ServerStatusResponse> StatusAsync(CancellationToken cancellation);
    Task<ServerSettingsDocument> SettingsAsync(CancellationToken cancellation);
    Task<IReadOnlyList<LibrarySummary>> LibrariesAsync(CancellationToken cancellation);
    Task<IReadOnlyList<LibraryScanSummary>> ActiveScansAsync(CancellationToken cancellation);
    Task<LibrarySummary> AddLibraryAsync(string? name, string path, LibraryKind kind, CancellationToken cancellation);
    Task<LibraryScanSummary> ScanAsync(Guid library, CancellationToken cancellation);
    Task RemoveLibraryAsync(Guid library, CancellationToken cancellation);
    Task<DeviceAuthorizationPreview> LookUpDeviceAsync(string code, CancellationToken cancellation);
    Task AnswerDeviceAsync(Guid request, bool approve, CancellationToken cancellation);
    Task<IReadOnlyList<DeviceSessionSummary>> DevicesAsync(CancellationToken cancellation);
    Task RemoveDeviceAsync(Guid session, CancellationToken cancellation);
    Task<ServerOperationStatus> TryNetworkAsync(JsonObject settings, bool confirmDisconnect, CancellationToken cancellation);
    Task ConfirmNetworkAsync(Guid operation, CancellationToken cancellation);
}

/// <summary>
/// Owner management over the pinned connection, the way the Mac app does it: the Server Password
/// unlocks management for ten minutes, and every lasting change is additionally approved for
/// exactly its method, path and body, once.
/// </summary>
public sealed class ServerManagementClient(AureliaServerApi api, StoredConnection connection, string profileToken) : IServerManagement
{
    private HttpClient Client => api.Pinned(connection.Address, connection.Fingerprint);

    public async Task<DateTimeOffset> UnlockAsync(string password, CancellationToken cancellation) =>
        (await SendCoreAsync<ManagementUnlockResponse>(HttpMethod.Post, "/api/v1/management/unlock", new UnlockManagementRequest(password), false, cancellation)).ExpiresAt;

    public Task<ServerStatusResponse> StatusAsync(CancellationToken cancellation) =>
        SendCoreAsync<ServerStatusResponse>(HttpMethod.Get, "/api/v1/server/status", null, false, cancellation);

    public async Task<ServerSettingsDocument> SettingsAsync(CancellationToken cancellation)
    {
        var document = await SendCoreAsync<JsonObject>(HttpMethod.Get, "/api/v1/server/settings", null, false, cancellation);
        return document["stored"] is JsonObject stored
            ? new ServerSettingsDocument((JsonObject)stored.DeepClone(), document["restartRequired"]?.GetValue<bool>() ?? false)
            : throw AureliaApiException.InvalidResponse();
    }

    public Task<IReadOnlyList<LibrarySummary>> LibrariesAsync(CancellationToken cancellation) =>
        SendCoreAsync<IReadOnlyList<LibrarySummary>>(HttpMethod.Get, "/api/v1/libraries", null, false, cancellation);

    public Task<IReadOnlyList<LibraryScanSummary>> ActiveScansAsync(CancellationToken cancellation) =>
        SendCoreAsync<IReadOnlyList<LibraryScanSummary>>(HttpMethod.Get, "/api/v1/libraries/scans", null, false, cancellation);

    public Task<LibrarySummary> AddLibraryAsync(string? name, string path, LibraryKind kind, CancellationToken cancellation) =>
        SendCoreAsync<LibrarySummary>(HttpMethod.Post, "/api/v1/libraries", new CreateLibraryRequest(name, path, kind), true, cancellation);

    public Task<LibraryScanSummary> ScanAsync(Guid library, CancellationToken cancellation) =>
        SendCoreAsync<LibraryScanSummary>(HttpMethod.Post, $"/api/v1/libraries/{library}/scans", null, false, cancellation);

    public Task RemoveLibraryAsync(Guid library, CancellationToken cancellation) =>
        SendCoreAsync<AureliaServerApi.NoContent>(HttpMethod.Delete, $"/api/v1/libraries/{library}", null, true, cancellation);

    public Task<DeviceAuthorizationPreview> LookUpDeviceAsync(string code, CancellationToken cancellation) =>
        SendCoreAsync<DeviceAuthorizationPreview>(HttpMethod.Post, "/api/v1/server/device-pairings/lookup",
            new DeviceAuthorizationLookupRequest(new string([.. code.Where(char.IsAsciiDigit)])), false, cancellation);

    public Task AnswerDeviceAsync(Guid request, bool approve, CancellationToken cancellation) =>
        SendCoreAsync<AureliaServerApi.NoContent>(HttpMethod.Post, $"/api/v1/server/device-pairings/{request}/{(approve ? "approve" : "deny")}",
            null, true, cancellation);

    public Task<IReadOnlyList<DeviceSessionSummary>> DevicesAsync(CancellationToken cancellation) =>
        SendCoreAsync<IReadOnlyList<DeviceSessionSummary>>(HttpMethod.Get, "/api/v1/auth/sessions", null, false, cancellation);

    public Task RemoveDeviceAsync(Guid session, CancellationToken cancellation) =>
        SendCoreAsync<AureliaServerApi.NoContent>(HttpMethod.Delete, $"/api/v1/auth/sessions/{session}", null, true, cancellation);

    public Task<ServerOperationStatus> TryNetworkAsync(JsonObject settings, bool confirmDisconnect, CancellationToken cancellation) =>
        SendCoreAsync<ServerOperationStatus>(HttpMethod.Post, "/api/v1/server/operations/network",
            new JsonObject { ["settings"] = settings.DeepClone(), ["confirmRemoteAccessDisabled"] = confirmDisconnect }, true, cancellation);

    public Task ConfirmNetworkAsync(Guid operation, CancellationToken cancellation) =>
        SendCoreAsync<AureliaServerApi.NoContent>(HttpMethod.Post, $"/api/v1/server/operations/{operation}/confirm", null, false, cancellation);

    /// <summary>Any management request; the approval follows the server's rule for it.</summary>
    public Task<T> SendAsync<T>(HttpMethod method, string path, object? body, CancellationToken cancellation) =>
        SendCoreAsync<T>(method, path, body, AdministrationRules.RequiresApproval(method, path), cancellation);

    public Task<T> SendBytesAsync<T>(HttpMethod method, string path, byte[] content, string contentType, CancellationToken cancellation) =>
        SendRawAsync<T>(method, path, content, contentType, AdministrationRules.RequiresApproval(method, path), cancellation);

    private Task<T> SendCoreAsync<T>(HttpMethod method, string path, object? body, bool approve, CancellationToken cancellation) =>
        // The approval covers these exact bytes, so they are serialized once and sent as they are.
        SendRawAsync<T>(method, path, body is null ? null : JsonSerializer.SerializeToUtf8Bytes(body, body.GetType(), AureliaServerApi.Json),
            "application/json", approve, cancellation);

    private async Task<T> SendRawAsync<T>(HttpMethod method, string path, byte[]? content, string contentType, bool approve,
        CancellationToken cancellation)
    {
        var payload = content ?? [];
        using var request = new HttpRequestMessage(method, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", profileToken);
        if (content is not null)
        {
            request.Content = new ByteArrayContent(payload);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        }
        if (approve)
        {
            var grant = await SendCoreAsync<AdministrationApprovalResponse>(HttpMethod.Post, "/api/v1/server/approval",
                new AdministrationApprovalRequest($"{method.Method} {path}", Convert.ToHexStringLower(SHA256.HashData(payload))), false, cancellation);
            request.Headers.Add("X-Aurelia-Approval", grant.Token);
        }
        return await AureliaServerApi.SendRequestAsync<T>(Client, request, inspecting: false, cancellation);
    }
}
