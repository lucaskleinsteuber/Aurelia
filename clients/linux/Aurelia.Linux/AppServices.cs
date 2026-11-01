using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Core.Settings;

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
    string DeviceName)
{
    public static AppServices CreateDefault()
    {
        var paths = AppPaths.FromEnvironment();
        return new(
            new JsonFileSettingsStore(paths.SettingsFile),
            DesktopButtonLayoutReader.Read(),
            new PinnedServerTransport(),
            new SecretServiceCredentialStore(),
            () => new MdnsServerDiscovery(),
            new UdpWakeOnLan(),
            TimeProvider.System,
            Environment.MachineName);
    }

    /// <summary>Services that touch nothing outside the process, for tests.</summary>
    public static AppServices ForTests(ISettingsStore? settings = null, WindowButtonLayout? layout = null, IServerTransport? transport = null,
        ICredentialStore? credentials = null) => new(
            settings ?? new MemorySettingsStore(),
            layout ?? WindowButtonLayout.Default,
            transport ?? new PinnedServerTransport(),
            credentials ?? new MemoryCredentialStore(),
            () => new NoServerDiscovery(),
            new NoWakeOnLan(),
            TimeProvider.System,
            "Test PC");
}
