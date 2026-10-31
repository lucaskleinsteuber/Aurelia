namespace Aurelia.Linux.Core.Settings;

/// <summary>
/// Where the app keeps its own files, following the XDG base directories: settings in
/// <c>$XDG_CONFIG_HOME/aurelia-desktop</c>, caches in <c>$XDG_CACHE_HOME/aurelia-desktop</c> and state
/// that must survive (such as unsent playback progress) in <c>$XDG_STATE_HOME/aurelia-desktop</c>.
/// </summary>
public sealed record AppPaths(string ConfigDirectory, string CacheDirectory, string StateDirectory)
{
    public const string FolderName = "aurelia-desktop";

    public static AppPaths FromEnvironment(Func<string, string?>? environment = null)
    {
        environment ??= Environment.GetEnvironmentVariable;
        var home = environment("HOME") is { Length: > 0 } value ? value : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string Base(string variable, string fallback) =>
            environment(variable) is { Length: > 0 } path && Path.IsPathRooted(path) ? path : Path.Combine(home, fallback);
        return new(
            Path.Combine(Base("XDG_CONFIG_HOME", ".config"), FolderName),
            Path.Combine(Base("XDG_CACHE_HOME", ".cache"), FolderName),
            Path.Combine(Base("XDG_STATE_HOME", Path.Combine(".local", "state")), FolderName));
    }

    public string SettingsFile => Path.Combine(ConfigDirectory, "settings.json");
}
