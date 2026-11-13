using System.Net;
using System.Security.Cryptography.X509Certificates;

namespace Aurelia.Linux.Core.Api;

/// <summary>Remembers the key fingerprint a server presented during the TLS handshake.</summary>
public sealed class CapturedFingerprint
{
    private string? value;

    public string? Value => Volatile.Read(ref value);

    public void Set(string fingerprint) => Volatile.Write(ref value, fingerprint);
}

/// <summary>Creates the HTTP clients for talking to servers; tests replace it with an in-memory server.</summary>
public interface IServerTransport
{
    /// <summary>
    /// A client for one server. With an expected fingerprint only that key is accepted; without one
    /// (the first contact) any key is accepted and reported to <paramref name="captured"/>.
    /// </summary>
    HttpClient CreateClient(Uri address, string? expectedFingerprint, CapturedFingerprint? captured, TimeSpan timeout);
}

/// <summary>
/// HTTPS with the server's key pinned: trust comes from the key fingerprint the person confirmed,
/// not from a certificate authority, so name and chain errors of the self-signed certificate are
/// expected and ignored. Redirects and cookies are never followed or kept.
/// </summary>
public sealed class PinnedServerTransport(string? installationId = null) : IServerTransport
{
    public HttpClient CreateClient(Uri address, string? expectedFingerprint, CapturedFingerprint? captured, TimeSpan timeout)
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            ConnectTimeout = TimeSpan.FromSeconds(8),
            PooledConnectionIdleTimeout = TimeSpan.FromSeconds(60),
            AutomaticDecompression = DecompressionMethods.Brotli | DecompressionMethods.GZip,
        };
        handler.SslOptions.RemoteCertificateValidationCallback = (_, certificate, _, _) =>
        {
            if (certificate is not X509Certificate2 presented) return false;
            var fingerprint = ServerIdentity.Fingerprint(presented);
            if (fingerprint is null) return false;
            captured?.Set(fingerprint);
            return expectedFingerprint is null || ServerIdentity.Matches(expectedFingerprint, fingerprint);
        };
        var client = new HttpClient(handler) { BaseAddress = address, Timeout = timeout };
        // Which device this is, for the owner's Settings › Security (docs/CLIENT_PROTOCOL.md).
        if (installationId is not null) client.DefaultRequestHeaders.TryAddWithoutValidation("X-Aurelia-Installation", installationId);
        client.DefaultRequestHeaders.TryAddWithoutValidation("X-Aurelia-Client", AureliaInstallation.ClientHeader);
        return client;
    }
}
