using System.Reflection;

namespace Aurelia.Server.Services;

public static class ServerProductVersion
{
    public static string Current { get; } = typeof(Program).Assembly
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? typeof(Program).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";

    /// <summary>The build counter, the fourth part of the file version (1.8.7.91), or 0.</summary>
    public static int Build { get; } = Version.TryParse(
        typeof(Program).Assembly.GetCustomAttribute<AssemblyFileVersionAttribute>()?.Version, out var file)
        && file.Revision > 0 ? file.Revision : 0;
}
