using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Services;
using Microsoft.Net.Http.Headers;

namespace Aurelia.Server.Endpoints;

/// <summary>
/// Aurelia in a web browser. The server hands out the app's files and signs a browser in with the
/// pairing code from the main device (older setups: an owner-approved code the browser shows),
/// but keeps every credential in HttpOnly cookies
/// (<see cref="WebCookies"/>). Everything else the app does goes through the normal API.
/// </summary>
public static class WebAppEndpoints
{
    public static void MapWebApp(this WebApplication app)
    {
        var web = app.MapGroup("/api/v1/web").AddEndpointFilter(async (context, next) =>
        {
            // Only the app's own scripts send this header; a form on another site cannot.
            if (string.IsNullOrEmpty(context.HttpContext.Request.Headers[WebCookies.Header]))
                throw new AccountException("web_header_required", "This request must come from the Aurelia browser app.", 403);
            RequirePrivateTransport(context.HttpContext);
            return await next(context);
        });

        web.MapPost("/pairing", async (DeviceAuthorizationStartRequest request, DeviceAuthorizationService service, HttpContext context) =>
        {
            var started = await service.StartAsync(request.DeviceName, Address(context), context.RequestAborted);
            WebCookies.Set(context, WebCookies.Pairing, $"{started.Id:N}.{started.Secret}", started.ExpiresAt, WebCookies.PairingPath);
            return new WebPairingResponse(started.Code, started.ExpiresAt, started.PollIntervalSeconds);
        });
        web.MapPost("/pairing/status", async (DeviceAuthorizationService service, HttpContext context) =>
        {
            var (id, secret) = Pairing(context);
            var status = await service.StatusAsync(id, secret, Address(context), context.RequestAborted);
            if (status.Authentication is { } credential)
            {
                // The browser keeps the device credential; the pairing is finished at once so the
                // server forgets its copy.
                await service.AcknowledgeAsync(id, secret, Address(context), context.RequestAborted);
                WebCookies.Set(context, WebCookies.Device, credential.Token, credential.ExpiresAt);
            }
            if (status.State != DeviceAuthorizationState.Pending) WebCookies.Delete(context, WebCookies.Pairing, WebCookies.PairingPath);
            return new WebPairingStatusResponse(status.State, status.ExpiresAt, status.PollIntervalSeconds);
        });
        // The same 8-digit code every Aurelia app enters: created on the main device (a Mac, the
        // Linux app or `aurelia pair`) and typed into the browser. The credential goes into the
        // HttpOnly device cookie and never into the response.
        web.MapPost("/pair", async (RedeemPairingCodeRequest request, AccountService accounts, HttpContext context) =>
        {
            var credential = await accounts.RedeemPairingCodeAsync(request, context.RequestAborted);
            WebCookies.Set(context, WebCookies.Device, credential.Token, credential.ExpiresAt);
            WebCookies.Delete(context, WebCookies.Pairing, WebCookies.PairingPath);
            return Results.NoContent();
        }).RequireRateLimiting("authentication");
        web.MapPost("/pairing/cancel", async (DeviceAuthorizationService service, HttpContext context) =>
        {
            if (context.Request.Cookies.ContainsKey(WebCookies.Pairing))
            {
                var (id, secret) = Pairing(context);
                await service.CancelAsync(id, secret, Address(context), context.RequestAborted);
            }
            WebCookies.Delete(context, WebCookies.Pairing, WebCookies.PairingPath);
            return Results.NoContent();
        });

        web.MapPost("/profiles/{id:guid}/unlock", async (Guid id, UnlockProfileRequest request, ProfileService service, HttpContext context) =>
        {
            var session = await service.UnlockAsync(context.User.RequireSessionId(), id, request.Pin, context.RequestAborted);
            // A session cookie: closing the browser ends the profile, as quitting does in the apps.
            WebCookies.Set(context, WebCookies.Profile, session.Token, null);
            return new WebProfileResponse(session.User, session.ExpiresAt);
        }).RequireAuthorization("TrustedDevice").RequireRateLimiting("authentication");

        web.MapPost("/profile/end", (HttpContext context, ProfileSessionStore sessions) =>
        {
            if (context.User.FindFirst(DeviceTokenAuthenticationHandler.ProfileSessionIdClaim) is not null)
                sessions.End(context.User.RequireProfileSessionId());
            WebCookies.Delete(context, WebCookies.Profile);
            return Results.NoContent();
        });
        web.MapPost("/sign-out", async (HttpContext context, AccountService accounts) =>
        {
            if (context.User.Identity?.IsAuthenticated == true)
                await accounts.RevokeOwnDeviceAsync(context.User.RequireSessionId(), context.RequestAborted);
            WebCookies.Delete(context, WebCookies.Profile);
            WebCookies.Delete(context, WebCookies.Device);
            return Results.NoContent();
        });

        // The page's files under a name that changes with their content: kept for good by the browser.
        app.MapMethods("/web/v/{version}/{**file}", [HttpMethods.Get, HttpMethods.Head], (string version, string? file, WebAppAssets assets, HttpContext context) =>
            version == assets.Version && file != WebAppAssets.Index ? Serve(context, assets.Find(file ?? string.Empty), immutable: true) : Results.NotFound());
        app.MapMethods("/web/{**file}", [HttpMethods.Get, HttpMethods.Head], (string? file, WebAppAssets assets, HttpContext context) =>
            Serve(context, file == WebAppAssets.Index ? assets.Page : assets.Find(file ?? string.Empty)));
        // Every other page address belongs to the app, which finds its screen from the address.
        // API addresses keep their plain 404, and this route runs only when no other one matches.
        app.MapMethods("{**path}", [HttpMethods.Get, HttpMethods.Head], (string? path, WebAppAssets assets, HttpContext context) =>
            context.Request.Path.StartsWithSegments("/api") ? Results.NotFound() : Serve(context, assets.Page))
            .Add(endpoint => ((RouteEndpointBuilder)endpoint).Order = int.MaxValue);
    }

    private static IResult Serve(HttpContext context, WebAppAssets.Asset? asset, bool immutable = false)
    {
        if (asset is null) return Results.NotFound();
        var headers = context.Response.Headers;
        headers.CacheControl = immutable ? "public, max-age=31536000, immutable" : "no-cache";
        headers.XContentTypeOptions = "nosniff";
        if (asset.ContentType.StartsWith("text/html", StringComparison.Ordinal))
            headers.ContentSecurityPolicy = WebAppAssets.ContentSecurityPolicy;
        var encoding = asset.Compressible ? PreferredEncoding(context.Request) : null;
        var body = encoding is null ? null : asset.Encoded(encoding);
        if (body is null) encoding = null;
        if (asset.Compressible) headers.Vary = HeaderNames.AcceptEncoding;
        // Each encoding is its own representation, so it carries its own tag.
        var entityTag = encoding is null ? asset.EntityTag : asset.EntityTag.Insert(asset.EntityTag.Length - 1, "-" + encoding);
        headers.ETag = entityTag;
        if (context.Request.Headers.IfNoneMatch.ToString() == entityTag)
            return Results.StatusCode(StatusCodes.Status304NotModified);
        if (encoding is not null) headers.ContentEncoding = encoding;
        var content = body ?? asset.Content;
        if (HttpMethods.IsHead(context.Request.Method))
        {
            headers.ContentType = asset.ContentType;
            headers.ContentLength = content.Length;
            return Results.Empty;
        }
        return Results.Bytes(content, asset.ContentType);
    }

    /// <summary>Brotli when the browser accepts it, else gzip, else none; "q=0" refuses an encoding.</summary>
    internal static string? PreferredEncoding(HttpRequest request)
    {
        if (!StringWithQualityHeaderValue.TryParseList(request.Headers.AcceptEncoding, out var values)) return null;
        bool Accepts(string name) => values.Any(value =>
            value.Value.Equals(name, StringComparison.OrdinalIgnoreCase) && (value.Quality ?? 1) > 0);
        return Accepts("br") ? "br" : Accepts("gzip") ? "gzip" : null;
    }

    private static (Guid Id, string Secret) Pairing(HttpContext context)
    {
        var value = context.Request.Cookies[WebCookies.Pairing] ?? string.Empty;
        var separator = value.IndexOf('.', StringComparison.Ordinal);
        if (separator < 0 || !Guid.TryParseExact(value[..separator], "N", out var id))
            throw new AccountException("device_pairing_not_found", "The device pairing was not found.", 404);
        return (id, value[(separator + 1)..]);
    }

    private static string Address(HttpContext context) => context.Connection.RemoteIpAddress?.ToString() ?? "local";

    private static void RequirePrivateTransport(HttpContext context)
    {
        context.Response.Headers[HeaderNames.CacheControl] = "no-store";
        if (!context.Request.IsHttps && context.Connection.RemoteIpAddress is { } ip && !System.Net.IPAddress.IsLoopback(ip))
            throw new AccountException("https_required", "Signing in requires the server's HTTPS address.", 403);
    }
}
