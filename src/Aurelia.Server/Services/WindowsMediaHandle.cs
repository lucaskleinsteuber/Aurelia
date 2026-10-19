using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

namespace Aurelia.Server.Services;

/// <summary>
/// The Windows counterpart of the openat chain in <see cref="PinnedMediaHandle"/>. Windows has no
/// per-component no-follow open, so the opened handle is checked instead: it must be a plain file
/// or directory, and the path the system reports for that handle must be exactly the expected path
/// beneath the library's own resolved location. A junction or link swapped in anywhere below the
/// library therefore cannot redirect the handle, even after validation. The library location
/// itself may be a mapped network drive; it is resolved once and serves as the anchor.
/// </summary>
[SupportedOSPlatform("windows")]
internal static unsafe partial class WindowsMediaHandle
{
    private const uint GenericRead = 0x8000_0000;
    private const uint FileListDirectory = 0x0001;
    private const uint FileReadAttributes = 0x0080;
    private const uint ShareAll = 0x1 | 0x2 | 0x4;
    private const uint OpenExisting = 3;
    private const uint BackupSemantics = 0x0200_0000;
    private const uint OpenReparsePoint = 0x0020_0000;
    private const uint AttributeDirectory = 0x10;
    private const uint AttributeReparsePoint = 0x400;
    private const uint VolumeNameNt = 0x2;
    private const int FileAttributeTagInfo = 9;
    private const int FileIdInfo = 18;
    private const int FileFullDirectoryInfo = 14;
    private const int FileFullDirectoryRestartInfo = 15;
    private const int ErrorNoMoreFiles = 18;

    public static FileStream Open(string libraryPath, string sourcePath)
        => new(OpenHandle(libraryPath, sourcePath, isDirectory: false), FileAccess.Read, 128 * 1024, isAsync: false);

    public static IReadOnlyList<(string Name, bool Directory)> ListDirectory(string libraryPath, string path)
    {
        using var handle = OpenHandle(libraryPath, path, isDirectory: true);
        // Reading the entries through the verified handle lists exactly that directory, like
        // fdopendir on macOS and Linux, even if its path is replaced meanwhile.
        var results = new List<(string, bool)>();
        var buffer = new byte[64 * 1024];
        var infoClass = FileFullDirectoryRestartInfo;
        while (true)
        {
            bool read;
            fixed (byte* pointer = buffer) read = GetFileInformationByHandleEx(handle, infoClass, pointer, (uint)buffer.Length);
            if (!read)
            {
                if (Marshal.GetLastPInvokeError() == ErrorNoMoreFiles) return results;
                throw new IOException("The directory could not be read.");
            }
            infoClass = FileFullDirectoryInfo;
            var offset = 0;
            while (true)
            {
                var next = BitConverter.ToInt32(buffer, offset);
                var attributes = BitConverter.ToUInt32(buffer, offset + 56);
                var nameBytes = BitConverter.ToInt32(buffer, offset + 60);
                if (nameBytes < 0 || offset + 68 + nameBytes > buffer.Length) throw new IOException("The directory could not be read.");
                var name = System.Text.Encoding.Unicode.GetString(buffer, offset + 68, nameBytes);
                // Links are left out, as macOS and Linux leave out symbolic links.
                if (name is not ("." or "..") && (attributes & AttributeReparsePoint) == 0 && name.IndexOfAny(['\\', '/', ':', '\0']) < 0)
                {
                    if (results.Count >= 10_000)
                        throw new AccountException("directory_too_large", "This directory contains too many entries. Select a smaller folder.", 413);
                    results.Add((name, (attributes & AttributeDirectory) != 0));
                }
                if (next <= 0) break;
                offset += next;
                if (offset + 68 > buffer.Length) throw new IOException("The directory could not be read.");
            }
        }
    }

    /// <summary>A stable identity for a file on its volume, so a moved or renamed video keeps its title.</summary>
    public static string? TryReadIdentity(string path)
    {
        using var handle = CreateFile(Win32Path(path), FileReadAttributes, ShareAll, 0, OpenExisting, BackupSemantics | OpenReparsePoint, 0);
        if (handle.IsInvalid) return null;
        // FILE_ID_INFO holds a 64-bit volume serial and a 128-bit file ID (unique on NTFS and ReFS).
        var info = stackalloc byte[24];
        if (GetFileInformationByHandleEx(handle, FileIdInfo, info, 24))
        {
            var identifier = new ReadOnlySpan<byte>(info + 8, 16);
            if (identifier.ContainsAnyExcept((byte)0))
                return $"windows:{BitConverter.ToUInt64(new ReadOnlySpan<byte>(info, 8)):x}:{Convert.ToHexStringLower(identifier)}";
        }
        // Older file systems and some network shares only offer the 64-bit file index.
        var legacy = stackalloc byte[52];
        if (!GetFileInformationByHandle(handle, legacy)) return null;
        var serial = BitConverter.ToUInt32(new ReadOnlySpan<byte>(legacy + 28, 4));
        var index = (ulong)BitConverter.ToUInt32(new ReadOnlySpan<byte>(legacy + 44, 4)) << 32 | BitConverter.ToUInt32(new ReadOnlySpan<byte>(legacy + 48, 4));
        if (index == 0) return null;
        Span<byte> padded = stackalloc byte[16];
        BitConverter.TryWriteBytes(padded, index);
        return $"windows:{serial:x}:{Convert.ToHexStringLower(padded)}";
    }

    private static SafeFileHandle OpenHandle(string libraryPath, string sourcePath, bool isDirectory)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(libraryPath));
        var target = Path.GetFullPath(sourcePath);
        var relative = Path.GetRelativePath(root, target);
        string[] components = relative == "." ? [] : relative.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
        // ':' would name an alternate data stream; a rooted result means another drive.
        if (Path.IsPathRooted(relative) || (components.Length == 0 && !isDirectory)
            || components.Any(value => value is "." or ".." || value.IndexOfAny([':', '\0', '/']) >= 0))
            throw new IOException("Invalid media path.");
        // Every component below the library must be a plain folder or file. The handle checks
        // below catch a link swapped in after this point.
        var current = root;
        foreach (var component in components)
        {
            current = Path.Combine(current, component);
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new PinnedMediaHandle.UnsafeHandleException();
        }

        var anchor = Owned(CreateFile(Win32Path(root), FileReadAttributes | FileListDirectory, ShareAll, 0, OpenExisting, BackupSemantics, 0));
        string expected;
        try
        {
            if ((AttributesOf(anchor) & AttributeDirectory) == 0) throw new IOException("The storage location is not a folder.");
            if (components.Length == 0) return anchor;
            expected = FinalPath(anchor) + "\\" + string.Join('\\', components);
        }
        catch
        {
            anchor.Dispose();
            throw;
        }
        anchor.Dispose();

        var handle = Owned(CreateFile(Win32Path(target), isDirectory ? FileListDirectory | FileReadAttributes : GenericRead, ShareAll, 0, OpenExisting,
            OpenReparsePoint | (isDirectory ? BackupSemantics : 0), 0));
        try
        {
            var attributes = AttributesOf(handle);
            if ((attributes & AttributeReparsePoint) != 0 || ((attributes & AttributeDirectory) != 0) != isDirectory
                || !string.Equals(FinalPath(handle), expected, StringComparison.OrdinalIgnoreCase))
                throw new PinnedMediaHandle.UnsafeHandleException();
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    /// <summary>Paths beyond the classic 260-character limit need the extended prefix in Win32 calls.</summary>
    private static string Win32Path(string path) =>
        path.Length < 248 || path.StartsWith(@"\\?\", StringComparison.Ordinal) ? path
        : path.StartsWith(@"\\", StringComparison.Ordinal) ? @"\\?\UNC\" + path[2..] : @"\\?\" + path;

    private static SafeFileHandle Owned(SafeFileHandle handle)
    {
        if (!handle.IsInvalid) return handle;
        var error = Marshal.GetLastPInvokeError();
        handle.Dispose();
        // Denied access and unresolvable links are permanent, unlike a drive that is away.
        if (error is 5 or 1920 or 1921) throw new PinnedMediaHandle.UnsafeHandleException();
        throw new IOException("The media handle could not be opened safely.");
    }

    private static uint AttributesOf(SafeFileHandle handle)
    {
        var info = stackalloc uint[2];
        if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, info, 8)) throw new IOException("The media file could not be inspected.");
        return info[0];
    }

    /// <summary>The NT form exists for every volume, including network shares and folders without a drive letter.</summary>
    private static string FinalPath(SafeFileHandle handle)
    {
        var buffer = new char[1024];
        while (true)
        {
            uint length;
            fixed (char* pointer = buffer) length = GetFinalPathNameByHandle(handle, pointer, (uint)buffer.Length, VolumeNameNt);
            if (length == 0) throw new IOException("The media path could not be verified.");
            if (length < buffer.Length) return new string(buffer, 0, (int)length).TrimEnd('\\');
            if (length > 32_768) throw new IOException("The media path is too long.");
            buffer = new char[length + 1];
        }
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial SafeFileHandle CreateFile(string name, uint access, uint share, nint security, uint disposition, uint flags, nint template);

    [LibraryImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", SetLastError = true)]
    private static partial uint GetFinalPathNameByHandle(SafeFileHandle file, char* path, uint length, uint flags);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandleEx(SafeFileHandle file, int infoClass, void* info, uint size);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandle(SafeFileHandle file, void* info);
}
