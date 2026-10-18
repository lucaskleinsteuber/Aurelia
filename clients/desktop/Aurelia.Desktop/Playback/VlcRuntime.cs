using System.Runtime.InteropServices;
using LibVLCSharp.Shared;

namespace Aurelia.Desktop.Playback;

/// <summary>Finds the VLC build that ships next to the app for this platform and architecture.</summary>
public static class VlcRuntime
{
    private static readonly Lock Gate = new();
    private static bool initialized;

    public static void EnsureInitialized()
    {
        lock (Gate)
        {
            if (initialized) return;
            var directory = NativeDirectory();
            if (directory is not null && OperatingSystem.IsMacOS())
            {
                // The Mac build keeps its modules beside the library; tell VLC where they are.
                Environment.SetEnvironmentVariable("VLC_PLUGIN_PATH", Path.Combine(directory, "vlc", "plugins"));
            }
            LibVLCSharp.Shared.Core.Initialize(directory);
            initialized = true;
        }
    }

    /// <summary>The bundled VLC folder, or null to use the system's VLC (Linux).</summary>
    public static string? NativeDirectory()
    {
        var arm = RuntimeInformation.ProcessArchitecture == Architecture.Arm64;
        var root = Path.Combine(AppContext.BaseDirectory, "libvlc");
        string? directory = null;
        if (OperatingSystem.IsWindows()) directory = Path.Combine(root, arm ? "win-arm64" : "win-x64");
        else if (OperatingSystem.IsMacOS()) directory = Path.Combine(root, arm ? "osx-arm64" : "osx-x64", "lib");
        return directory is not null && Directory.Exists(directory) ? directory : null;
    }

    /// <summary>The platform's normal audio output, used to rebuild the output with night mode.</summary>
    public static string AudioOutput =>
        OperatingSystem.IsWindows() ? "mmdevice" : OperatingSystem.IsMacOS() ? "auhal" : "pulse";
}
