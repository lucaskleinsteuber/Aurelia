using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class PrivateFilePermissionsTests
{
    [Fact]
    public void ProtectsRegularFilesSkipsMissingOnesAndRejectsLinks()
    {
        if (OperatingSystem.IsWindows()) return;
        var root = Directory.CreateTempSubdirectory("aurelia-private-");
        try
        {
            var database = Path.Combine(root.FullName, "aurelia.db");
            File.WriteAllBytes(database, [1]);
            File.SetUnixFileMode(database, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead | UnixFileMode.OtherRead);

            PrivateFilePermissions.ProtectFile(database);
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(database));

            // SQLite removes -wal and -shm when its last connection closes.
            PrivateFilePermissions.ProtectFile($"{database}-wal");

            var link = Path.Combine(root.FullName, "aurelia.db-shm");
            File.CreateSymbolicLink(link, database);
            Assert.Throws<IOException>(() => PrivateFilePermissions.ProtectFile(link));
        }
        finally { root.Delete(recursive: true); }
    }
}
