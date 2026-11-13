using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Library;

namespace Aurelia.Linux.Core.Management;

/// <summary>
/// Owner and administrator requests, sent the way the Mac app's AdministrationRequestExecutor
/// does: every request goes out as it is. Only when the server answers "approval_required" does
/// the client ask for a one-use approval for exactly that request (its method, path and the SHA-256
/// of its exact bytes) and send it again. When management is locked, <paramref name="askPassword"/>
/// asks for the Server Password, management is unlocked for ten minutes and the request is retried.
/// When the owner requires Face ID or Touch ID for administrators, the password is refused
/// ("passkey_required") and <paramref name="confirmElsewhere"/> asks an iPhone, iPad or Mac to confirm.
/// </summary>
public sealed partial class ManagementClient(AureliaApi api, LibraryClient library, Func<string, Task<string?>> askPassword,
    Func<ManagementClient, Task<bool>>? confirmElsewhere = null)
{
    public LibraryClient Library { get; } = library;

    private HttpClient Pinned => api.Pinned(Library.Server.Address, Library.Server.Fingerprint);

    public Task<T> GetAsync<T>(string path, CancellationToken cancellation = default) => SendAsync<T>(HttpMethod.Get, path, null, cancellation);

    public async Task<T> SendAsync<T>(HttpMethod method, string path, object? body, CancellationToken cancellation = default)
    {
        var bytes = body is null ? null : JsonSerializer.SerializeToUtf8Bytes(body, body.GetType(), AureliaJson.Options);
        return await SendBytesAsync<T>(method, path, bytes, "application/json", cancellation);
    }

    public async Task<T> SendBytesAsync<T>(HttpMethod method, string path, byte[]? bytes, string contentType, CancellationToken cancellation = default)
    {
        string? approval = null;
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                using var request = Request(method, path, bytes, contentType, approval);
                if (typeof(T) != typeof(JsonNode) && typeof(T) != typeof(JsonObject))
                    return await AureliaApi.SendRequestAsync<T>(Pinned, request, inspecting: false, cancellation);
                // Untyped answers may be empty (204 No Content).
                var raw = await AureliaApi.SendRequestAsync<byte[]>(Pinned, request, inspecting: false, cancellation);
                return raw.Length == 0 ? default! : ParseNode(raw) is T node ? node : throw AureliaApiException.InvalidResponse();
            }
            catch (AureliaApiException error) when (attempt < 3 && error.Status == 403 && error.Code == "approval_required")
            {
                approval = await ApproveAsync(method, path, bytes ?? [], cancellation);
            }
            catch (AureliaApiException error) when (attempt < 3 && error.Status == 403 && error.Code == "management_locked")
            {
                await UnlockAsync(error.Message, cancellation);
            }
        }
    }

    /// <summary>A file the server sends (diagnostics, an exported backup), as bytes.</summary>
    public async Task<byte[]> DownloadAsync(string path, CancellationToken cancellation = default)
    {
        using var request = Request(HttpMethod.Get, path, null, null, null);
        request.Headers.Accept.Clear();
        using var response = await Pinned.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
        if (!response.IsSuccessStatusCode) throw await AureliaApi.ProblemAsync(response, cancellation);
        return await response.Content.ReadAsByteArrayAsync(cancellation);
    }

    /// <summary>POST /api/v1/management/unlock with the Server Password; it lasts ten minutes.</summary>
    public async Task UnlockAsync(string reason, CancellationToken cancellation = default)
    {
        var password = await askPassword(reason) ?? throw new OperationCanceledException("The Server Password was not entered.");
        try
        {
            await AureliaApi.SendAsync<ManagementUnlockResponse>(Pinned, HttpMethod.Post, "/api/v1/management/unlock", Library.Profile.Token,
                new UnlockManagementRequest(password), false, cancellation);
        }
        catch (AureliaApiException error) when (error.Code == "passkey_required" && confirmElsewhere is not null)
        {
            if (!await confirmElsewhere(this)) throw new OperationCanceledException("The unlock was not confirmed on another device.");
        }
    }

    public static string PayloadHash(ReadOnlySpan<byte> payload) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(payload)).ToLowerInvariant();

    private async Task<string> ApproveAsync(HttpMethod method, string path, byte[] bytes, CancellationToken cancellation)
    {
        var request = new AdministrationApprovalRequest(method.Method + " " + path, PayloadHash(bytes));
        var approval = await SendAsync<AdministrationApprovalResponse>(HttpMethod.Post, "/api/v1/management/approval", request, cancellation);
        return approval.Token;
    }

    private HttpRequestMessage Request(HttpMethod method, string path, byte[]? bytes, string? contentType, string? approval)
    {
        var request = new HttpRequestMessage(method, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Library.Profile.Token);
        if (approval is not null) request.Headers.Add("X-Aurelia-Approval", approval);
        if (bytes is not null)
        {
            request.Content = new ByteArrayContent(bytes);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue(contentType ?? "application/json");
        }
        return request;
    }

    private static JsonNode? ParseNode(byte[] raw)
    {
        try
        {
            return JsonNode.Parse(raw);
        }
        catch (JsonException)
        {
            throw AureliaApiException.InvalidResponse();
        }
    }
}
