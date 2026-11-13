using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Api;

/// <summary>
/// This app's own random identifier, sent as <c>X-Aurelia-Installation</c> with <c>X-Aurelia-Client</c>
/// ("linux/2.7.0"), so the owner can tell devices apart in Settings › Security and block one. It
/// identifies an installation, not a person, and lives in the app's settings folder.
/// </summary>
public static class AureliaInstallation
{
    public const string FileName = "installation-id";

    public static string ClientHeader => "linux/" + AppInfo.CurrentVersion.ToString(3);

    /// <summary>The saved identifier, created once; null when the folder can't be written.</summary>
    public static string? Identifier(string configDirectory)
    {
        var path = Path.Combine(configDirectory, FileName);
        try
        {
            if (File.Exists(path) && Guid.TryParse(File.ReadAllText(path).Trim(), out var saved)) return saved.ToString();
            var created = Guid.NewGuid().ToString();
            PrivateFiles.CreateDirectory(configDirectory);
            PrivateFiles.WriteAllText(path, created);
            return created;
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
