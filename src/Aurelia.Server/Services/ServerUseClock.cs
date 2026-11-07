namespace Aurelia.Server.Services;

/// <summary>
/// Remembers when someone last used this server: browsing, playing, saving progress or changing
/// settings on any device. An open app keeps a few connections busy in the background (library
/// sync, Play On availability) even when nobody looks at it; those do not count. The server writes
/// the time to a <c>last-use</c> file in its data folder, at most twice a minute, so the Linux
/// power saving (<c>aurelia sleep on</c>) can tell an idle open app apart from someone watching.
/// </summary>
public sealed class ServerUseClock(ServerRuntimeOptions runtime, TimeProvider clock)
{
    public const string FileName = "last-use";
    private static readonly TimeSpan WriteInterval = TimeSpan.FromSeconds(30);
    private readonly object gate = new();
    private DateTimeOffset? written;

    private string UsePath => Path.Combine(runtime.DataDirectory, FileName);

    /// <summary>Requests an open app sends by itself, with nobody using it.</summary>
    private static readonly PathString[] Background =
    [
        "/api/v1/sync/changes",
        "/api/v1/devices/player/heartbeat",
        "/api/v1/devices/player/commands",
        "/api/v1/health",
        "/api/v1/server/info",
    ];

    /// <summary>
    /// A request someone made: one from a signed-in device that is not background work, or a
    /// sign-in itself. Unauthenticated probes from the network never keep the server awake.
    /// </summary>
    public static bool CountsAsUse(HttpContext context)
    {
        var path = context.Request.Path;
        foreach (var background in Background)
            if (path.Equals(background, StringComparison.OrdinalIgnoreCase)) return false;
        // A Watch Together player asks for the party while it waits; playing itself counts.
        if (HttpMethods.IsGet(context.Request.Method) && path.StartsWithSegments("/api/v1/watch-together")
            && context.Request.Query.ContainsKey("after")) return false;
        if (context.User.Identity?.IsAuthenticated == true) return true;
        return HttpMethods.IsPost(context.Request.Method)
            && (path.StartsWithSegments("/api/v1/auth") || path.StartsWithSegments("/api/v1/setup"));
    }

    /// <summary>Notes a use now. True when the file was written.</summary>
    public bool Record()
    {
        DateTimeOffset now;
        lock (gate)
        {
            now = clock.GetUtcNow();
            if (written is { } last && now - last < WriteInterval && now >= last) return false;
            written = now;
        }

        try
        {
            PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
            File.WriteAllText(UsePath, now.ToUnixTimeSeconds().ToString(System.Globalization.CultureInfo.InvariantCulture));
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Power saving then falls back to open connections; the request itself goes on.
            return false;
        }
    }
}
