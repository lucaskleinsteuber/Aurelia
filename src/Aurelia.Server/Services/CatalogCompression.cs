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
            || context.Request.Path.StartsWithSegments("/api/v1/history"));
}
