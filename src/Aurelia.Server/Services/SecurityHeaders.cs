using Microsoft.Net.Http.Headers;

namespace Aurelia.Server.Services;

/// <summary>
/// Headers on every response. The API serves JSON and media only: nothing may be framed,
/// sniffed as another type or leak a referrer, and personal responses are never stored by
/// intermediaries unless an endpoint sets its own caching (artwork does). The browser app's page
/// sets its own, still strict content policy (<see cref="WebAppAssets.ContentSecurityPolicy"/>).
/// </summary>
public static class SecurityHeaders
{
    public static void Apply(IHeaderDictionary headers)
    {
        headers.XContentTypeOptions = "nosniff";
        headers.XFrameOptions = "DENY";
        headers["Referrer-Policy"] = "no-referrer";
        if (!headers.ContainsKey(HeaderNames.ContentSecurityPolicy))
            headers.ContentSecurityPolicy = "default-src 'none'; frame-ancestors 'none'";
        if (!headers.ContainsKey(HeaderNames.CacheControl)) headers.CacheControl = "no-store";
    }
}
