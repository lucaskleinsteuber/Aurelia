namespace Tarven.Linux.Core.Settings;

/// <summary>
/// Tarven was called Aurelia until Linux app 2.16.0. On its first start Tarven takes over what the
/// app kept under the old name: the settings, state, cache and hosted-server folders named
/// "aurelia-desktop" are renamed in place (nothing is copied), and the login entry is replaced.
/// The keyring entry comes along in <see cref="Platform.SecretServiceCredentialStore"/>. The Tarven
/// Flatpak can't see the Aurelia Flatpak's folder, so it asks the host to copy it over and then
/// removes the Aurelia Flatpak (its data stays). Nothing happens while Aurelia still runs, and never
/// when a folder of the new name already exists.
/// </summary>
public static class LegacyAppData
{
    public static string FolderName => AppInfo.IsTestEdition ? "aurelia-desktop-test" : "aurelia-desktop";
    public static string ApplicationId => AppInfo.IsTestEdition ? "io.github.lucasfd3.Aurelia.Test" : "io.github.lucasfd3.Aurelia";

    /// <summary>Renames the old folders; returns those it took over.</summary>
    public static IReadOnlyList<string> Adopt(AppPaths paths, Func<string, string[], bool>? host = null)
    {
        if (File.Exists("/.flatpak-info") || host is not null) return AdoptFlatpak(paths, host ?? RunOnHost);
        var adopted = new List<string>();
        var legacyConfig = Legacy(paths.ConfigDirectory);
        if (IsRunning(legacyConfig)) return adopted;
        foreach (var current in new[] { paths.ConfigDirectory, paths.StateDirectory, paths.DataDirectory, paths.CacheDirectory })
        {
            if (current is null) continue;
            var legacy = Legacy(current);
            if (Directory.Exists(current) || !Directory.Exists(legacy)) continue;
            try
            {
                Directory.Move(legacy, current);
                adopted.Add(current);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // Another file system or no permission: Tarven starts fresh; the old folder stays.
            }
        }
        ReplaceLoginEntry(paths);
        return adopted;
    }

    /// <summary>
    /// In the Flatpak sandbox the folders are ~/.var/app/&lt;id&gt;/…; the host copies Aurelia's
    /// (cp -a, nothing removed) and then uninstalls the Aurelia Flatpak without its data.
    /// </summary>
    private static List<string> AdoptFlatpak(AppPaths paths, Func<string, string[], bool> host)
    {
        var adopted = new List<string>();
        var sandbox = "/.var/app/" + AppInfo.ApplicationId + "/";
        var legacySandbox = "/.var/app/" + ApplicationId + "/";
        foreach (var current in new[] { paths.ConfigDirectory, paths.StateDirectory, paths.DataDirectory })
        {
            if (current is null || Directory.Exists(current) || !current.Contains(sandbox, StringComparison.Ordinal)) continue;
            var legacy = Legacy(current).Replace(sandbox, legacySandbox, StringComparison.Ordinal);
            if (host("test", ["-d", legacy]) && host("cp", ["-a", legacy, current])) adopted.Add(current);
        }
        if (adopted.Count > 0) host("flatpak", ["uninstall", "--user", "--noninteractive", ApplicationId]);
        return adopted;
    }

    private static bool RunOnHost(string program, string[] arguments)
    {
        try
        {
            var start = new System.Diagnostics.ProcessStartInfo("/usr/bin/flatpak-spawn") { UseShellExecute = false };
            start.ArgumentList.Add("--host");
            start.ArgumentList.Add(program);
            foreach (var argument in arguments) start.ArgumentList.Add(argument);
            using var process = System.Diagnostics.Process.Start(start);
            if (process is null) return false;
            if (!process.WaitForExit(TimeSpan.FromMinutes(5))) return false;
            return process.ExitCode == 0;
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException or InvalidOperationException)
        {
            return false;
        }
    }

    private static string Legacy(string current) => Path.Combine(Path.GetDirectoryName(current)!, FolderName);

    /// <summary>Aurelia holds instance.lock in its settings folder while it runs.</summary>
    private static bool IsRunning(string legacyConfig)
    {
        var lockFile = Path.Combine(legacyConfig, "instance.lock");
        if (!File.Exists(lockFile)) return false;
        try
        {
            using var probe = new FileStream(lockFile, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            return false;
        }
        catch (IOException)
        {
            return true;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>
    /// Aurelia's login entry would start an app that is gone; Tarven's own entry, with the same
    /// lines and the new name, takes its place.
    /// </summary>
    private static void ReplaceLoginEntry(AppPaths paths)
    {
        var folder = Path.Combine(Path.GetDirectoryName(paths.ConfigDirectory)!, "autostart");
        var legacy = Path.Combine(folder, ApplicationId + ".desktop");
        var current = Path.Combine(folder, AppInfo.ApplicationId + ".desktop");
        if (!File.Exists(legacy)) return;
        try
        {
            if (!File.Exists(current))
            {
                var entry = File.ReadAllText(legacy)
                    .Replace(ApplicationId, AppInfo.ApplicationId, StringComparison.Ordinal)
                    .Replace(FolderName, AppPaths.FolderName, StringComparison.Ordinal)
                    .Replace("Aurelia", AppInfo.ProductName, StringComparison.Ordinal);
                File.WriteAllText(current, entry);
            }
            File.Delete(legacy);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Settings › General shows the login choice; turning it off and on writes the entry again.
        }
    }
}
