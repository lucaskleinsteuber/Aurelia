using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Management;

/// <summary>
/// Where to open Aurelia in a web browser: the server serves the browser app itself, so this is
/// the server's own HTTPS address as other devices at home reach it.
/// </summary>
public sealed record BrowserAddress(Uri Url, bool ThisComputerOnly)
{
    /// <param name="serverAddress">The address this computer uses for the server.</param>
    /// <param name="lanAccessEnabled">The home-network access of a server running on this computer.</param>
    public static BrowserAddress Resolve(Uri serverAddress, bool? lanAccessEnabled, int? lanPort, Func<string?>? localIPv4 = null)
    {
        if (!ServerAddress.IsLoopback(serverAddress))
        {
            return new BrowserAddress(new UriBuilder("https", serverAddress.Host, serverAddress.Port).Uri, false);
        }
        if (lanAccessEnabled == true && (localIPv4 ?? PrivateIPv4)() is { } address)
        {
            return new BrowserAddress(new UriBuilder("https", address, lanPort ?? 43111).Uri, false);
        }
        return new BrowserAddress(new UriBuilder(serverAddress.Scheme, serverAddress.Host, serverAddress.Port).Uri, true);
    }

    /// <summary>This computer's address in the home network (10/8, 172.16/12 or 192.168/16).</summary>
    public static string? PrivateIPv4() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(card => card.OperationalStatus == OperationalStatus.Up && card.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .OrderBy(card => card.NetworkInterfaceType is NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.Ethernet ? 0 : 1)
            .SelectMany(card => card.GetIPProperties().UnicastAddresses)
            .Select(unicast => unicast.Address)
            .FirstOrDefault(address => address.AddressFamily == AddressFamily.InterNetwork && IsPrivate(address))?.ToString();

    private static bool IsPrivate(IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) || (bytes[0] == 192 && bytes[1] == 168);
    }
}
