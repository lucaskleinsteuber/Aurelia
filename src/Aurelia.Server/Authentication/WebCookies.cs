namespace Aurelia.Server.Authentication;

/// <summary>
/// The browser app's credentials. They live in HttpOnly cookies that scripts cannot read, and a
/// cookie only counts when the request says which one it means with the X-Aurelia-Web header.
/// Another site cannot send that header without a CORS preflight the server never answers, and
/// SameSite=Strict keeps the cookies off requests started from other sites. Video and image
/// elements cannot set headers, so a plain GET or HEAD of a stream or artwork uses the profile.
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
        if (purpose == "device") return request.Cookies[Device];
        if (purpose == "profile") return request.Cookies[Profile];
        if (purpose.Length == 0 && (HttpMethods.IsGet(request.Method) || HttpMethods.IsHead(request.Method))
            && (request.Path.StartsWithSegments("/api/v1/streams") || request.Path.StartsWithSegments("/api/v1/artwork")))
            return request.Cookies[Profile];
        return null;
    }

    /// <param name="expires">Null keeps the cookie only until the browser closes.</param>
    public static void Set(HttpContext context, string name, string value, DateTimeOffset? expires, string path = "/") =>
        context.Response.Cookies.Append(name, value, Options(context, path, expires));

    public static void Delete(HttpContext context, string name, string path = "/") =>
        context.Response.Cookies.Delete(name, Options(context, path, null));

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
