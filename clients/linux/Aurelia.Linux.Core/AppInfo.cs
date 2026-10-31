using System.Reflection;

namespace Aurelia.Linux.Core;

/// <summary>The product name and the version this build carries.</summary>
public static class AppInfo
{
    public const string ProductName = "Aurelia";

    /// <summary>The desktop file and Wayland app id; it also names the Flatpak.</summary>
    public const string ApplicationId = "io.github.lucasfd3.Aurelia";

    /// <summary>Version and build, for example "0.1.0 (1)".</summary>
    public static string DisplayVersion { get; } = FormatVersion(
        typeof(AppInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion);

    public static string FormatVersion(string? informationalVersion)
    {
        if (string.IsNullOrWhiteSpace(informationalVersion)) return "0.0.0";
        var version = informationalVersion.Split('+', 2);
        if (version.Length == 2 && version[1].StartsWith("build.", StringComparison.Ordinal))
        {
            var build = version[1]["build.".Length..].Split('.', 2)[0];
            return $"{version[0]} ({build})";
        }
        return version[0];
    }
}
