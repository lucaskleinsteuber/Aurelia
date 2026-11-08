namespace Aurelia.Linux.Core.Settings;

/// <summary>
/// Where the app keeps its own files, following the XDG base directories: settings in
/// <c>$XDG_CONFIG_HOME/aurelia-desktop</c>, caches in <c>$XDG_CACHE_HOME/aurelia-desktop</c> and state
/// that must survive (such as unsent playback progress) in <c>$XDG_STATE_HOME/aurelia-desktop</c>, and
/// the data of the server this computer hosts in <c>$XDG_DATA_HOME/aurelia-desktop/server</c>.
/// </summary>
public sealed record AppPaths(string ConfigDirectory, string CacheDirectory, string StateDirectory, string? DataDirectory = null)
{
    /// <summary>"aurelia-desktop", or "aurelia-desktop-test" for the test edition, which never shares files with the real app.</summary>
    public static string FolderName { get; } = AppInfo.IsTestEdition ? "aurelia-desktop-test" : "aurelia-desktop";

    public static AppPaths FromEnvironment(Func<string, string?>? environment = null)
    {
        environment ??= Environment.GetEnvironmentVariable;
        var home = environment("HOME") is { Length: > 0 } value ? value : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string Base(string variable, string fallback) =>
            environment(variable) is { Length: > 0 } path && Path.IsPathRooted(path) ? path : Path.Combine(home, fallback);
        return new(
            Path.Combine(Base("XDG_CONFIG_HOME", ".config"), FolderName),
            Path.Combine(Base("XDG_CACHE_HOME", ".cache"), FolderName),
            Path.Combine(Base("XDG_STATE_HOME", Path.Combine(".local", "state")), FolderName),
            Path.Combine(Base("XDG_DATA_HOME", Path.Combine(".local", "share")), FolderName));
    }

    public string SettingsFile => Path.Combine(ConfigDirectory, "settings.json");

    /// <summary>The hosted server's database, settings and TLS identity. Media is never stored here.</summary>
    public string ServerDirectory => Path.Combine(DataDirectory ?? StateDirectory, "server");

    public string LogDirectory => Path.Combine(StateDirectory, "logs");
}
