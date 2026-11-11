using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace Aurelia.Server.Services;

/// <summary>
/// The browser app's files, built into the server from src/Aurelia.Server/WebApp. They are read
/// once on first request for each asset; every answer carries an ETag, so a browser checks them cheaply on each visit
/// and gets the new files right after a server update.
/// The page itself loads the files under <c>/web/v/&lt;version&gt;/</c>, a name that changes with
/// their content, so a browser keeps them for good and fetches them all at once instead of asking
/// again on every visit. Text files are also kept compressed (Brotli and gzip), made once on first use.
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

    public const string VersionedPrefix = "/web/v/";

    public sealed record Asset(byte[] Content, string ContentType, string EntityTag)
    {
        private readonly Lazy<byte[]?> brotli = new(() => Compress(Content, ContentType, static output => new BrotliStream(output, CompressionLevel.SmallestSize, leaveOpen: true)));
        private readonly Lazy<byte[]?> gzip = new(() => Compress(Content, ContentType, static output => new GZipStream(output, CompressionLevel.SmallestSize, leaveOpen: true)));

        /// <summary>Whether this file has compressed forms worth sending (text of some size).</summary>
        public bool Compressible => IsText(ContentType) && Content.Length >= 1024;

        /// <summary>The file in the given encoding ("br" or "gzip"), or null when it isn't smaller.</summary>
        public byte[]? Encoded(string encoding) => encoding switch
        {
            "br" => brotli.Value,
            "gzip" => gzip.Value,
            _ => null,
        };
    }

    private readonly Dictionary<string, Lazy<Asset>> assets = new(StringComparer.Ordinal);
    private readonly Lazy<string> version;
    private readonly Lazy<Asset> page;

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
        version = new(ComputeVersion, LazyThreadSafetyMode.ExecutionAndPublication);
        page = new(BuildPage, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public Asset? Find(string path) => assets.GetValueOrDefault(path)?.Value;

    /// <summary>A short name for this exact set of files; it changes whenever any file changes.</summary>
    public string Version => version.Value;

    /// <summary>
    /// index.html as the browser receives it: its stylesheet and script come from the versioned
    /// folder, and every module is announced up front so the browser loads them side by side.
    /// </summary>
    public Asset Page => page.Value;

    private string ComputeVersion()
    {
        var builder = new StringBuilder();
        foreach (var path in assets.Keys.Order(StringComparer.Ordinal))
            builder.Append(path).Append('\n').Append(assets[path].Value.EntityTag).Append('\n');
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(builder.ToString())).AsSpan(0, 8)).ToLowerInvariant();
    }

    private Asset BuildPage()
    {
        var index = Find(Index) ?? throw new InvalidOperationException("The browser app has no index.html.");
        var prefix = VersionedPrefix + Version + "/";
        var modules = assets.Keys
            .Where(path => path.StartsWith("js/", StringComparison.Ordinal) && path.EndsWith(".js", StringComparison.Ordinal))
            .Order(StringComparer.Ordinal)
            .Select(path => $"  <link rel=\"modulepreload\" href=\"{prefix}{path}\">\n");
        var html = Encoding.UTF8.GetString(index.Content)
            .Replace("href=\"/web/app.css\"", $"href=\"{prefix}app.css\"", StringComparison.Ordinal)
            .Replace("src=\"/web/js/app.js\"", $"src=\"{prefix}js/app.js\"", StringComparison.Ordinal)
            .Replace("</head>", string.Concat(modules) + "</head>", StringComparison.Ordinal);
        var content = Encoding.UTF8.GetBytes(html);
        return new Asset(content, index.ContentType, "\"" + Convert.ToHexString(SHA256.HashData(content).AsSpan(0, 12)) + "\"");
    }

    private static bool IsText(string contentType) =>
        contentType.StartsWith("text/", StringComparison.Ordinal)
        || contentType.StartsWith("image/svg+xml", StringComparison.Ordinal)
        || contentType.StartsWith("application/manifest+json", StringComparison.Ordinal);

    private static byte[]? Compress(byte[] content, string contentType, Func<Stream, Stream> encoder)
    {
        if (!IsText(contentType) || content.Length < 1024) return null;
        using var output = new MemoryStream();
        using (var stream = encoder(output)) stream.Write(content);
        return output.Length < content.Length ? output.ToArray() : null;
    }

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
