using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace Aurelia.Linux.Core.Connection;

/// <summary>Sends Wake-on-LAN magic packets to wake a sleeping server.</summary>
public interface IWakeOnLan
{
    Task SendAsync(IReadOnlyList<string> hardwareAddresses, string? lastKnownHost, CancellationToken cancellation);
}

public sealed class NoWakeOnLan : IWakeOnLan
{
    public Task SendAsync(IReadOnlyList<string> hardwareAddresses, string? lastKnownHost, CancellationToken cancellation) => Task.CompletedTask;
}

/// <summary>
/// Like the Mac app: the magic packet (six 0xFF bytes, then the hardware address sixteen times)
/// goes over UDP to ports 9 and 7, to the broadcast address of every active IPv4 network, to
/// 255.255.255.255 and to the server's last known address. The hardware addresses come from the
/// server itself (server/info) and are remembered with the connection.
/// </summary>
public sealed class UdpWakeOnLan : IWakeOnLan
{
    private static readonly int[] Ports = [9, 7];

    public async Task SendAsync(IReadOnlyList<string> hardwareAddresses, string? lastKnownHost, CancellationToken cancellation)
    {
        var packets = hardwareAddresses.Select(MagicPacket).OfType<byte[]>().ToList();
        if (packets.Count == 0) return;
        var targets = BroadcastAddresses().Append(IPAddress.Broadcast).ToList();
        if (lastKnownHost is not null && IPAddress.TryParse(lastKnownHost.Trim('[', ']'), out var host) && host.AddressFamily == AddressFamily.InterNetwork)
            targets.Add(host);
        using var socket = new UdpClient(AddressFamily.InterNetwork) { EnableBroadcast = true };
        foreach (var packet in packets)
        {
            foreach (var target in targets.Distinct())
            {
                foreach (var port in Ports)
                {
                    try
                    {
                        await socket.SendAsync(packet, new IPEndPoint(target, port), cancellation);
                    }
                    catch (SocketException)
                    {
                        // One unreachable network must not stop the others.
                    }
                }
            }
        }
    }

    /// <summary>The 102-byte magic packet for "aa:bb:cc:dd:ee:ff" (or with dashes), or null when the address is not valid.</summary>
    public static byte[]? MagicPacket(string hardwareAddress)
    {
        var parts = hardwareAddress.Split(':', '-');
        if (parts.Length != 6) return null;
        var bytes = new byte[6];
        for (var index = 0; index < 6; index++)
        {
            if (parts[index].Length != 2 || !byte.TryParse(parts[index], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out bytes[index])) return null;
        }
        if (bytes.All(value => value == 0) || bytes.All(value => value == 0xFF)) return null;
        var packet = new byte[102];
        for (var index = 0; index < 6; index++) packet[index] = 0xFF;
        for (var repeat = 0; repeat < 16; repeat++) bytes.CopyTo(packet, 6 + repeat * 6);
        return packet;
    }

    private static IEnumerable<IPAddress> BroadcastAddresses()
    {
        foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (network.OperationalStatus != OperationalStatus.Up || network.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var unicast in network.GetIPProperties().UnicastAddresses)
            {
                if (unicast.Address.AddressFamily != AddressFamily.InterNetwork || unicast.IPv4Mask is null) continue;
                var address = unicast.Address.GetAddressBytes();
                var mask = unicast.IPv4Mask.GetAddressBytes();
                var broadcast = new byte[4];
                for (var index = 0; index < 4; index++) broadcast[index] = (byte)(address[index] | ~mask[index]);
                yield return new IPAddress(broadcast);
            }
        }
    }
}
