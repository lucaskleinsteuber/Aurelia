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
