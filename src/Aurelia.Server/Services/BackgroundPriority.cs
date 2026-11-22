using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Aurelia.Server.Services;

/// <summary>
/// Lowers both CPU and disk I/O priority for background work (file checks, scrub previews, segment
/// detection, speech recognition, and background ffprobe) so playback and library browsing stay
/// responsive on both macOS and Linux.
/// </summary>
internal static partial class BackgroundPriority
{
    private const int PrioDarwinThread = 3;
    private const int PrioDarwinProcess = 4;
    private const int PrioDarwinBg = 0x1000;

    private const int IoprioWhoProcess = 1;
    private const int IoprioClassNone = 0;
    private const int IoprioClassIdle = 3;
    private const int IoprioClassShift = 13;

    /// <summary>
    /// Lowers a child background process's CPU and disk I/O priority. On macOS this enters
    /// <c>PRIO_DARWIN_BG</c> (efficiency cores + throttled disk I/O) in addition to <c>nice</c>.
    /// </summary>
    public static void ApplyToProcess(Process process, bool idle = false)
    {
        ArgumentNullException.ThrowIfNull(process);
        try
        {
            process.PriorityClass = idle ? ProcessPriorityClass.Idle : ProcessPriorityClass.BelowNormal;
        }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
        }

        if (OperatingSystem.IsMacOS())
        {
            try
            {
                if (!process.HasExited) _ = SetPriority(PrioDarwinProcess, (uint)process.Id, PrioDarwinBg);
            }
            catch (InvalidOperationException)
            {
            }
        }
    }

    /// <summary>
    /// Lowers the current dedicated thread's CPU and disk I/O priority for the lifetime of the
    /// returned scope. Always call on a dedicated background thread (never a shared ThreadPool
    /// thread without restoring).
    /// </summary>
    public static IDisposable EnterCurrentThread()
    {
        ThreadPriority? previous = null;
        try
        {
            previous = Thread.CurrentThread.Priority;
            Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
        }
        catch (Exception exception) when (exception is ThreadStateException or PlatformNotSupportedException)
        {
        }

        var darwinSet = false;
        if (OperatingSystem.IsMacOS())
        {
            darwinSet = SetPriority(PrioDarwinThread, 0, PrioDarwinBg) == 0;
        }

        var linuxSet = false;
        if (OperatingSystem.IsLinux())
        {
            linuxSet = SetLinuxThreadIoPriority(IoprioClassIdle << IoprioClassShift);
        }

        return new ThreadScope(previous, darwinSet, linuxSet);
    }

    private static bool SetLinuxThreadIoPriority(int priority)
    {
        var syscallNumber = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.X64 => 251L,
            Architecture.Arm64 => 30L,
            _ => -1L,
        };
        if (syscallNumber < 0) return false;
        return Syscall3(syscallNumber, IoprioWhoProcess, 0, priority) == 0;
    }

    private sealed class ThreadScope(ThreadPriority? previous, bool darwinSet, bool linuxSet) : IDisposable
    {
        private int disposed;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            if (darwinSet && OperatingSystem.IsMacOS()) _ = SetPriority(PrioDarwinThread, 0, 0);
            if (linuxSet && OperatingSystem.IsLinux()) _ = SetLinuxThreadIoPriority(IoprioClassNone << IoprioClassShift);
            if (previous is { } original)
            {
                try { Thread.CurrentThread.Priority = original; }
                catch (Exception exception) when (exception is ThreadStateException or PlatformNotSupportedException) { }
            }
        }
    }

    [LibraryImport("libc", EntryPoint = "setpriority", SetLastError = true)]
    private static partial int SetPriority(int which, uint who, int priority);

    [LibraryImport("libc", EntryPoint = "syscall", SetLastError = true)]
    private static partial long Syscall3(long number, long arg1, long arg2, long arg3);
}
