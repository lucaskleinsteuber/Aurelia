namespace Aurelia.Server.Authentication;

/// <summary>
/// The browser app's credentials. They live in HttpOnly cookies that scripts cannot read, and a
/// cookie only counts when the request says which one it means with the X-Aurelia-Web header.
/// Another site cannot send that header without a CORS preflight the server never answers, and
/// SameSite=Strict keeps the cookies off requests started from other sites. Video and image
/// elements cannot set headers, so a plain GET or HEAD of a stream or picture uses the profile.
/// </summary>
public static class WebCookies
{
    public const string Header = "X-Aurelia-Web";
    public const string Device = "aurelia_device";
    public const string Profile = "aurelia_profile";
    public const string Pairing = "aurelia_pairing";
    public const string PairingPath = "/api/v1/web/pairing";

    public static string? Credential(HttpRequest request)
    {
        var purpose = request.Headers[Header].ToString();
        if (purpose == "device") return Read(request, Device);
        if (purpose == "profile") return Read(request, Profile);
        if (purpose.Length == 0 && (HttpMethods.IsGet(request.Method) || HttpMethods.IsHead(request.Method))
            && (request.Path.StartsWithSegments("/api/v1/streams") || request.Path.StartsWithSegments("/api/v1/artwork")
                || request.Path.StartsWithSegments("/api/v1/wishes/poster")
                || (request.Path.StartsWithSegments("/api/v1/media") && IsMediaImage(request.Path.Value ?? string.Empty))
                || (request.Path.StartsWithSegments("/api/v1/collections") && IsCollectionImage(request.Path.Value ?? string.Empty))))
            return Read(request, Profile);
        return null;
    }

    public static string? Read(HttpRequest request, string name)
    {
        if (request.IsHttps && request.Cookies.TryGetValue("__Host-" + name, out var hostScoped) && !string.IsNullOrEmpty(hostScoped))
            return hostScoped;
        return request.Cookies[name];
    }

    public static string EffectiveName(HttpContext context, string name, string path = "/") =>
        context.Request.IsHttps && path == "/" ? "__Host-" + name : name;

    // Scrub previews and the media/collection editors' artwork and image drafts are shown in <img> elements.
    private static bool IsMediaImage(string path) =>
        path.Contains("/scrub-previews/", StringComparison.Ordinal)
        || path.Contains("/editor/artwork/", StringComparison.Ordinal)
        || path.Contains("/editor/uploads/", StringComparison.Ordinal);

    private static bool IsCollectionImage(string path) =>
        path.Contains("/editor/uploads/", StringComparison.Ordinal);

    /// <param name="expires">Null keeps the cookie only until the browser closes.</param>
    public static void Set(HttpContext context, string name, string value, DateTimeOffset? expires, string path = "/")
    {
        var effectiveName = EffectiveName(context, name, path);
        context.Response.Cookies.Append(effectiveName, value, Options(context, path, expires));
        if (!string.Equals(effectiveName, name, StringComparison.Ordinal) && context.Request.Cookies.ContainsKey(name))
            context.Response.Cookies.Delete(name, Options(context, path, null));
    }

    public static void Delete(HttpContext context, string name, string path = "/")
    {
        var effectiveName = EffectiveName(context, name, path);
        context.Response.Cookies.Delete(effectiveName, Options(context, path, null));
        if (!string.Equals(effectiveName, name, StringComparison.Ordinal))
            context.Response.Cookies.Delete(name, Options(context, path, null));
    }

    // Secure needs HTTPS; plain HTTP is only possible on the server's own loopback address.
    private static CookieOptions Options(HttpContext context, string path, DateTimeOffset? expires) => new()
    {
        HttpOnly = true,
        Secure = context.Request.IsHttps,
        SameSite = SameSiteMode.Strict,
        Path = path,
        Expires = expires,
        IsEssential = true,
    };
}
