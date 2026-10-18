using System.Reflection;

namespace Aurelia.Desktop;

/// <summary>The app's own version, independent of the Mac/server and Apple TV versions.</summary>
internal static class AppInfo
{
    public static string VersionLabel => Label(
        typeof(AppInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion);

    /// <summary>"0.0.1+build.1" (the SDK may append the source revision) becomes "Version 0.0.1 (1)".</summary>
    public static string Label(string? informationalVersion)
    {
        if (string.IsNullOrEmpty(informationalVersion)) return "Version unknown";
        var parts = informationalVersion.Split('+', 2);
        var build = parts.Length > 1 && parts[1].StartsWith("build.", StringComparison.Ordinal)
            ? new string(parts[1]["build.".Length..].TakeWhile(char.IsAsciiDigit).ToArray())
            : "";
        return build.Length > 0 ? $"Version {parts[0]} ({build})" : $"Version {parts[0]}";
    }
}
