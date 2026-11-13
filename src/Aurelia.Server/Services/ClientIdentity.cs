using System.Net;

namespace Aurelia.Server.Services;

/// <summary>
/// Who is asking, as far as the server can tell: the app's own random installation identifier
/// (<c>X-Aurelia-Installation</c>, or the browser's HttpOnly <c>aurelia_installation</c> cookie),
/// the kind of app and its version (<c>X-Aurelia-Client: ios/2.11.0</c>, or a short summary of a
/// browser's User-Agent) and the network address. It names a device in the security log and lets
/// the owner block it; it proves nothing, so codes and the Server Password stay the protection.
/// </summary>
public sealed record ClientIdentity(string? InstallationId, string? Platform, string? Version, string? IpAddress)
{
    public const string InstallationHeader = "X-Aurelia-Installation";
    public const string ClientHeader = "X-Aurelia-Client";
    public const string InstallationCookie = "aurelia_installation";
    private const string InstallationItem = "Aurelia.Installation";

    /// <summary>
    /// Gives a browser its installation identifier in an HttpOnly cookie (scripts never see it),
    /// once, when it first talks to the browser app's sign-in endpoints. It lasts ten years.
    /// </summary>
    public static void EnsureBrowserInstallation(HttpContext context)
    {
        if (Installation(context.Request.Cookies[InstallationCookie]) is not null) return;
        var created = Guid.NewGuid().ToString("N");
        context.Items[InstallationItem] = created;
        Authentication.WebCookies.Set(context, InstallationCookie, created, DateTimeOffset.UtcNow.AddYears(10));
    }

    public static ClientIdentity From(HttpContext? context)
    {
        if (context is null) return new(null, null, null, null);
        var installation = Installation(context.Request.Headers[InstallationHeader].ToString())
            ?? Installation(context.Items[InstallationItem] as string)
            ?? Installation(context.Request.Cookies[InstallationCookie]);
        var (platform, version) = Client(context.Request.Headers[ClientHeader].ToString());
        platform ??= BrowserPlatform(context.Request.Headers.UserAgent.ToString());
        return new(installation, platform, version, Address(context.Connection.RemoteIpAddress));
    }

    /// <summary>A GUID in its lowercase 32-digit form, or null for anything else.</summary>
    public static string? Installation(string? value) =>
        Guid.TryParse(value?.Trim(), out var id) && id != Guid.Empty ? id.ToString("N") : null;

    /// <summary>"ios/2.11.0" becomes ("iPhone or iPad", "2.11.0"); anything unknown is ignored.</summary>
    public static (string? Platform, string? Version) Client(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 64) return (null, null);
        var parts = value.Trim().Split('/', 2);
        var platform = parts[0].ToLowerInvariant() switch
        {
            "ios" => "iPhone or iPad",
            "ipados" => "iPad",
            "macos" => "Mac",
            "linux" => "Linux",
            "tvos" => "Apple TV",
            "web" => "Browser",
            _ => null,
        };
        if (platform is null) return (null, null);
        var version = parts.Length == 2 && parts[1].Length is > 0 and <= 32
            && parts[1].All(character => char.IsAsciiDigit(character) || character is '.' or '-' or '(' or ')' or ' ')
            ? parts[1] : null;
        return (platform, version);
    }

    /// <summary>"Browser · Safari on iPhone" from a User-Agent, or null when it says nothing useful.</summary>
    public static string? BrowserPlatform(string? userAgent)
    {
        if (string.IsNullOrWhiteSpace(userAgent) || !userAgent.Contains("Mozilla/", StringComparison.Ordinal)) return null;
        var browser = userAgent.Contains("Edg/", StringComparison.Ordinal) ? "Edge"
            : userAgent.Contains("Firefox/", StringComparison.Ordinal) ? "Firefox"
            : userAgent.Contains("Chrome/", StringComparison.Ordinal) || userAgent.Contains("CriOS/", StringComparison.Ordinal) ? "Chrome"
            : userAgent.Contains("Safari/", StringComparison.Ordinal) ? "Safari"
            : "a browser";
        var system = userAgent.Contains("iPhone", StringComparison.Ordinal) ? "iPhone"
            : userAgent.Contains("iPad", StringComparison.Ordinal) ? "iPad"
            : userAgent.Contains("Android", StringComparison.Ordinal) ? "Android"
            : userAgent.Contains("Macintosh", StringComparison.Ordinal) ? "Mac"
            : userAgent.Contains("Windows", StringComparison.Ordinal) ? "Windows"
            : userAgent.Contains("CrOS", StringComparison.Ordinal) ? "ChromeOS"
            : userAgent.Contains("Linux", StringComparison.Ordinal) ? "Linux"
            : null;
        return system is null ? $"Browser · {browser}" : $"Browser · {browser} on {system}";
    }

    public static string? Address(IPAddress? address)
    {
        if (address is null) return null;
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        return address.ToString();
    }

    public static bool IsLoopback(HttpContext context) =>
        context.Connection.RemoteIpAddress is { } address
        && IPAddress.IsLoopback(address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address);
}
