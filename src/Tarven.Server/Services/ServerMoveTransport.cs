using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;

namespace Tarven.Server.Services;

/// <summary>
/// How a new server reaches the old one during a move. The old server's certificate is self-signed,
/// so TLS accepts any certificate but reports the public key it saw: the move's proof and bundle key
/// are bound to it, so a machine in the middle can neither answer the claim nor read the bundle.
/// With <c>pinnedSpki</c> (the arrival report) only that key is accepted. Tests replace this class.
/// </summary>
public class ServerMoveTransport
{
    public virtual HttpClient Create(Action<byte[]> observedSpki, byte[]? pinnedSpki)
    {
        var handler = new SocketsHttpHandler
        {
            UseProxy = false,
            AllowAutoRedirect = false,
            ConnectTimeout = TimeSpan.FromSeconds(10),
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        };
        handler.SslOptions.RemoteCertificateValidationCallback = (_, certificate, _, _) =>
        {
            if (certificate is null) return false;
            var spki = ServerMoveCrypto.SpkiSha256(certificate);
            observedSpki(spki);
            return pinnedSpki is null || CryptographicOperations.FixedTimeEquals(spki, pinnedSpki);
        };
        return new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }

    /// <summary>"192.168.1.20", "server.local:43111" or "https://…" as an HTTPS base address; null when it isn't one.</summary>
    public static Uri? ParseAddress(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 512) return null;
        var text = value.Trim();
        if (!text.Contains("://", StringComparison.Ordinal)) text = "https://" + text;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var address) || address.Scheme != Uri.UriSchemeHttps
            || !string.IsNullOrEmpty(address.UserInfo) || address.AbsolutePath.Trim('/').Length > 0
            || !string.IsNullOrEmpty(address.Query) || !string.IsNullOrEmpty(address.Fragment)) return null;
        var port = address.IsDefaultPort && !value.TrimEnd('/').EndsWith(":443", StringComparison.Ordinal) ? ServerRuntimeOptions.DefaultLanHttpsPort : address.Port;
        return new UriBuilder(Uri.UriSchemeHttps, address.Host, port).Uri;
    }

    /// <summary>This server's HTTPS addresses on the home network, for devices and the other server.</summary>
    public static IReadOnlyList<string> LocalAddresses(int port)
    {
        var result = new List<string>();
        try
        {
            foreach (var address in NetworkInterface.GetAllNetworkInterfaces()
                .Where(network => network.OperationalStatus == OperationalStatus.Up && network.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                .SelectMany(network => network.GetIPProperties().UnicastAddresses).Select(unicast => unicast.Address)
                .Where(address => address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address)
                    && ServerRequestGuard.NetworkAllowed(address, null)))
                result.Add($"https://{address}:{port}");
        }
        catch (NetworkInformationException) { }
        if (!string.IsNullOrWhiteSpace(Environment.MachineName) && Uri.CheckHostName(Environment.MachineName + ".local") == UriHostNameType.Dns)
            result.Add($"https://{Environment.MachineName.ToLowerInvariant()}.local:{port}");
        return result.Distinct(StringComparer.Ordinal).Take(8).ToArray();
    }

    /// <summary>Addresses another server reported: at most eight HTTPS URLs without credentials.</summary>
    public static IReadOnlyList<string> ValidAddresses(IEnumerable<string>? values) => (values ?? [])
        .Where(value => value is { Length: > 0 and <= 512 } && Uri.TryCreate(value, UriKind.Absolute, out var uri)
            && uri.Scheme == Uri.UriSchemeHttps && string.IsNullOrEmpty(uri.UserInfo))
        .Distinct(StringComparer.Ordinal).Take(8).ToArray();
}
