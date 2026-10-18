using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>
/// HTTPS calls to an Aurelia server. The first contact reads the server's key fingerprint; every
/// later connection only proceeds when the server presents exactly that key, so nobody in
/// between can pose as the server.
/// </summary>
public sealed class AureliaServerApi : IAureliaServerApi, IDisposable
{
    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
    };
    private static readonly string[] RequiredFeatures = ["device-authorization-v1", "library-state-v1"];
    private readonly Lock gate = new();
    private readonly Dictionary<string, HttpClient> pinnedClients = [];
    private bool disposed;

    public async Task<InspectedServer> InspectAsync(Uri address, CancellationToken cancellation)
    {
        if (!ServerAddress.IsValid(address))
            throw new AureliaApiException(0, "invalid_address", "Enter a server address such as 192.168.1.20.");
        var captured = new CapturedFingerprint();
        using var client = CreateClient(address, expectedFingerprint: null, captured);
        var info = await SendAsync<ServerInfoResponse>(client, HttpMethod.Get, "/api/v1/server/info", null, null, inspecting: true, cancellation);
        var fingerprint = captured.Value;
        if (!ServerIdentity.IsValidFingerprint(fingerprint) || !ReportsIdentity(info, fingerprint!, address))
            throw AureliaApiException.IdentityMismatch();
        if (!info.LanAccessEnabled && !ServerAddress.IsLoopback(address))
            throw new AureliaApiException(0, "network_access_off",
                "This server does not accept other devices yet. Turn on network access in Aurelia on the server.");
        if (!info.IsSetup)
            throw new AureliaApiException(409, "setup_required", "Finish setting up this server in Aurelia first.");
        var capabilities = await SendAsync<ClientCapabilitiesResponse>(client, HttpMethod.Get, "/api/v1/capabilities", null, null, inspecting: true, cancellation);
        if (capabilities.FormatVersion is < 1 or > 2 || !RequiredFeatures.All(feature => capabilities.Capabilities.Contains(feature)))
            throw new AureliaApiException(0, "unsupported_server", "This server is too old for this app. Update Aurelia on the server.");
        return new InspectedServer(address, info, fingerprint!.ToUpperInvariant());
    }

    public async Task<ServerInfoResponse> ServerInfoAsync(StoredConnection connection, CancellationToken cancellation)
    {
        var info = await SendAsync<ServerInfoResponse>(Pinned(connection.Address, connection.Fingerprint), HttpMethod.Get,
            "/api/v1/server/info", null, null, inspecting: false, cancellation);
        if (info.ServerId != connection.ServerId || !ReportsIdentity(info, connection.Fingerprint, connection.Address))
            throw AureliaApiException.IdentityMismatch();
        return info;
    }

    public async Task<DeviceAuthorizationStartResponse> StartPairingAsync(InspectedServer server, string deviceName, CancellationToken cancellation)
    {
        var name = deviceName.Trim();
        if (name.Length is 0 or > 128) name = "Windows PC";
        var started = await SendAsync<DeviceAuthorizationStartResponse>(Pinned(server.Address, server.Fingerprint), HttpMethod.Post,
            "/api/v1/auth/device-pairings", null, new DeviceAuthorizationStartRequest(name), inspecting: false, cancellation);
        if (started.Code is not { Length: 8 } || !started.Code.All(char.IsAsciiDigit) || !IsValidSecret(started.Secret)
            || started.PollIntervalSeconds is < 1 or > 300)
            throw AureliaApiException.InvalidResponse();
        return started;
    }

    public Task<DeviceAuthorizationStatusResponse> PairingStatusAsync(InspectedServer server, Guid id, string secret, CancellationToken cancellation) =>
        PairingOperationAsync(server.Address, server.Fingerprint, id, secret, "status", cancellation);

    public Task<DeviceAuthorizationStatusResponse> AcknowledgePairingAsync(Uri address, string fingerprint, Guid id, string secret, CancellationToken cancellation) =>
        PairingOperationAsync(address, fingerprint, id, secret, "ack", cancellation);

    public Task CancelPairingAsync(InspectedServer server, Guid id, string secret, CancellationToken cancellation) =>
        PairingOperationAsync(server.Address, server.Fingerprint, id, secret, "cancel", cancellation);

    public async Task<ProfilePickerResponse> ProfilesAsync(StoredConnection connection, CancellationToken cancellation) =>
        await SendAsync<ProfilePickerResponse>(Pinned(connection.Address, connection.Fingerprint), HttpMethod.Get,
            "/api/v1/profiles", connection.DeviceToken, null, inspecting: false, cancellation);

    public async Task<ProfileSessionResponse> UnlockProfileAsync(StoredConnection connection, Guid profileId, string? pin, CancellationToken cancellation)
    {
        if (!string.IsNullOrEmpty(pin) && !ProfilePin.IsValid(pin))
            throw new AureliaApiException(400, "invalid_profile_pin", "Enter a PIN with four to eight digits.");
        var session = await SendAsync<ProfileSessionResponse>(Pinned(connection.Address, connection.Fingerprint), HttpMethod.Post,
            $"/api/v1/profiles/{profileId}/unlock", connection.DeviceToken, new UnlockProfileRequest(string.IsNullOrEmpty(pin) ? null : pin),
            inspecting: false, cancellation);
        if (session.User.Id != profileId || !IsValidSecret(session.Token) || session.ExpiresAt <= DateTimeOffset.UtcNow)
            throw AureliaApiException.InvalidResponse();
        return session;
    }

    public Task EndProfileAsync(StoredConnection connection, ProfileSessionResponse session, CancellationToken cancellation) =>
        SendAsync<NoContent>(Pinned(connection.Address, connection.Fingerprint), HttpMethod.Post, "/api/v1/profile/end",
            session.Token, null, inspecting: false, cancellation);

    public Task DisconnectDeviceAsync(StoredConnection connection, CancellationToken cancellation) =>
        SendAsync<NoContent>(Pinned(connection.Address, connection.Fingerprint), HttpMethod.Delete, "/api/v1/device",
            connection.DeviceToken, null, inspecting: false, cancellation);

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
            foreach (var client in pinnedClients.Values) client.Dispose();
            pinnedClients.Clear();
        }
    }

    private async Task<DeviceAuthorizationStatusResponse> PairingOperationAsync(Uri address, string fingerprint, Guid id, string secret,
        string operation, CancellationToken cancellation)
    {
        if (!IsValidSecret(secret)) throw AureliaApiException.InvalidResponse();
        var status = await SendAsync<DeviceAuthorizationStatusResponse>(Pinned(address, fingerprint), HttpMethod.Post,
            $"/api/v1/auth/device-pairings/{id}/{operation}", null, new DeviceAuthorizationSecretRequest(secret), inspecting: false, cancellation);
        if (status.PollIntervalSeconds is < 1 or > 300) throw AureliaApiException.InvalidResponse();
        if (status.Authentication is { } credential
            && (status.State != DeviceAuthorizationState.Approved || !IsValidSecret(credential.Token) || credential.ExpiresAt <= DateTimeOffset.UtcNow))
            throw AureliaApiException.InvalidResponse();
        return status;
    }

    /// <summary>One long-lived client per trusted server, so connections and TLS handshakes are reused.</summary>
    internal HttpClient Pinned(Uri address, string fingerprint)
    {
        if (!ServerAddress.IsValid(address) || !ServerIdentity.IsValidFingerprint(fingerprint))
            throw AureliaApiException.IdentityMismatch();
        var key = address.GetLeftPart(UriPartial.Authority).ToLowerInvariant() + "|" + fingerprint.ToUpperInvariant();
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!pinnedClients.TryGetValue(key, out var client))
            {
                client = CreateClient(address, fingerprint, captured: null);
                pinnedClients[key] = client;
            }
            return client;
        }
    }

    internal static HttpClient CreateClient(Uri address, string? expectedFingerprint, CapturedFingerprint? captured,
        TimeSpan? timeout = null)
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            ConnectTimeout = TimeSpan.FromSeconds(8),
            PooledConnectionIdleTimeout = TimeSpan.FromSeconds(60),
            AutomaticDecompression = DecompressionMethods.Brotli | DecompressionMethods.GZip,
        };
        // The server's certificate is its own; trust comes from the pinned key, not from a
        // certificate authority, so name and chain errors are expected and ignored.
        handler.SslOptions.RemoteCertificateValidationCallback = (_, certificate, _, _) =>
        {
            if (certificate is not X509Certificate2 presented) return false;
            var fingerprint = ServerIdentity.Fingerprint(presented);
            if (fingerprint is null) return false;
            captured?.Set(fingerprint);
            return expectedFingerprint is null || ServerIdentity.Matches(expectedFingerprint, fingerprint);
        };
        return new HttpClient(handler) { BaseAddress = address, Timeout = timeout ?? TimeSpan.FromSeconds(20) };
    }

    internal static async Task<T> SendAsync<T>(HttpClient client, HttpMethod method, string path, string? token, object? body,
        bool inspecting, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(method, path);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (body is not null) request.Content = JsonContent.Create(body, body.GetType(), options: Json);
        HttpResponseMessage response;
        try
        {
            response = await client.SendAsync(request, cancellation);
        }
        catch (HttpRequestException error) when (error.HttpRequestError == HttpRequestError.SecureConnectionError)
        {
            throw inspecting
                ? new AureliaApiException(0, "not_aurelia", "This address does not answer like an Aurelia server.")
                : AureliaApiException.IdentityMismatch();
        }
        catch (HttpRequestException)
        {
            throw AureliaApiException.Unreachable();
        }
        catch (TaskCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw AureliaApiException.Unreachable();
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode) throw await ProblemAsync(response, cancellation);
            if (typeof(T) == typeof(NoContent)) return default!;
            if (typeof(T) == typeof(byte[])) return (T)(object)await response.Content.ReadAsByteArrayAsync(cancellation);
            try
            {
                return await response.Content.ReadFromJsonAsync<T>(Json, cancellation) ?? throw AureliaApiException.InvalidResponse();
            }
            catch (JsonException)
            {
                throw AureliaApiException.InvalidResponse();
            }
        }
    }

    private static async Task<AureliaApiException> ProblemAsync(HttpResponseMessage response, CancellationToken cancellation)
    {
        ApiProblem? problem = null;
        if (response.Content.Headers.ContentLength is null or <= 16_384)
        {
            try { problem = await response.Content.ReadFromJsonAsync<ApiProblem>(Json, cancellation); }
            catch (JsonException) { }
            catch (NotSupportedException) { }
        }
        var status = (int)response.StatusCode;
        var retryAfter = response.Headers.RetryAfter?.Delta;
        var message = problem?.Message is { Length: > 0 and <= 300 } text ? text : status switch
        {
            401 => "This computer's access ended. Connect to the server again.",
            403 => "The server did not allow this.",
            404 => "The server does not know this request.",
            429 => "The server is busy. Try again shortly.",
            _ => "The server could not complete the request.",
        };
        return new AureliaApiException(status, problem?.Code, message, retryAfter);
    }

    /// <summary>
    /// A server with network access reports the key it presents, and the two must match. A server
    /// on this computer without network access reports none; its key was still read from the
    /// TLS connection itself, which cannot be intercepted from the network.
    /// </summary>
    private static bool ReportsIdentity(ServerInfoResponse info, string presented, Uri address) =>
        info.PublicKeyFingerprint is null
            ? ServerAddress.IsLoopback(address)
            : ServerIdentity.Matches(info.PublicKeyFingerprint, presented);

    private static bool IsValidSecret(string? value) =>
        value is { Length: >= 32 and <= 256 } && !value.Any(char.IsWhiteSpace);

    internal sealed class CapturedFingerprint
    {
        private string? value;
        public string? Value => Volatile.Read(ref value);
        public void Set(string fingerprint) => Volatile.Write(ref value, fingerprint);
    }

    internal sealed record NoContent;
}

/// <summary>Profile PINs are four to eight digits on every Aurelia client.</summary>
public static class ProfilePin
{
    public static bool IsValid(string? pin) => pin is { Length: >= 4 and <= 8 } && pin.All(char.IsAsciiDigit);
}
