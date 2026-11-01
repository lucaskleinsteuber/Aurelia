namespace Aurelia.Linux.Core.Api;

/// <summary>Server addresses as people type them: "192.168.1.20" becomes https://192.168.1.20:43111.</summary>
public static class ServerAddress
{
    public const int DefaultPort = 43111;

    public static bool TryNormalize(string? input, out Uri address)
    {
        address = null!;
        var trimmed = input?.Trim() ?? "";
        if (trimmed.Length is 0 or > 255) return false;
        var text = trimmed.Contains("://", StringComparison.Ordinal) ? trimmed : "https://" + trimmed;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var parsed)) return false;
        var builder = new UriBuilder(parsed);
        if (!string.Equals(builder.Scheme, "https", StringComparison.OrdinalIgnoreCase)) return false;
        builder.Scheme = "https";
        // A typed address without a port means Aurelia's own port, not 443.
        if (!HasExplicitPort(text)) builder.Port = DefaultPort;
        if (builder.Path is "/" or "") builder.Path = "";
        var candidate = builder.Uri;
        if (!IsValid(candidate)) return false;
        address = candidate;
        return true;
    }

    public static bool IsValid(Uri address) =>
        address.IsAbsoluteUri
        && address.Scheme == Uri.UriSchemeHttps
        && address.Host.Length > 0
        && string.IsNullOrEmpty(address.UserInfo)
        && string.IsNullOrEmpty(address.Query)
        && string.IsNullOrEmpty(address.Fragment)
        && address.AbsolutePath == "/"
        && address.Port is > 0 and <= 65535;

    /// <summary>A server on this computer needs no network access; every other one does.</summary>
    public static bool IsLoopback(Uri address) => address.IsLoopback || address.Host is "127.0.0.1" or "[::1]" or "::1";

    private static bool HasExplicitPort(string text)
    {
        var authority = text[(text.IndexOf("://", StringComparison.Ordinal) + 3)..];
        var end = authority.IndexOfAny(['/', '?', '#']);
        if (end >= 0) authority = authority[..end];
        if (authority.StartsWith('[')) return authority.IndexOf("]:", StringComparison.Ordinal) > 0;
        return authority.Contains(':', StringComparison.Ordinal);
    }
}
