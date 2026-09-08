using System.Diagnostics;

namespace Aurelia.Home.Server.Services;

public sealed class ParentProcessMonitor(
    ServerRuntimeOptions runtime,
    IHostApplicationLifetime lifetime,
    ILogger<ParentProcessMonitor> logger) : BackgroundService
{
    private static readonly Action<ILogger, Exception?> NativeHostExited =
        LoggerMessage.Define(
            LogLevel.Information,
            new EventId(5001, nameof(NativeHostExited)),
            "The native host exited; stopping Aurelia Home Server.");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (runtime.HostParentProcessId is null)
        {
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var process = Process.GetProcessById(runtime.HostParentProcessId.Value);
                if (process.HasExited)
                {
                    lifetime.StopApplication();
                    return;
                }
            }
            catch (ArgumentException)
            {
                NativeHostExited(logger, null);
                lifetime.StopApplication();
                return;
            }

            await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
        }
    }
}
