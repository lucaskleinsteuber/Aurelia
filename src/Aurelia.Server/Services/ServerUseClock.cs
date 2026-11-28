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

    /// <summary>When someone last used the server since it started, or null.</summary>
    public DateTimeOffset? LastUse { get { lock (gate) return written; } }

    /// <summary>Requests an open app sends by itself, with nobody using it.</summary>
    private static readonly PathString[] Background =
    [
        "/api/v1/sync/changes",
        "/api/v1/devices/player/heartbeat",
        "/api/v1/devices/player/commands",
        "/api/v1/health",
        "/api/v1/server/info",
        "/api/v1/server/security/alerts",
    ];

    /// <summary>
    /// Marks a read an open app makes by itself (since server 2.21.0): a page that refreshes its
    /// progress every few seconds, a remote's status or a page reloaded because the server
    /// reported a change. Only reads may carry it; whatever a person changes still counts.
    /// </summary>
    public const string BackgroundHeader = "X-Aurelia-Background";

    /// <summary>A request that waits on the server for something to happen is an app keeping watch.</summary>
    private static readonly string[] WaitParameters = ["waitSeconds", "waitMs"];

    /// <summary>
    /// A request someone made: one from a signed-in device that is not background work, or a
    /// sign-in itself. Unauthenticated probes from the network never keep the server awake.
    /// </summary>
    public static bool CountsAsUse(HttpContext context)
    {
        var path = context.Request.Path;
        foreach (var background in Background)
            if (path.Equals(background, StringComparison.OrdinalIgnoreCase)) return false;
        // Watch Together and Movie Night are gone, but Home in apps from before their removal
        // still asks every few seconds whether a party or a night is on; that is nobody using it.
        if (HttpMethods.IsGet(context.Request.Method)
            && (path.StartsWithSegments("/api/v1/watch-together") || path.StartsWithSegments("/api/v1/movie-night"))) return false;
        // A small remote asks every few seconds how the other device plays; the other device counts.
        if (HttpMethods.IsGet(context.Request.Method) && path.StartsWithSegments("/api/v1/devices/players")
            && path.Value?.EndsWith("/status", StringComparison.OrdinalIgnoreCase) == true) return false;
        if (HttpMethods.IsGet(context.Request.Method) && context.Request.Headers.ContainsKey(BackgroundHeader)) return false;
        // Whatever an open app waits for (new devices for the owner, commands, changes): nobody
        // did anything. New waiting requests then never keep the server awake by being forgotten here.
        if (HttpMethods.IsGet(context.Request.Method))
            foreach (var name in WaitParameters)
                if (context.Request.Query.ContainsKey(name)) return false;
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
            PrivateFilePermissions.WritePrivateText(UsePath, now.ToUnixTimeSeconds().ToString(System.Globalization.CultureInfo.InvariantCulture));
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Power saving then falls back to open connections; the request itself goes on.
            return false;
        }
    }
}
