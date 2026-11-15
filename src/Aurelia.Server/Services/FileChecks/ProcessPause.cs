using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Aurelia.Server.Services.FileChecks;

/// <summary>
/// Holds a running ffmpeg still while someone watches and lets it go on afterwards (SIGSTOP and
/// SIGCONT), so a long examination need not start again. Where that is not possible (Windows), the
/// caller ends the run and examines the file again later.
/// </summary>
internal static partial class ProcessPause
{
    public static bool Supported => OperatingSystem.IsLinux() || OperatingSystem.IsMacOS();

    public static bool Suspend(Process process) => Signal(process, OperatingSystem.IsMacOS() ? 17 : 19);

    public static bool Resume(Process process) => Signal(process, OperatingSystem.IsMacOS() ? 19 : 18);

    private static bool Signal(Process process, int signal)
    {
        if (!Supported) return false;
        try
        {
            return !process.HasExited && Kill(process.Id, signal) == 0;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    [LibraryImport("libc", EntryPoint = "kill", SetLastError = true)]
    private static partial int Kill(int pid, int signal);
}
