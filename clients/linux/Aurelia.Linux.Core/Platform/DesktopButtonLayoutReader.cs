using System.Diagnostics;

namespace Aurelia.Linux.Core.Platform;

/// <summary>
/// Reads the desktop's window button arrangement: KDE Plasma's kwinrc, otherwise GNOME's setting
/// (also used by Cinnamon, Budgie, MATE and others), otherwise the common default.
/// </summary>
public static class DesktopButtonLayoutReader
{
    public static WindowButtonLayout Read(Func<string, string?>? environment = null, Func<string?>? gnomeSetting = null)
    {
        environment ??= Environment.GetEnvironmentVariable;
        var desktop = environment("XDG_CURRENT_DESKTOP") ?? "";
        if (desktop.Contains("KDE", StringComparison.OrdinalIgnoreCase))
        {
            var home = environment("HOME") ?? "";
            var config = environment("XDG_CONFIG_HOME") is { Length: > 0 } value ? value : Path.Combine(home, ".config");
            var kwinrc = Path.Combine(config, "kwinrc");
            return File.Exists(kwinrc) ? FromKwinrc(File.ReadAllLines(kwinrc)) : WindowButtonLayout.FromKde(null, null);
        }
        return WindowButtonLayout.FromGnome((gnomeSetting ?? ReadGnomeSetting)()) ?? WindowButtonLayout.Default;
    }

    /// <summary>Reads the button letters from the <c>[org.kde.kdecoration2]</c> group of kwinrc.</summary>
    public static WindowButtonLayout FromKwinrc(IEnumerable<string> lines)
    {
        string? left = null, right = null;
        var inGroup = false;
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.StartsWith('['))
            {
                inGroup = line == "[org.kde.kdecoration2]";
                continue;
            }
            if (!inGroup) continue;
            var parts = line.Split('=', 2);
            if (parts.Length != 2) continue;
            if (parts[0] == "ButtonsOnLeft") left = parts[1];
            else if (parts[0] == "ButtonsOnRight") right = parts[1];
        }
        return WindowButtonLayout.FromKde(left, right);
    }

    private static string? ReadGnomeSetting()
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo("gsettings", ["get", "org.gnome.desktop.wm.preferences", "button-layout"])
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            });
            if (process is null) return null;
            var output = process.StandardOutput.ReadToEnd();
            return process.WaitForExit(2000) && process.ExitCode == 0 ? output : null;
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return null;
        }
    }
}
