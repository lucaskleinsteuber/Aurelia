using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;
using Aurelia.Contracts;

namespace Aurelia.Server.Services.Automation;

/// <summary>Something that happened, before it is shaped for each webhook.</summary>
public sealed record AutomationEvent(
    string Kind,
    Guid Id,
    DateTimeOffset OccurredAt,
    AutomationDeviceInfo? Device = null,
    AutomationProfileInfo? Profile = null,
    Guid? ProfileId = null,
    AutomationMedia? Media = null,
    int? Count = null);

/// <summary>
/// Hands events to the webhook dispatcher without waiting. The queue is bounded: if a target is
/// so slow that a thousand events pile up, the oldest are dropped rather than holding up playback.
/// </summary>
public sealed class AutomationEventBus
{
    private readonly Channel<AutomationEvent> events = Channel.CreateBounded<AutomationEvent>(
        new BoundedChannelOptions(1024) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });

    public ChannelReader<AutomationEvent> Reader => events.Reader;

    public void Publish(AutomationEvent value) => events.Writer.TryWrite(value);
}

/// <summary>
/// The signature every webhook carries, in the style of Stripe and GitHub:
/// <c>X-Aurelia-Signature: t=&lt;unix seconds&gt;,v1=&lt;hex HMAC-SHA256(secret, t + "." + body)&gt;</c>.
/// A receiver checks the HMAC and rejects old timestamps, so a recorded request can't be replayed.
/// </summary>
public static class WebhookSigner
{
    public const string SignatureHeader = "X-Aurelia-Signature";
    public const string EventHeader = "X-Aurelia-Event";
    public const string DeliveryHeader = "X-Aurelia-Delivery";

    public static string CreateSecret() => "whsec_" + Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
        .TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static string Sign(string secret, long timestamp, string body)
    {
        var mac = HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret),
            Encoding.UTF8.GetBytes(timestamp.ToString(System.Globalization.CultureInfo.InvariantCulture) + "." + body));
        return $"t={timestamp},v1={Convert.ToHexStringLower(mac)}";
    }
}

/// <summary>
/// Where a webhook may point. HTTPS goes anywhere; plain HTTP only to this computer or the home
/// network (Home Assistant usually runs at http://homeassistant.local:8123), because elsewhere it
/// would send what is playing unencrypted. Link-local addresses (cloud metadata services among
/// them) and multicast are never allowed, and the address is checked again when connecting, so a
/// name can't later point somewhere else.
/// </summary>
public static class WebhookTargetPolicy
{
    public static string? Problem(string url)
    {
        if (string.IsNullOrWhiteSpace(url) || url.Length > 2048) return "Enter the address the events go to.";
        if (!Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")
            || string.IsNullOrEmpty(uri.Host))
            return "The address must start with http:// or https://.";
        if (!string.IsNullOrEmpty(uri.UserInfo)) return "Put no user name or password in the address.";
        if (IPAddress.TryParse(uri.Host.Trim('[', ']'), out var address) && Forbidden(address))
            return "This address can't receive events.";
        if (uri.Scheme == "http" && !IsLocalName(uri.Host) && !(IPAddress.TryParse(uri.Host.Trim('[', ']'), out var local) && IsPrivate(local)))
            return "Use https:// for addresses outside your home network.";
        return null;
    }

    public static bool IsLocalName(string host) =>
        host.EndsWith(".local", StringComparison.OrdinalIgnoreCase) || host.EndsWith(".lan", StringComparison.OrdinalIgnoreCase)
        || host.EndsWith(".home.arpa", StringComparison.OrdinalIgnoreCase) || host.EndsWith(".fritz.box", StringComparison.OrdinalIgnoreCase)
        || string.Equals(host, "localhost", StringComparison.OrdinalIgnoreCase) || !host.Contains('.', StringComparison.Ordinal);

    public static bool Forbidden(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any) || address.Equals(IPAddress.Broadcast)) return true;
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            var bytes = address.GetAddressBytes();
            return (bytes[0] == 169 && bytes[1] == 254) || bytes[0] >= 224 || bytes[0] == 0;
        }
        return address.IsIPv6LinkLocal || address.IsIPv6Multicast;
    }

    public static bool IsPrivate(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address)) return true;
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            var bytes = address.GetAddressBytes();
            return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 100 && bytes[1] is >= 64 and <= 127);
        }
        return address.IsIPv6UniqueLocal || address.IsIPv6SiteLocal;
    }

    /// <summary>Checked for every connection the webhook client opens.</summary>
    public static async ValueTask<Stream> ConnectAsync(SocketsHttpConnectionContext context, CancellationToken cancellationToken)
    {
        var addresses = IPAddress.TryParse(context.DnsEndPoint.Host.Trim('[', ']'), out var literal)
            ? [literal] : await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, cancellationToken);
        var https = context.InitialRequestMessage.RequestUri?.Scheme == "https";
        var allowed = addresses.Where(address => !Forbidden(address) && (https || IsPrivate(address))).ToArray();
        if (allowed.Length == 0) throw new HttpRequestException("This address can't receive events.");
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            await socket.ConnectAsync(allowed, context.DnsEndPoint.Port, cancellationToken);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }
}
