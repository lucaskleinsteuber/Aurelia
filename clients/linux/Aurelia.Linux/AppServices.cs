using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux;

/// <summary>The app's long-lived services, created once at start; tests pass their own.</summary>
public sealed record AppServices(ISettingsStore Settings, WindowButtonLayout ButtonLayout)
{
    public static AppServices CreateDefault()
    {
        var paths = AppPaths.FromEnvironment();
        return new(new JsonFileSettingsStore(paths.SettingsFile), DesktopButtonLayoutReader.Read());
    }
}
