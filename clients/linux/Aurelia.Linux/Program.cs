using Aurelia.Linux.Core;
using Avalonia;

namespace Aurelia.Linux;

public enum DisplayBackendPreference { PlatformDefault, WaylandWithX11Fallback, X11 }

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
        var preference = SelectDisplayBackend(OperatingSystem.IsLinux(), Environment.GetEnvironmentVariable("AURELIA_DISPLAY_BACKEND"));
        if (preference == DisplayBackendPreference.PlatformDefault) return builder.UsePlatformDetect();
        // X11 is configured first: it is the fallback that UseWaylandWithFallback switches to.
        builder = builder.UseX11();
        if (preference == DisplayBackendPreference.WaylandWithX11Fallback) builder = builder.UseWaylandWithFallback();
        return builder
            .UseSkia()
            .UseHarfBuzz()
            .With(new WaylandPlatformOptions { AppId = AppInfo.ApplicationId });
    }

    /// <summary>Pure startup policy; inspecting it never registers another graphics platform in a running app.</summary>
    public static DisplayBackendPreference SelectDisplayBackend(bool isLinux, string? requested) => !isLinux
        ? DisplayBackendPreference.PlatformDefault
        : requested == "x11" ? DisplayBackendPreference.X11 : DisplayBackendPreference.WaylandWithX11Fallback;
}
