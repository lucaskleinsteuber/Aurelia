using System.Buffers.Binary;
using System.Runtime.InteropServices;

namespace Aurelia.Server.Services;

internal static partial class FileSystemIdentity
{
    private const int StatBufferLength = 512;

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
            var device = OperatingSystem.IsMacOS()
                ? BinaryPrimitives.ReadUInt32LittleEndian(buffer.AsSpan(0, 4))
                : BinaryPrimitives.ReadUInt64LittleEndian(buffer.AsSpan(0, 8));
            return inode == 0
                ? null
                : $"{(OperatingSystem.IsMacOS() ? "darwin" : "unix")}:{device:x}:{inode:x}";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    [LibraryImport("libc", EntryPoint = "lstat", StringMarshalling = StringMarshalling.Utf8)]
    private static partial int LStat(string path, [Out] byte[] buffer);
}
