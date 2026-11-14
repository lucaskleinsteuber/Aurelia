using Aurelia.Contracts;

namespace Aurelia.Server.Services.Automation;

/// <summary>
/// "Turn the server off now" from an app, Home Assistant or Siri. A Linux package server leaves a
/// power-now file that the aurelia-power-request path unit hands to aurelia-autosleep at once, which
/// sleeps or turns the computer off as `aurelia sleep` would (it is woken with Wake-on-LAN). A server
/// in the Mac or Linux app can only stop; it starts again when Aurelia is opened on that computer.
/// </summary>
public sealed partial class PowerNowService(
    ServerRuntimeOptions runtime,
    ActiveStreamRegistry streams,
    IHostApplicationLifetime lifetime,
    ILogger<PowerNowService> logger)
{
    public const string FileName = "power-now";

    /// <summary>What this server can do now, in the order an app offers them.</summary>
    public IReadOnlyList<string> Actions => Hosting switch
    {
        ServerHosting.LinuxServer => [PowerNowActions.Sleep, PowerNowActions.Shutdown, PowerNowActions.Stop],
        ServerHosting.MacApp or ServerHosting.LinuxApp => [PowerNowActions.Stop],
        _ => [],
    };

    private string Hosting => ServerHosting.Kind(runtime);

    public PowerNowResponse Request(PowerNowRequest request)
    {
        var action = (request.Action ?? string.Empty).Trim().ToLowerInvariant();
        if (!Actions.Contains(action))
            throw new AutomationException("power_action_unavailable", Actions.Count == 0
                ? "This server can't turn itself off. It runs as a service that something else starts and stops."
                : "This server can't do that. " + Describe(Actions), 409);
        if (streams.PlaybackCount > 0 && !request.Force)
            throw new AutomationException("playback_active", "Someone is watching right now. Turn it off anyway?", 409);
        if (ServerHosting.ByApp(Hosting))
        {
            Stopping(logger, action);
            Environment.ExitCode = ServerHosting.IdleExitCode;
            // Answer first, then stop.
            _ = Task.Delay(TimeSpan.FromSeconds(1)).ContinueWith(_ => lifetime.StopApplication(), TaskScheduler.Default);
            return new PowerNowResponse(action, "Aurelia Server stops now. It starts again when Aurelia is opened on its computer.");
        }
        PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
        var path = Path.Combine(runtime.DataDirectory, FileName);
        File.WriteAllText(path, action + "\n");
        PrivateFilePermissions.ProtectFile(path);
        Stopping(logger, action);
        return new PowerNowResponse(action, action switch
        {
            PowerNowActions.Sleep => "The server computer goes to sleep now. Wake-on-LAN wakes it in about 10 to 20 seconds.",
            PowerNowActions.Shutdown => "The server computer turns off now. Wake-on-LAN starts it again in about 30 to 60 seconds.",
            _ => "Aurelia Server stops now and starts again when a device connects.",
        });
    }

    private static string Describe(IReadOnlyList<string> actions) =>
        actions.SequenceEqual([PowerNowActions.Stop]) ? "It can only stop until Aurelia is opened on its computer." : string.Empty;

    [LoggerMessage(LogLevel.Information, "Asked to {Action} now.")]
    private static partial void Stopping(ILogger logger, string action);
}
