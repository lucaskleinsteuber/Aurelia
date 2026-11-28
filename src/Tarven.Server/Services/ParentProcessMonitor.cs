using System.Diagnostics;

namespace Tarven.Server.Services;

public sealed class ParentProcessMonitor(
    ServerRuntimeOptions runtime,
    IHostApplicationLifetime lifetime,
    ILogger<ParentProcessMonitor> logger) : BackgroundService
{
    private static readonly Action<ILogger, Exception?> NativeHostExited =
        LoggerMessage.Define(
            LogLevel.Information,
            new EventId(5001, nameof(NativeHostExited)),
            "The native host exited; stopping Tarven Server.");

    private static readonly Action<ILogger, Exception?> MonitorFailed =
        LoggerMessage.Define(
            LogLevel.Warning,
            new EventId(5002, nameof(MonitorFailed)),
            "Parent process check failed unexpectedly.");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (runtime.HostParentProcessId is null)
        {
            return;
        }

        if (Environment.GetEnvironmentVariable("TARVEN_HOST_LIFELINE") == "1")
        {
            // An inherited pipe closes even after SIGKILL and cannot accidentally
            // bind to a reused parent PID. Standalone servers keep the PID fallback.
            using var input = Console.OpenStandardInput();
            await MonitorLifelineAsync(input, () =>
            {
                NativeHostExited(logger, null);
                lifetime.StopApplication();
            }, stoppingToken);
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var process = Process.GetProcessById(runtime.HostParentProcessId.Value);
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
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                MonitorFailed(logger, exception);
            }

            try { await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { return; }
        }
    }

    internal static async Task MonitorLifelineAsync(Stream input, Action stopApplication, CancellationToken cancellationToken)
    {
        try
        {
            var buffer = new byte[1];
            // Console input may not interrupt an in-flight Unix read. WaitAsync
            // still lets normal server shutdown finish while the host pipe is open.
            while (await input.ReadAsync(buffer, CancellationToken.None).AsTask().WaitAsync(cancellationToken) != 0) { }
            if (!cancellationToken.IsCancellationRequested) stopApplication();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (IOException) when (!cancellationToken.IsCancellationRequested) { stopApplication(); }
    }
}
