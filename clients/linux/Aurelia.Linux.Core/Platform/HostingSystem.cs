using System.Globalization;
using Aurelia.Linux.Core.Hosting;
using Aurelia.Linux.Core.Settings;
using Microsoft.Win32.SafeHandles;
using Tmds.DBus.Protocol;

namespace Aurelia.Linux.Core.Platform;

/// <summary>What hosting the server needs from the desktop: start at login and keeping the computer awake.</summary>
public interface IHostingSystem
{
    bool StartsAtLogin { get; }

    /// <summary>Requests background permission and configures login startup. A denied request throws without saving preferences.</summary>
    Task ConfigureBackgroundAsync(bool keepRunning, bool startAtLogin);

    /// <summary>Keeps the computer from sleeping by itself until the result is disposed; null where the desktop cannot.</summary>
    Task<IDisposable?> KeepAwakeAsync(string reason);
}

/// <summary>The hosting choices, saved with the app's settings.</summary>
public static class HostingSettings
{
    public const string KeepRunningKey = "hostKeepRunning";
    public const string StartAtLoginKey = "hostStartAtLogin";
    public const string KeepAwakeKey = "hostKeepAwake";

    public static HostingPreferences Read(ISettingsStore store) => new(
        store.Read<bool?>(KeepRunningKey) ?? false,
        store.Read<bool?>(StartAtLoginKey) ?? false,
        store.Read<bool?>(KeepAwakeKey) ?? false);

    public static void Write(ISettingsStore store, HostingPreferences preferences)
    {
        store.Write(KeepRunningKey, preferences.KeepRunning);
        // Starting at login only makes sense when the server keeps running without the window.
        store.Write(StartAtLoginKey, preferences.KeepRunning && preferences.StartAtSignIn);
        store.Write(KeepAwakeKey, preferences.KeepAwake);
    }

    /// <summary>
    /// How to open the server's port in a firewall that is installed here, or null without one. Aurelia
    /// never changes the firewall itself; that needs the administrator password.
    /// </summary>
    public static string? FirewallHint(int port, Func<string, bool>? exists = null)
    {
        exists ??= File.Exists;
        var number = port.ToString(CultureInfo.InvariantCulture);
        if (exists("/usr/sbin/ufw") || exists("/usr/bin/ufw"))
            return $"If other devices cannot connect, allow the server's port in the firewall: sudo ufw allow {number}/tcp";
        if (exists("/usr/bin/firewall-cmd"))
            return $"If other devices cannot connect, allow the server's port in the firewall: sudo firewall-cmd --permanent --add-port={number}/tcp && sudo firewall-cmd --reload";
        return null;
    }
}

/// <summary>
/// The Linux desktop: an XDG autostart entry starts Aurelia in the background at login, and logind's
/// inhibitor lock keeps the computer awake (released by the system when Aurelia ends, even after a crash).
/// </summary>
public sealed class LinuxHostingSystem : IHostingSystem
{
    private readonly AppPaths paths;
    private readonly IDesktopHostingPortal? portal;
    private bool portalStartsAtLogin;

    public LinuxHostingSystem(AppPaths paths) : this(paths,
        Environment.GetEnvironmentVariable("FLATPAK_ID") is { Length: > 0 } ? new DesktopHostingPortal() : null)
    {
    }

    internal LinuxHostingSystem(AppPaths paths, IDesktopHostingPortal? portal)
    {
        this.paths = paths;
        this.portal = portal;
    }

    private string AutostartFile => Path.Combine(Path.GetDirectoryName(paths.ConfigDirectory)!, "autostart", AppInfo.ApplicationId + ".desktop");

    public bool StartsAtLogin => portal is null ? File.Exists(AutostartFile) : portalStartsAtLogin;

    public async Task ConfigureBackgroundAsync(bool keepRunning, bool startAtLogin)
    {
        var enabled = keepRunning && startAtLogin;
        if (portal is not null)
        {
            var granted = await portal.RequestBackgroundAsync(enabled);
            if (keepRunning && !granted.Background || enabled && !granted.Autostart)
                throw new InvalidOperationException("The desktop did not allow Aurelia to run in the background or start at login. You can allow it in the desktop's application permissions.");
            portalStartsAtLogin = granted.Autostart;
            return;
        }
        if (!enabled)
        {
            if (File.Exists(AutostartFile)) File.Delete(AutostartFile);
            return;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(AutostartFile)!);
        File.WriteAllText(AutostartFile, AutostartEntry(File.Exists("/usr/bin/aurelia-desktop") ? "aurelia-desktop" : Environment.ProcessPath ?? "aurelia-desktop"));
    }

    public static string AutostartEntry(string executable) =>
        $"""
        [Desktop Entry]
        Type=Application
        Name={AppInfo.DisplayName}
        Comment=Keeps this computer's Aurelia Server running
        Exec={(AppInfo.IsTestEdition ? "env AURELIA_EDITION=test " : "")}{(executable.Contains(' ', StringComparison.Ordinal) ? "\"" + executable + "\"" : executable)} --background
        Icon={AppInfo.ApplicationId}
        Terminal=false
        NoDisplay=true
        X-GNOME-Autostart-enabled=true

        """;

    public async Task<IDisposable?> KeepAwakeAsync(string reason)
    {
        if (portal is not null)
        {
            try
            {
                return await portal.InhibitAsync(reason);
            }
            catch (DBusExceptionBase)
            {
                return null;
            }
        }
        if (DBusConnection.System is not { } bus) return null;
        try
        {
            MessageBuffer Call()
            {
                using var writer = bus.GetMessageWriter();
                writer.WriteMethodCallHeader(destination: "org.freedesktop.login1", path: "/org/freedesktop/login1",
                    @interface: "org.freedesktop.login1.Manager", signature: "ssss", member: "Inhibit");
                writer.WriteString("sleep:idle");
                writer.WriteString("Aurelia");
                writer.WriteString(reason);
                writer.WriteString("block");
                return writer.CreateMessage();
            }
            return await bus.CallMethodAsync(Call(), (message, _) => message.GetBodyReader().ReadHandle<SafeFileHandle>(), null);
        }
        catch (DBusExceptionBase)
        {
            return null;
        }
    }
}

/// <summary>For tests and systems without these services.</summary>
public sealed class NoHostingSystem : IHostingSystem
{
    public bool StartsAtLogin { get; private set; }

    public int AwakeRequests { get; private set; }

    public Task ConfigureBackgroundAsync(bool keepRunning, bool startAtLogin)
    {
        StartsAtLogin = keepRunning && startAtLogin;
        return Task.CompletedTask;
    }

    public Task<IDisposable?> KeepAwakeAsync(string reason)
    {
        AwakeRequests++;
        return Task.FromResult<IDisposable?>(null);
    }
}
