using System.Reflection;

namespace Aurelia.Server.Services;

public static class ServerProductVersion
{
    public static string Current { get; } = typeof(Program).Assembly
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? typeof(Program).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
}
