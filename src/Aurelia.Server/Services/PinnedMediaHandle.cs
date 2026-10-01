using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Aurelia.Server.Services;

internal static partial class PinnedMediaHandle
{
    // openat pins each directory, so replacing a parent with a symlink between
    // validation and open cannot redirect the file descriptor outside the root.
    public static FileStream Open(string libraryPath, string sourcePath)
    {
        if (!OperatingSystem.IsMacOS() && !OperatingSystem.IsLinux())
            throw new NotSupportedException("Handle-pinned direct play requires macOS or Linux.");
        var root = Path.GetFullPath(libraryPath);
        if (OperatingSystem.IsMacOS())
        {
            // Canonical aliases shipped by macOS, not arbitrary library symlinks.
            foreach (var alias in new[] { "/var", "/tmp", "/etc" })
                if (root.StartsWith(alias + "/", StringComparison.Ordinal)) root = "/private" + root;
        }
        var components = root.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Concat(Path.GetRelativePath(libraryPath, sourcePath).Split('/', StringSplitOptions.RemoveEmptyEntries)).ToArray();
        if (components.Length == 0 || components.Any(value => value is "." or ".." || value.Contains('\0'))) throw new IOException("Invalid media path.");
        var noFollow = OperatingSystem.IsMacOS() ? 0x100 : 0x20000;
        var directory = OperatingSystem.IsMacOS() ? 0x100000 : 0x10000;
        var closeOnExec = OperatingSystem.IsMacOS() ? 0x1000000 : 0x80000;
        var nonBlocking = OperatingSystem.IsMacOS() ? 0x4 : 0x800;
        using var first = Owned(OpenNative("/", directory | closeOnExec));
        SafeFileHandle current = first;
        try
        {
            for (var index = 0; index < components.Length; index++)
            {
                var last = index == components.Length - 1;
                var next = Owned(OpenAtNative(current.DangerousGetHandle().ToInt32(), components[index], noFollow | closeOnExec | (last ? nonBlocking : directory)));
                if (!ReferenceEquals(current, first)) current.Dispose();
                current = next;
            }
            if (!UnixFileIdentity.IsRegular(current)) throw new IOException("Media is not a regular file.");
            var stream = new FileStream(current, FileAccess.Read, 128 * 1024, isAsync: false);
            current = first; // FileStream owns the final descriptor.
            return stream;
        }
        finally { if (!ReferenceEquals(current, first)) current.Dispose(); }
    }
    private static SafeFileHandle Owned(int descriptor)
    {
        if (descriptor < 0) throw new IOException("The media handle could not be opened safely.");
        return new SafeFileHandle((IntPtr)descriptor, ownsHandle: true);
    }
    [LibraryImport("libc", EntryPoint = "open", StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    private static partial int OpenNative(string path, int flags);
    [LibraryImport("libc", EntryPoint = "openat", StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    private static partial int OpenAtNative(int directory, string path, int flags);
}
