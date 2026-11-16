namespace Aurelia.Server.Services;

/// <summary>Selects the read-only library lists that may be compressed.</summary>
public static class CatalogCompression
{
    public static bool Applies(HttpContext context) =>
        HttpMethods.IsGet(context.Request.Method)
        && (context.Request.Path.StartsWithSegments("/api/v1/catalog")
            || context.Request.Path.StartsWithSegments("/api/v1/home")
            || context.Request.Path.StartsWithSegments("/api/v1/collections")
            || context.Request.Path.StartsWithSegments("/api/v1/watchlist")
            || context.Request.Path.StartsWithSegments("/api/v1/history")
            // A series' plan lists every episode (61 KB for Better Call Saul); it holds no ticket.
            || (context.Request.Path.StartsWithSegments("/api/v1/media")
                && context.Request.Path.Value?.EndsWith("/playback-plan", StringComparison.Ordinal) == true));
}
