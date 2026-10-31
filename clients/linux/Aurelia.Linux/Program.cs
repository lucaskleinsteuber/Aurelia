using Aurelia.Linux.Core;
using Avalonia;

namespace Aurelia.Linux;

public static class Program
{
    [STAThread]
    public static int Main(string[] args) => BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);

    /// <summary>
    /// Wayland first, as most current desktops run it; X11 when there is no Wayland session or when
    /// AURELIA_DISPLAY_BACKEND=x11 asks for it. Other systems (the Mac during development) use their own.
    /// </summary>
    public static AppBuilder BuildAvaloniaApp()
    {
        var builder = AppBuilder.Configure<App>().WithInterFont();
        if (!OperatingSystem.IsLinux()) return builder.UsePlatformDetect();
        // X11 is configured first: it is the fallback that UseWaylandWithFallback switches to.
        builder = builder.UseX11();
        if (Environment.GetEnvironmentVariable("AURELIA_DISPLAY_BACKEND") != "x11") builder = builder.UseWaylandWithFallback();
        return builder
            .UseSkia()
            .UseHarfBuzz()
            .With(new WaylandPlatformOptions { AppId = AppInfo.ApplicationId });
    }
}
