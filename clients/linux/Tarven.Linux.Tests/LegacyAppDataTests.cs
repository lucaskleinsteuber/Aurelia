using Tarven.Linux.Core;
using Tarven.Linux.Core.Settings;
using Xunit;

namespace Tarven.Linux.Tests;

/// <summary>
/// Tarven was called Aurelia: on its first start it takes over the old app's folders and login
/// entry. Temporary folders with invented content only.
/// </summary>
public sealed class LegacyAppDataTests
{
    [Fact]
    public void TheOldFoldersAndLoginEntryAreTakenOverOnce()
    {
        var home = Directory.CreateTempSubdirectory("tarven-legacy-home-").FullName;
        try
        {
            var paths = AppPaths.FromEnvironment(name => name == "HOME" ? home : null);
            var config = Path.Combine(home, ".config", LegacyAppData.FolderName);
            var server = Path.Combine(home, ".local", "share", LegacyAppData.FolderName, "server");
            Directory.CreateDirectory(config);
            Directory.CreateDirectory(server);
            File.WriteAllText(Path.Combine(config, "settings.json"), "{\"betaUpdates\":true}");
            File.WriteAllText(Path.Combine(server, "aurelia.db"), "synthetic");
            var autostart = Directory.CreateDirectory(Path.Combine(home, ".config", "autostart")).FullName;
            File.WriteAllText(Path.Combine(autostart, LegacyAppData.ApplicationId + ".desktop"),
                $"[Desktop Entry]\nName=Aurelia\nExec=/usr/bin/{LegacyAppData.FolderName} --background\nIcon={LegacyAppData.ApplicationId}\n");

            var adopted = LegacyAppData.Adopt(paths);

            Assert.Contains(paths.ConfigDirectory, adopted);
            Assert.Equal("{\"betaUpdates\":true}", File.ReadAllText(paths.SettingsFile));
            Assert.True(File.Exists(Path.Combine(paths.ServerDirectory, "aurelia.db")));
            Assert.False(Directory.Exists(config));
            Assert.False(File.Exists(Path.Combine(autostart, LegacyAppData.ApplicationId + ".desktop")));
            var entry = File.ReadAllText(Path.Combine(autostart, AppInfo.ApplicationId + ".desktop"));
            Assert.Contains($"Exec=/usr/bin/{AppPaths.FolderName} --background", entry, StringComparison.Ordinal);
            Assert.Contains("Name=Tarven", entry, StringComparison.Ordinal);

            // A second start finds nothing more to take over and never touches the new folders.
            Directory.CreateDirectory(config);
            File.WriteAllText(Path.Combine(config, "settings.json"), "{}");
            Assert.Empty(LegacyAppData.Adopt(paths));
            Assert.Equal("{\"betaUpdates\":true}", File.ReadAllText(paths.SettingsFile));
        }
        finally { Directory.Delete(home, recursive: true); }
    }

    [Fact]
    public void NothingMovesWhileAureliaStillRuns()
    {
        var home = Directory.CreateTempSubdirectory("tarven-legacy-home-").FullName;
        try
        {
            var paths = AppPaths.FromEnvironment(name => name == "HOME" ? home : null);
            var config = Directory.CreateDirectory(Path.Combine(home, ".config", LegacyAppData.FolderName)).FullName;
            using (new FileStream(Path.Combine(config, "instance.lock"), FileMode.Create, FileAccess.ReadWrite, FileShare.None))
            {
                Assert.Empty(LegacyAppData.Adopt(paths));
                Assert.True(Directory.Exists(config));
                Assert.False(Directory.Exists(paths.ConfigDirectory));
            }
        }
        finally { Directory.Delete(home, recursive: true); }
    }

    [Fact]
    public void TheFlatpakAsksTheHostToCopyAndThenRemovesTheAureliaFlatpak()
    {
        var home = "/home/someone";
        var sandbox = $"{home}/.var/app/{AppInfo.ApplicationId}";
        var paths = new AppPaths($"{sandbox}/config/{AppPaths.FolderName}", $"{sandbox}/cache/{AppPaths.FolderName}",
            $"{sandbox}/.local/state/{AppPaths.FolderName}", $"{sandbox}/data/{AppPaths.FolderName}");
        var calls = new List<string>();
        var legacyConfig = $"{home}/.var/app/{LegacyAppData.ApplicationId}/config/{LegacyAppData.FolderName}";
        LegacyAppData.Adopt(paths, (program, arguments) =>
        {
            calls.Add(program + " " + string.Join(' ', arguments));
            return program != "test" || arguments[1] == legacyConfig;
        });
        Assert.Equal(
        [
            $"test -d {legacyConfig}",
            $"cp -a {legacyConfig} {paths.ConfigDirectory}",
            $"test -d {home}/.var/app/{LegacyAppData.ApplicationId}/.local/state/{LegacyAppData.FolderName}",
            $"test -d {home}/.var/app/{LegacyAppData.ApplicationId}/data/{LegacyAppData.FolderName}",
            $"flatpak uninstall --user --noninteractive {LegacyAppData.ApplicationId}",
        ], calls);
    }
}
