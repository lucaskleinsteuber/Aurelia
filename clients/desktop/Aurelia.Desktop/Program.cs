using Avalonia;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop;

internal static class Program
{
    /// <summary>
    /// Starts Aurelia once per person: a second start opens the running one's window, "--background"
    /// (at sign-in) starts only the server in the notification area, and "--quit" (the installer)
    /// asks a running Aurelia to stop its server and close.
    /// </summary>
    [STAThread]
    public static int Main(string[] args)
    {
        var request = StartRequests.From(args);
        using var instance = AppInstance.TryClaim();
        if (instance is null)
        {
            if (request != StartRequest.Background)
                AppInstance.SendAsync(request, TimeSpan.FromSeconds(request == StartRequest.Quit ? 30 : 5)).GetAwaiter().GetResult();
            return 0;
        }
        if (request == StartRequest.Quit) return 0;
        App.Start = request;
        App.Instance = instance;
        return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args, Avalonia.Controls.ShutdownMode.OnExplicitShutdown);
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>().UsePlatformDetect().WithInterFont().LogToTrace();
}
