using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace Aurelia.Server.Services;

/// <summary>
/// The hardware addresses a client needs to wake this server with a Wake-on-LAN packet: wired
/// and wireless cards that are up and have an address in a private network.
/// </summary>
public static class WakeOnLan
{
    public static IReadOnlyList<string> LocalAddresses()
    {
        try
        {
            return [.. NetworkInterface.GetAllNetworkInterfaces()
                .Where(network => network.OperationalStatus == OperationalStatus.Up
                    && network.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet
                        or NetworkInterfaceType.Wireless80211
                    && network.GetIPProperties().UnicastAddresses.Any(address => address.Address.AddressFamily == AddressFamily.InterNetwork
                        && !IPAddress.IsLoopback(address.Address) && ServerRequestGuard.NetworkAllowed(address.Address, null)))
                .Select(network => Format(network.GetPhysicalAddress()))
                .OfType<string>()
                .Distinct(StringComparer.Ordinal)
                .Take(8)];
        }
        catch (NetworkInformationException)
        {
            return [];
        }
    }

    internal static string? Format(PhysicalAddress address)
    {
        var bytes = address.GetAddressBytes();
        return bytes.Length != 6 || bytes.All(value => value == 0)
            ? null
            : string.Join(':', bytes.Select(value => value.ToString("x2", System.Globalization.CultureInfo.InvariantCulture)));
    }
}
