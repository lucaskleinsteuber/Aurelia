using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Connection;

/// <summary>A server found on the local network. Its name and id are hints until its key is checked.</summary>
public sealed record DiscoveredServer(Guid? ServerId, string Name, Uri Address);

/// <summary>A server read for the first time: its details and the key it presented.</summary>
public sealed record InspectedServer(Uri Address, ServerInfoResponse Info, string Fingerprint);

/// <summary>
/// This computer's paired connection to a server: the server's identity (id and key fingerprint),
/// its address and the device credential. Kept in the desktop keyring, never in a plain file.
/// </summary>
public sealed record StoredServer(
    Guid ServerId,
    string Name,
    Uri Address,
    string Fingerprint,
    string DeviceToken,
    Guid SessionId,
    DateTimeOffset ExpiresAt,
    UserSummary? User = null,
    bool LocallyManaged = false,
    IReadOnlyList<string>? WakeOnLanAddresses = null);

/// <summary>An open watching profile. It lives in memory only and ends after at most twelve hours.</summary>
public sealed record ProfileSession(UserSummary User, Guid SessionId, string Token, DateTimeOffset ExpiresAt)
{
    public bool CanManageMedia => User.Role is UserRole.Owner or UserRole.Admin;

    public bool IsOwner => User.Role == UserRole.Owner;
}
