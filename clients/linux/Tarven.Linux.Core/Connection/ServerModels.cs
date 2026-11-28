using Tarven.Contracts;

namespace Tarven.Linux.Core.Connection;

/// <summary>A server found on the local network. Its name and id are hints until its key is checked.</summary>
public sealed record DiscoveredServer(Guid? ServerId, string Name, Uri Address);

/// <summary>A saved server's public info, and where it went when it moved to another computer.</summary>
public sealed record ServerProbe(ServerInfoResponse Info, Tarven.Linux.Core.Moving.MovedServer? Moved);

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
    IReadOnlyList<string>? WakeOnLanAddresses = null,
    string? Hosting = null,
    bool PowerSavingEnabled = false)
{
    /// <summary>"macApp" or "linuxApp": the Tarven app hosts it on a desktop or laptop, which its owner starts, never Wake-on-LAN.</summary>
    public bool HostedByApp => Hosting is "macApp" or "linuxApp";
}

/// <summary>An open watching profile. It lives in memory only and ends after at most twelve hours.</summary>
public sealed record ProfileSession(UserSummary User, Guid SessionId, string Token, DateTimeOffset ExpiresAt)
{
    public bool CanManageMedia => User.Role is UserRole.Owner or UserRole.Admin;

    public bool IsOwner => User.Role == UserRole.Owner;
}
