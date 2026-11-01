namespace Aurelia.Linux.Core.Hosting;

/// <summary>Keep the app's private VLC codec libraries out of the hosted server's runtime tools.</summary>
public static class HostedServerEnvironment
{
    public static void Configure(IDictionary<string, string?> environment)
    {
        if (environment.GetValueOrDefault("FLATPAK_ID") != AppInfo.ApplicationId) return;
        // Flatpak also puts /app/lib ahead of the runtime in ld.so.cache, so removing our
        // decoder-only libav from LD_LIBRARY_PATH alone is insufficient. This app targets
        // x64 and Freedesktop 26.08: prefer that runtime's complete, matching codec family
        // (including encoders) for both ffmpeg and ffprobe in the hosted server.
        string[] runtimePaths = ["/usr/lib/x86_64-linux-gnu/codecs-extra/lib", "/usr/lib/x86_64-linux-gnu"];
        var inherited = (environment.GetValueOrDefault("LD_LIBRARY_PATH") ?? "")
            .Split(':', StringSplitOptions.RemoveEmptyEntries)
            .Where(path => path != "/app/lib" && !path.StartsWith("/app/lib/", StringComparison.Ordinal)
                && path != "/app/lib64" && !path.StartsWith("/app/lib64/", StringComparison.Ordinal));
        environment["LD_LIBRARY_PATH"] = string.Join(':', runtimePaths.Concat(inherited).Distinct(StringComparer.Ordinal));
        environment.Remove("VLC_PLUGIN_PATH");
    }

    private static string? GetValueOrDefault(this IDictionary<string, string?> environment, string key) =>
        environment.TryGetValue(key, out var value) ? value : null;
}
