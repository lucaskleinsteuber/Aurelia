using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>A server whose identity was read but not yet trusted by the person.</summary>
public sealed record InspectedServer(Uri Address, ServerInfoResponse Info, string Fingerprint);

/// <summary>A pairing whose credential arrived but was not yet acknowledged to the server.</summary>
public sealed record PendingPairing(Guid Id, string Secret);

/// <summary>Everything needed to reconnect to a paired server; kept only in the secret store.</summary>
public sealed record StoredConnection(
    Guid ServerId,
    string ServerName,
    Uri Address,
    string Fingerprint,
    string DeviceToken,
    Guid DeviceSessionId,
    PendingPairing? PendingAcknowledgement = null,
    bool LocalHost = false);

/// <summary>An Aurelia server announced on the local network.</summary>
public sealed record DiscoveredServer(Guid? ServerId, string Name, Uri Address);

/// <summary>The server calls this app makes, so the connection flow can be tested without a network.</summary>
public interface IAureliaServerApi
{
    Task<InspectedServer> InspectAsync(Uri address, CancellationToken cancellation);
    Task<ServerInfoResponse> ServerInfoAsync(StoredConnection connection, CancellationToken cancellation);
    Task<DeviceAuthorizationStartResponse> StartPairingAsync(InspectedServer server, string deviceName, CancellationToken cancellation);
    Task<DeviceAuthorizationStatusResponse> PairingStatusAsync(InspectedServer server, Guid id, string secret, CancellationToken cancellation);
    Task<DeviceAuthorizationStatusResponse> AcknowledgePairingAsync(Uri address, string fingerprint, Guid id, string secret, CancellationToken cancellation);
    Task CancelPairingAsync(InspectedServer server, Guid id, string secret, CancellationToken cancellation);
    Task<ProfilePickerResponse> ProfilesAsync(StoredConnection connection, CancellationToken cancellation);
    /// <summary>The first owner's viewing PIN on a new server, confirmed with the Server Password.</summary>
    Task InitializeProfilesAsync(StoredConnection connection, string password, string pin, CancellationToken cancellation);
    Task<ProfileSessionResponse> UnlockProfileAsync(StoredConnection connection, Guid profileId, string? pin, CancellationToken cancellation);
    Task EndProfileAsync(StoredConnection connection, ProfileSessionResponse session, CancellationToken cancellation);
    Task DisconnectDeviceAsync(StoredConnection connection, CancellationToken cancellation);
}
