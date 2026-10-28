using System.Security.Cryptography;

namespace Aurelia.Server.Services;

/// <summary>
/// The browser app's files, built into the server from src/Aurelia.Server/WebApp. They are read
/// once at start; every answer carries an ETag, so a browser checks them cheaply on each visit
/// and gets the new files right after a server update.
/// </summary>
public sealed class WebAppAssets
{
    public const string Index = "index.html";
    private const string ResourcePrefix = "WebApp/";

    /// <summary>
    /// The page may only load its own scripts, styles, pictures and video and talk to this server:
    /// no inline code, no other origin, no framing. Video may also come from a blob: address, the
    /// page's own MediaSource for live converted titles.
    /// </summary>
    public const string ContentSecurityPolicy =
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; "
        + "connect-src 'self'; font-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; "
        + "frame-ancestors 'none'";

    public sealed record Asset(byte[] Content, string ContentType, string EntityTag);

    private readonly Dictionary<string, Lazy<Asset>> assets = new(StringComparer.Ordinal);

    public WebAppAssets()
    {
        var assembly = typeof(WebAppAssets).Assembly;
        foreach (var name in assembly.GetManifestResourceNames())
        {
            var path = name.Replace('\\', '/');
            if (!path.StartsWith(ResourcePrefix, StringComparison.Ordinal)) continue;
            // The compiled resource set is fixed. Load only the requested asset, once,
            // so opening HTML does not read/hash unused icons or JavaScript modules.
            assets[path[ResourcePrefix.Length..]] = new(() => ReadAsset(name, path), LazyThreadSafetyMode.ExecutionAndPublication);
        }
    }

    public Asset? Find(string path) => assets.GetValueOrDefault(path)?.Value;

    private static Asset ReadAsset(string name, string path)
    {
        using var stream = typeof(WebAppAssets).Assembly.GetManifestResourceStream(name)!;
        var content = new byte[checked((int)stream.Length)];
        stream.ReadExactly(content);
        var tag = "\"" + Convert.ToHexString(SHA256.HashData(content).AsSpan(0, 12)) + "\"";
        return new Asset(content, ContentType(path), tag);
    }

    private static string ContentType(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".html" => "text/html; charset=utf-8",
        ".js" or ".mjs" => "text/javascript; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".svg" => "image/svg+xml",
        ".png" => "image/png",
        ".webmanifest" => "application/manifest+json",
        _ => "application/octet-stream",
    };
}
