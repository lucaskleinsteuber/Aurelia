using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Settings;
using Avalonia.Media;
using Avalonia;

namespace Aurelia.Linux;

public enum DisplayBackendPreference { PlatformDefault, WaylandWithX11Fallback, X11 }

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        using var instance = new AppInstance(AppPaths.FromEnvironment().ConfigDirectory);
        if (!instance.IsOwner)
        {
            try { instance.NotifyExistingAsync(!args.Contains("--background", StringComparer.Ordinal)).GetAwaiter().GetResult(); return 0; }
            catch (Exception error) when (error is IOException or OperationCanceledException)
            {
                Console.Error.WriteLine("Aurelia is already running, but its window could not be reached. Try again in a moment.");
                return 1;
            }
        }
        // A stale login entry must not open a window or start hosting after it was disabled.
        if (args.Contains("--background", StringComparer.Ordinal)
            && !StartsBackgroundServer(new JsonFileSettingsStore(AppPaths.FromEnvironment().SettingsFile))) return 0;
        App.Instance = instance;
        return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    /// <summary>
    /// Wayland first, as most current desktops run it; X11 when there is no Wayland session or when
    /// AURELIA_DISPLAY_BACKEND=x11 asks for it. Other systems (the Mac during development) use their own.
    /// </summary>
    public static AppBuilder BuildAvaloniaApp()
    {
        var builder = AppBuilder.Configure<App>().WithInterFont()
            .With(new FontManagerOptions { DefaultFamilyName = "avares://Avalonia.Fonts.Inter/Assets#Inter" });
        var preference = SelectDisplayBackend(OperatingSystem.IsLinux(), Environment.GetEnvironmentVariable("AURELIA_DISPLAY_BACKEND"));
        if (preference == DisplayBackendPreference.PlatformDefault) return builder.UsePlatformDetect();
        // X11 is configured first: it is the fallback that UseWaylandWithFallback switches to.
        builder = builder.UseX11();
        if (preference == DisplayBackendPreference.WaylandWithX11Fallback) builder = builder.UseWaylandWithFallback();
        return builder
            .UseSkia()
            .UseHarfBuzz()
            // On X11, menus are drawn inside the window: no separate popup windows whose square
            // corners show around the rounded menus.
            .With(new X11PlatformOptions { OverlayPopups = true })
            .With(new WaylandPlatformOptions { AppId = AppInfo.ApplicationId });
    }

    public static bool StartsBackgroundServer(ISettingsStore settings) =>
        new AppFlow(settings).Mode == OperatingMode.Host && HostingSettings.Read(settings).KeepRunning;

    /// <summary>Pure startup policy; inspecting it never registers another graphics platform in a running app.</summary>
    public static DisplayBackendPreference SelectDisplayBackend(bool isLinux, string? requested) => !isLinux
        ? DisplayBackendPreference.PlatformDefault
        : requested == "x11" ? DisplayBackendPreference.X11 : DisplayBackendPreference.WaylandWithX11Fallback;
}
