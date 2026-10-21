using System.Buffers.Binary;
using System.Runtime.InteropServices;

namespace Aurelia.Server.Services;

internal static partial class FileSystemIdentity
{
    private const int StatBufferLength = 512;
    private const int StatFsBufferLength = 256;

    // Linux file systems whose inode numbers are made up again at every mount: exFAT and FAT
    // number files with iunique(), and FUSE drivers (NTFS-3G, apfs-fuse and others) choose their
    // own. An identity built from them could name a different file after the next mount.
    private static readonly HashSet<long> UnstableLinuxFileSystems =
    [
        0x2011BAB0, // exFAT
        0x4D44, // FAT (vfat, msdos)
        0x65735546, // FUSE
    ];

    public static string? TryRead(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            try
            {
                return WindowsMediaHandle.TryReadIdentity(path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                return null;
            }
        }

        var buffer = new byte[StatBufferLength];
        try
        {
            if (LStat(path, buffer) != 0)
            {
                return null;
            }

            var inode = BinaryPrimitives.ReadUInt64LittleEndian(buffer.AsSpan(8, 8));
            if (OperatingSystem.IsMacOS())
            {
                var device = BinaryPrimitives.ReadUInt32LittleEndian(buffer.AsSpan(0, 4));
                return inode == 0 ? null : $"darwin:{device:x}:{inode:x}";
            }

            if (OperatingSystem.IsLinux())
            {
                var fileSystem = new byte[StatFsBufferLength];
                if (StatFs(path, fileSystem) != 0)
                {
                    return null;
                }

                // 64-bit struct statfs on x64 and arm64: f_type first, f_fsid at byte 56.
                return ForLinux(
                    BinaryPrimitives.ReadInt64LittleEndian(fileSystem.AsSpan(0, 8)),
                    BinaryPrimitives.ReadUInt64LittleEndian(fileSystem.AsSpan(56, 8)),
                    inode);
            }

            var unixDevice = BinaryPrimitives.ReadUInt64LittleEndian(buffer.AsSpan(0, 8));
            return inode == 0 ? null : $"unix:{unixDevice:x}:{inode:x}";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    /// A Linux identity names the file system by its fsid, which ext4, Btrfs and most native
    /// file systems derive from their UUID, instead of the device number that changes when a
    /// USB drive comes back as another device. File systems without lasting inode numbers get
    /// no identity, so files there are matched by path alone.
    /// </summary>
    internal static string? ForLinux(long fileSystemType, ulong fileSystemId, ulong inode) =>
        inode == 0 || UnstableLinuxFileSystems.Contains(fileSystemType)
            ? null
            : $"linux:{fileSystemId:x}:{inode:x}";

    [LibraryImport("libc", EntryPoint = "lstat", StringMarshalling = StringMarshalling.Utf8)]
    private static partial int LStat(string path, [Out] byte[] buffer);

    [LibraryImport("libc", EntryPoint = "statfs", StringMarshalling = StringMarshalling.Utf8)]
    private static partial int StatFs(string path, [Out] byte[] buffer);
}
