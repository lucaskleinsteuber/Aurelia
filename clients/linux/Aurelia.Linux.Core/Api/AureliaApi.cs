using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Connection;

namespace Aurelia.Linux.Core.Api;

/// <summary>
/// Calls to an Aurelia server. The first contact reads the server's key fingerprint; every later
/// connection only proceeds when the server presents exactly that key, so nobody in between can
/// pose as the server. Each method names the endpoint it uses, as in docs/CLIENT_PROTOCOL.md.
/// </summary>
public sealed partial class AureliaApi : IDisposable
{
    /// <summary>The oldest servers this app works with report this capability (Aurelia 1.5.3 and later).</summary>
    public const string RequiredCapability = "library-state-v1";

    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(20);
    private readonly IServerTransport transport;
    private readonly Lock gate = new();
    private readonly Dictionary<string, HttpClient> pinnedClients = [];
    private bool disposed;

    public AureliaApi(IServerTransport transport) => this.transport = transport;

    /// <summary>GET /api/v1/server/info on first contact: reads the server and checks the key it presents.</summary>
    public async Task<InspectedServer> InspectAsync(Uri address, CancellationToken cancellation, TimeSpan? timeout = null)
    {
        if (!ServerAddress.IsValid(address))
            throw new AureliaApiException(0, "invalid_address", "Enter a server address such as 192.168.1.20.");
        var captured = new CapturedFingerprint();
        using var client = transport.CreateClient(address, expectedFingerprint: null, captured, timeout ?? DefaultTimeout);
        var info = await SendAsync<ServerInfoResponse>(client, HttpMethod.Get, "/api/v1/server/info", null, null, inspecting: true, cancellation);
        var fingerprint = captured.Value;
        if (!ServerIdentity.IsValidFingerprint(fingerprint) || !ReportsIdentity(info, fingerprint!, address)
            || !ShowsIdentity(info, fingerprint!))
            throw AureliaApiException.IdentityMismatch();
        if (!info.LanAccessEnabled && !ServerAddress.IsLoopback(address))
            throw new AureliaApiException(0, "network_access_off",
                "This server does not accept other devices yet. Turn on network access in Aurelia on the server.");
        if (!info.IsSetup)
            throw new AureliaApiException(409, "setup_required", "Finish setting up this server in Aurelia first.");
        if (info.Capabilities is not { } capabilities || !capabilities.Contains(RequiredCapability))
            throw new AureliaApiException(0, "server_update_required", "This server is too old for this app. Update Aurelia on the server.");
        return new InspectedServer(address, info, fingerprint!.ToUpperInvariant());
    }

    /// <summary>GET /api/v1/server/info over the pinned connection; the server's id and key must still match.</summary>
    public async Task<ServerInfoResponse> ServerInfoAsync(StoredServer server, CancellationToken cancellation, TimeSpan? timeout = null)
    {
        var client = timeout is { } limit ? transport.CreateClient(server.Address, server.Fingerprint, null, limit) : Pinned(server.Address, server.Fingerprint);
        try
        {
            var info = await SendAsync<ServerInfoResponse>(client, HttpMethod.Get, "/api/v1/server/info", null, null, inspecting: false, cancellation);
            if (info.ServerId != server.ServerId || !ReportsIdentity(info, server.Fingerprint, server.Address))
                throw AureliaApiException.IdentityMismatch();
            return info;
        }
        finally
        {
            if (timeout is not null) client.Dispose();
        }
    }

    /// <summary>POST /api/v1/auth/pair: redeems the eight-digit code an owner created on another device.</summary>
    public async Task<StoredServer> PairAsync(InspectedServer server, string code, string deviceName, CancellationToken cancellation)
    {
        var digits = new string(code.Where(char.IsAsciiDigit).ToArray());
        if (digits.Length != 8) throw new AureliaApiException(400, "invalid_pairing_code", "Enter the eight-digit pairing code.");
        var name = deviceName.Trim();
        if (name.Length is 0 or > 128) name = "Linux PC";
        var credential = await SendAsync<AuthenticationResponse>(Pinned(server.Address, server.Fingerprint), HttpMethod.Post,
            "/api/v1/auth/pair", null, new RedeemPairingCodeRequest(digits, name), inspecting: false, cancellation);
        if (!IsValidSecret(credential.Token)) throw AureliaApiException.InvalidResponse();
        return new StoredServer(server.Info.ServerId, server.Info.Name, server.Address, server.Fingerprint, credential.Token,
            credential.SessionId, credential.ExpiresAt, credential.User, WakeOnLanAddresses: server.Info.WakeOnLanAddresses,
            Hosting: server.Info.Hosting);
    }

    /// <summary>GET /api/v1/profiles with the device credential.</summary>
    public async Task<ProfilePickerResponse> ProfilesAsync(StoredServer server, CancellationToken cancellation)
    {
        var response = await SendAsync<ProfilePickerResponse>(Pinned(server.Address, server.Fingerprint), HttpMethod.Get,
            "/api/v1/profiles", server.DeviceToken, null, inspecting: false, cancellation);
        if (response.FormatVersion is < 1 or > 2) throw new AureliaApiException(0, "unsupported_server", "This server is newer than this app. Update Aurelia.");
        return response;
    }

    /// <summary>POST /api/v1/profiles/initialize: the server password and the owner's new PIN.</summary>
    public Task InitializeProfilesAsync(StoredServer server, string password, string pin, CancellationToken cancellation)
    {
        if (!ProfilePin.IsValid(pin)) throw new AureliaApiException(400, "invalid_profile_pin", "Enter a PIN with four to eight digits.");
        return SendAsync<NoContent>(Pinned(server.Address, server.Fingerprint), HttpMethod.Post, "/api/v1/profiles/initialize",
            server.DeviceToken, new InitializeProfilesRequest(password, pin), inspecting: false, cancellation);
    }

    /// <summary>POST /api/v1/profiles/{id}/unlock: opens a watching profile, with its PIN when it has one.</summary>
    public async Task<ProfileSession> UnlockProfileAsync(StoredServer server, Guid profileId, string? pin, CancellationToken cancellation)
    {
        if (!string.IsNullOrEmpty(pin) && !ProfilePin.IsValid(pin))
            throw new AureliaApiException(400, "invalid_profile_pin", "Enter a PIN with four to eight digits.");
        var session = await SendAsync<ProfileSessionResponse>(Pinned(server.Address, server.Fingerprint), HttpMethod.Post,
            $"/api/v1/profiles/{profileId}/unlock", server.DeviceToken, new UnlockProfileRequest(string.IsNullOrEmpty(pin) ? null : pin),
            inspecting: false, cancellation);
        if (session.User.Id != profileId || !IsValidSecret(session.Token)) throw AureliaApiException.InvalidResponse();
        return new ProfileSession(session.User, session.SessionId, session.Token, session.ExpiresAt);
    }

    /// <summary>POST /api/v1/profile/end: closes the watching profile on the server.</summary>
    public Task EndProfileAsync(StoredServer server, ProfileSession session, CancellationToken cancellation) =>
        SendAsync<NoContent>(Pinned(server.Address, server.Fingerprint), HttpMethod.Post, "/api/v1/profile/end",
            session.Token, null, inspecting: false, cancellation);

    /// <summary>PUT /api/v1/profile/pin-protection: changes, turns on or removes the open profile's own PIN.</summary>
    public Task<UserSummary> UpdateOwnPinAsync(StoredServer server, ProfileSession session, UpdateOwnPinProtectionRequest request, CancellationToken cancellation)
    {
        if (request.Pin is { } pin && !ProfilePin.IsValid(pin)) throw new AureliaApiException(400, "invalid_profile_pin", "Enter a PIN with four to eight digits.");
        return SendAsync<UserSummary>(Pinned(server.Address, server.Fingerprint), HttpMethod.Put, "/api/v1/profile/pin-protection",
            session.Token, request, inspecting: false, cancellation);
    }

    /// <summary>GET /api/v1/profiles/{id}/picture: a profile's own photo, shown in "Who's watching?".</summary>
    public Task<byte[]> ProfilePhotoAsync(StoredServer server, Guid profileId, long revision, CancellationToken cancellation) =>
        SendAsync<byte[]>(Pinned(server.Address, server.Fingerprint), HttpMethod.Get, $"/api/v1/profiles/{profileId}/picture?rev={revision}",
            server.DeviceToken, null, inspecting: false, cancellation);

    /// <summary>PUT /api/v1/profile/name: the open profile's shown name. The owner keeps signing in with the old name.</summary>
    public Task<UserSummary> RenameOwnProfileAsync(StoredServer server, ProfileSession session, string name, CancellationToken cancellation) =>
        SendAsync<UserSummary>(Pinned(server.Address, server.Fingerprint), HttpMethod.Put, "/api/v1/profile/name",
            session.Token, new UpdateProfileNameRequest(name), inspecting: false, cancellation);

    /// <summary>PUT /api/v1/profile/picture: a built-in picture for the open profile, or null for its initial.</summary>
    public Task<UserSummary> SetOwnPictureAsync(StoredServer server, ProfileSession session, string? builtin, CancellationToken cancellation) =>
        SendAsync<UserSummary>(Pinned(server.Address, server.Fingerprint), HttpMethod.Put, "/api/v1/profile/picture",
            session.Token, new UpdateProfilePictureRequest(builtin), inspecting: false, cancellation);

    /// <summary>PUT /api/v1/profile/picture/photo: an own photo; the server crops and shrinks it.</summary>
    public async Task<UserSummary> UploadOwnPhotoAsync(StoredServer server, ProfileSession session, byte[] image, CancellationToken cancellation)
    {
        if (image.Length > ProfilePictures.MaximumUploadBytes) throw new AureliaApiException(413, "profile_photo_too_large", "Choose a photo no larger than 8 MB.");
        using var request = new HttpRequestMessage(HttpMethod.Put, "/api/v1/profile/picture/photo") { Content = new ByteArrayContent(image) };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", session.Token);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        return await SendRequestAsync<UserSummary>(Pinned(server.Address, server.Fingerprint), request, inspecting: false, cancellation);
    }

    /// <summary>Closes idle connections, so a resting server is not kept awake.</summary>
    public void DropConnections()
    {
        lock (gate)
        {
            foreach (var client in pinnedClients.Values) client.Dispose();
            pinnedClients.Clear();
        }
    }

    /// <summary>DELETE /api/v1/device: removes this computer's pairing on the server.</summary>
    public Task DisconnectDeviceAsync(StoredServer server, CancellationToken cancellation) =>
        SendAsync<NoContent>(Pinned(server.Address, server.Fingerprint), HttpMethod.Delete, "/api/v1/device",
            server.DeviceToken, null, inspecting: false, cancellation);

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
            foreach (var client in pinnedClients.Values) client.Dispose();
            pinnedClients.Clear();
        }
    }

    /// <summary>One long-lived client per trusted server, so connections and TLS handshakes are reused.</summary>
    internal HttpClient Pinned(Uri address, string fingerprint)
    {
        if (!ServerAddress.IsValid(address) || !ServerIdentity.IsValidFingerprint(fingerprint)) throw AureliaApiException.IdentityMismatch();
        var key = address.GetLeftPart(UriPartial.Authority).ToLowerInvariant() + "|" + fingerprint.ToUpperInvariant();
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!pinnedClients.TryGetValue(key, out var client))
            {
                client = transport.CreateClient(address, fingerprint, captured: null, DefaultTimeout);
                pinnedClients[key] = client;
            }
            return client;
        }
    }

    internal static async Task<T> SendAsync<T>(HttpClient client, HttpMethod method, string path, string? token, object? body,
        bool inspecting, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(method, path);
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (body is not null) request.Content = JsonContent.Create(body, body.GetType(), options: AureliaJson.Options);
        return await SendRequestAsync<T>(client, request, inspecting, cancellation);
    }

    /// <summary>Sends a prepared request and turns the answer, or the server's problem, into a result.</summary>
    internal static async Task<T> SendRequestAsync<T>(HttpClient client, HttpRequestMessage request, bool inspecting, CancellationToken cancellation)
    {
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        HttpResponseMessage response;
        try
        {
            response = await client.SendAsync(request, cancellation);
        }
        catch (HttpRequestException error) when (error.HttpRequestError == HttpRequestError.SecureConnectionError
            && (inspecting || error.InnerException is System.Security.Authentication.AuthenticationException))
        {
            // Only a certificate the key check rejected is an identity problem; a handshake cut
            // short by a restarting server or the network is reported as unreachable below.
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
                return await response.Content.ReadFromJsonAsync<T>(AureliaJson.Options, cancellation) ?? throw AureliaApiException.InvalidResponse();
            }
            catch (JsonException)
            {
                throw AureliaApiException.InvalidResponse();
            }
        }
    }

    internal static async Task<AureliaApiException> ProblemAsync(HttpResponseMessage response, CancellationToken cancellation)
    {
        ApiProblem? problem = null;
        if (response.Content.Headers.ContentLength is null or <= 16_384)
        {
            try
            {
                problem = await response.Content.ReadFromJsonAsync<ApiProblem>(AureliaJson.Options, cancellation);
            }
            catch (Exception exception) when (exception is JsonException or NotSupportedException)
            {
            }
        }
        var status = (int)response.StatusCode;
        var retryAfter = response.Headers.RetryAfter is { } header
            ? header.Delta ?? (header.Date is { } date ? date - DateTimeOffset.UtcNow : null)
            : null;
        if (retryAfter is { } wait) retryAfter = TimeSpan.FromSeconds(Math.Clamp(wait.TotalSeconds, 0, 300));
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
    /// on this computer without network access reports none; its key was still read from the TLS
    /// connection itself, which cannot be intercepted from the network.
    /// </summary>
    private static bool ReportsIdentity(ServerInfoResponse info, string presented, Uri address) =>
        info.PublicKeyFingerprint is null
            ? ServerAddress.IsLoopback(address)
            : ServerIdentity.Matches(info.PublicKeyFingerprint, presented);

    /// <summary>A display fingerprint the server reports must belong to the key it presented.</summary>
    internal static bool ShowsIdentity(ServerInfoResponse info, string presented) =>
        info.DisplayFingerprint is not { Length: > 0 } shown
        || string.Equals(shown.Trim(), ServerIdentity.Display(presented), StringComparison.OrdinalIgnoreCase);

    private static bool IsValidSecret(string? value) => value is { Length: >= 32 and <= 512 } && !value.Any(char.IsWhiteSpace);

    internal static AureliaApiException Timeout() => AureliaApiException.Unreachable();

    internal sealed record NoContent;
}
