using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Aurelia.Server.Services;

internal static partial class PinnedMediaHandle
{
    // Remains an IOException for existing editor/browser callers, while playback
    // can distinguish a permanent unsafe handle from transient storage failure.
    internal sealed class UnsafeHandleException() : IOException("The media handle could not be opened safely.") { }

    // openat pins each directory, so replacing a parent with a symlink between
    // validation and open cannot redirect the file descriptor outside the root.
    public static FileStream Open(string libraryPath, string sourcePath)
        => new(OpenHandle(libraryPath, sourcePath, false), FileAccess.Read, 128 * 1024, isAsync: false);

    public static IReadOnlyList<(string Name, bool Directory)> ListDirectory(string libraryPath, string path)
    {
        using var handle = OpenHandle(libraryPath, path, true);
        var descriptor = Dup(handle.DangerousGetHandle().ToInt32());
        if (descriptor < 0) throw new IOException("The directory could not be opened.");
        var directory = FdOpenDirectory(descriptor);
        if (directory == IntPtr.Zero) { _ = Close(descriptor); throw new IOException("The directory could not be opened."); }
        try
        {
            var results = new List<(string, bool)>();
            IntPtr entry;
            while ((entry = ReadDirectory(directory)) != IntPtr.Zero)
            {
                var mac = OperatingSystem.IsMacOS();
                var type = Marshal.ReadByte(entry, mac ? 20 : 18);
                var name = Marshal.PtrToStringUTF8(entry + (mac ? 21 : 19));
                if (name is null or "." or ".." || name.Contains('/') || type is not 4 and not 8) continue;
                if (results.Count >= 10_000) throw new AccountException("directory_too_large", "This directory contains too many entries. Select a smaller folder.", 413);
                results.Add((name, type == 4));
            }
            return results;
        }
        finally { _ = CloseDirectory(directory); }
    }

    private static SafeFileHandle OpenHandle(string libraryPath, string sourcePath, bool isDirectory)
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
            .Concat(Path.GetRelativePath(libraryPath, sourcePath).Split('/', StringSplitOptions.RemoveEmptyEntries).Where(value => value != ".")).ToArray();
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
                var next = Owned(OpenAtNative(current.DangerousGetHandle().ToInt32(), components[index], noFollow | closeOnExec | (last && !isDirectory ? nonBlocking : directory)));
                if (!ReferenceEquals(current, first)) current.Dispose();
                current = next;
            }
            if (!isDirectory && !UnixFileIdentity.IsRegular(current)) throw new UnsafeHandleException();
            var result = current;
            current = first;
            return result;
        }
        finally { if (!ReferenceEquals(current, first)) current.Dispose(); }
    }
    private static SafeFileHandle Owned(int descriptor)
    {
        if (descriptor < 0)
        {
            // Permission denial and symlink refusal are not transient drive
            // loss. Preserve that distinction without exposing file paths.
            var error = Marshal.GetLastPInvokeError();
            if (error is 1 or 13 || error == (OperatingSystem.IsMacOS() ? 62 : 40))
                throw new UnsafeHandleException();
            throw new IOException("The media handle could not be opened safely.");
        }
        return new SafeFileHandle((IntPtr)descriptor, ownsHandle: true);
    }
    [LibraryImport("libc", EntryPoint = "open", StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    private static partial int OpenNative(string path, int flags);
    [LibraryImport("libc", EntryPoint = "openat", StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    private static partial int OpenAtNative(int directory, string path, int flags);
    [LibraryImport("libc", EntryPoint = "dup")] private static partial int Dup(int descriptor);
    [LibraryImport("libc", EntryPoint = "close")] private static partial int Close(int descriptor);
    [LibraryImport("libc", EntryPoint = "fdopendir")] private static partial IntPtr FdOpenDirectory(int descriptor);
    [LibraryImport("libc", EntryPoint = "readdir")] private static partial IntPtr ReadDirectory(IntPtr directory);
    [LibraryImport("libc", EntryPoint = "closedir")] private static partial int CloseDirectory(IntPtr directory);
}
