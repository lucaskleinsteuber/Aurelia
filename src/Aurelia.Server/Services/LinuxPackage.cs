namespace Aurelia.Server.Services;

/// <summary>
/// Aurelia Server installed from the Linux package runs as the <c>aurelia</c> systemd service, whose
/// unit sets <c>AURELIA_LINUX_PACKAGE=1</c>. Root-run parts of the package act on files the server
/// leaves in its data folder: power saving, updates. Restarting is the service's own job.
/// </summary>
public static class LinuxPackage
{
    /// <summary>systemd starts the service again when it ends with this status (RestartForceExitStatus).</summary>
    public const int RestartExitCode = 75;

    public static bool IsInstalled => OperatingSystem.IsLinux() && Environment.GetEnvironmentVariable("AURELIA_LINUX_PACKAGE") == "1";

    public static string Platform => OperatingSystem.IsMacOS() ? "macos"
        : OperatingSystem.IsLinux() ? "linux"
        : OperatingSystem.IsWindows() ? "windows" : "other";
}

/// <summary>Restarts a packaged Linux server: it ends with <see cref="LinuxPackage.RestartExitCode"/> and systemd starts it again.</summary>
public sealed class LinuxServiceRestart(IHostApplicationLifetime lifetime, ServerConfigurationStore configuration)
{
    public HostOperationStatus Request()
    {
        if (!LinuxPackage.IsInstalled)
            throw new AccountException("restart_unavailable", "This server cannot restart itself.", 409);
        // The answer reaches the device before the server stops.
        _ = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(1));
            Environment.ExitCode = LinuxPackage.RestartExitCode;
            lifetime.StopApplication();
        });
        return new(Guid.NewGuid(), "restart", "restarting", null, configuration.Current.LanHttpsPort);
    }
}

/// <summary>
/// Where this server runs. Aurelia for Mac and Aurelia for Linux start the server they host with
/// <c>--host-parent-pid</c>; such a desktop or laptop is often off or elsewhere, so it gets no
/// Wake-on-LAN and only "stop after unused minutes". The Linux package runs it as a system service
/// on a computer meant to serve.
/// </summary>
public static class ServerHosting
{
    public const string MacApp = "macApp";
    public const string LinuxApp = "linuxApp";
    public const string LinuxServer = "linuxServer";
    public const string Server = "server";

    /// <summary>A server that stopped because nobody used it ends with this status, so its app doesn't start it again.</summary>
    public const int IdleExitCode = 76;

    public static string Kind(ServerRuntimeOptions runtime) =>
        runtime.HostParentProcessId is not null ? (OperatingSystem.IsMacOS() ? MacApp : LinuxApp)
        : LinuxPackage.IsInstalled ? LinuxServer : Server;

    public static bool ByApp(string kind) => kind is MacApp or LinuxApp;
}
