using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Core.Settings;
using Aurelia.Linux.Core.Hosting;
using Aurelia.Linux.Core.Updates;
using Aurelia.Linux.Playback;

namespace Aurelia.Linux;

/// <summary>The app's long-lived services, created once at start; tests pass their own.</summary>
public sealed record AppServices(
    ISettingsStore Settings,
    WindowButtonLayout ButtonLayout,
    IServerTransport Transport,
    ICredentialStore Credentials,
    Func<IServerDiscovery> CreateDiscovery,
    IWakeOnLan WakeOnLan,
    TimeProvider Time,
    string DeviceName,
    string? ArtworkDirectory = null,
    IVideoEngineFactory? Engines = null,
    string? StateDirectory = null,
    IPlaybackSystem? PlaybackSystem = null,
    Func<ILocalServerHost>? CreateHost = null,
    IHostingSystem? HostingSystem = null,
    AppUpdater? Updater = null,
    OfflineDownloads? Downloads = null)
{
    public static AppServices CreateDefault()
    {
        var paths = AppPaths.FromEnvironment();
        var settings = new JsonFileSettingsStore(paths.SettingsFile);
        return new(
            settings,
            DesktopButtonLayoutReader.Read(),
            new PinnedServerTransport(),
            new SecretServiceCredentialStore(),
            () => new MdnsServerDiscovery(),
            new UdpWakeOnLan(),
            TimeProvider.System,
            Environment.MachineName,
            Path.Combine(paths.CacheDirectory, "artwork"),
            new VlcEngineFactory(),
            paths.StateDirectory,
            new LinuxPlaybackSystem(action => Avalonia.Threading.Dispatcher.UIThread.Post(action)),
            () => new LocalServerHost(LocalServerOptions.ForThisComputer(paths)),
            new LinuxHostingSystem(paths),
            // Aurelia Test shares the installed program with the real app, so it never installs updates.
            AppInfo.IsTestEdition ? null : new AppUpdater(new GitHubReleaseSource(settings: settings,
                auditPath: Path.Combine(paths.CacheDirectory, "updates", "public-test-audit.jsonl")), new LinuxPackageInstaller(), settings, paths.CacheDirectory, AppInfo.CurrentVersion, AppInfo.Build),
            // Downloads stay in this app's data folder, never next to the media.
            new OfflineDownloads(Path.Combine(paths.DataDirectory ?? paths.StateDirectory, "Offline Titles")));
    }

    /// <summary>Services that touch nothing outside the process, for tests.</summary>
    public static AppServices ForTests(ISettingsStore? settings = null, WindowButtonLayout? layout = null, IServerTransport? transport = null,
        ICredentialStore? credentials = null, IVideoEngineFactory? engines = null, TimeProvider? time = null, ILocalServerHost? host = null) => new(
            settings ?? new MemorySettingsStore(),
            layout ?? WindowButtonLayout.Default,
            transport ?? new PinnedServerTransport(),
            credentials ?? new MemoryCredentialStore(),
            () => new NoServerDiscovery(),
            new NoWakeOnLan(),
            time ?? TimeProvider.System,
            "Test PC",
            Engines: engines,
            CreateHost: host is null ? null : () => host,
            HostingSystem: new NoHostingSystem());
}
