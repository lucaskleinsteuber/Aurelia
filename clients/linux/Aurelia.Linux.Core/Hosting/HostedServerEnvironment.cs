namespace Aurelia.Linux.Core.Hosting;

/// <summary>Keep the app's private VLC codec libraries out of the hosted server's runtime tools.</summary>
public static class HostedServerEnvironment
{
    public static void Configure(IDictionary<string, string?> environment)
    {
        if (environment.GetValueOrDefault("FLATPAK_ID") != AppInfo.ApplicationId) return;
        // The Flatpak's libavcodec is a decoder-only dependency of VLC. The runtime's ffmpeg
        // includes encoders for browser conversion and must load its own matching libraries.
        if (environment.GetValueOrDefault("LD_LIBRARY_PATH") is { } search)
        {
            var runtime = search.Split(':', StringSplitOptions.RemoveEmptyEntries)
                .Where(path => path != "/app/lib" && !path.StartsWith("/app/lib/", StringComparison.Ordinal)
                    && path != "/app/lib64" && !path.StartsWith("/app/lib64/", StringComparison.Ordinal));
            var value = string.Join(':', runtime);
            if (value.Length == 0) environment.Remove("LD_LIBRARY_PATH");
            else environment["LD_LIBRARY_PATH"] = value;
        }
        environment.Remove("VLC_PLUGIN_PATH");
    }

    private static string? GetValueOrDefault(this IDictionary<string, string?> environment, string key) =>
        environment.TryGetValue(key, out var value) ? value : null;
}
