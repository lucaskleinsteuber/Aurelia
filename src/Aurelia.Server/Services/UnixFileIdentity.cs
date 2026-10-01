using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Aurelia.Server.Services;

internal static partial class UnixFileIdentity
{
    // The pinned .NET runtime's PAL supplies one portable FileStatus ABI instead
    // of guessing libc stat layouts separately on macOS, Linux, arm64 and x64.
    [StructLayout(LayoutKind.Explicit, Size = 256)]
    private struct FileStatus
    {
        [FieldOffset(4)] public int Mode;
        [FieldOffset(8)] public uint Uid;
    }
    public static bool IsRegular(SafeFileHandle handle) =>
        FStat(handle.DangerousGetHandle(), out var status) == 0 && (status.Mode & 0xF000) == 0x8000;
    public static void RequireOwned(string path)
    {
        if (OperatingSystem.IsWindows()) return;
        if (LStat(path, out var status) != 0 || status.Uid != GetEffectiveUserId() || (status.Mode & 0xF000) == 0xA000)
            throw new IOException("Private server state must be owned by the current user and cannot be a symbolic link.");
    }
    [LibraryImport("System.Native", EntryPoint = "SystemNative_FStat", SetLastError = true)]
    private static partial int FStat(nint descriptor, out FileStatus status);
    [LibraryImport("System.Native", EntryPoint = "SystemNative_LStat", StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    private static partial int LStat(string path, out FileStatus status);
    [LibraryImport("libc", EntryPoint = "geteuid")]
    private static partial uint GetEffectiveUserId();
}
