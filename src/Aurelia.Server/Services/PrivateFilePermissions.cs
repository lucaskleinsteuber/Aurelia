namespace Aurelia.Server.Services;

public static class PrivateFilePermissions
{
    public static void CreatePrivateDirectory(string path)
    {
        if (Directory.Exists(path) && new DirectoryInfo(path).LinkTarget is not null)
            throw new IOException("Private server directories cannot be symbolic links.");
        Directory.CreateDirectory(path);
        UnixFileIdentity.RequireOwned(path);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(
                path,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
    }

    public static void ProtectFile(string path)
    {
        if (File.Exists(path) && new FileInfo(path).LinkTarget is not null)
            throw new IOException("Private server files cannot be symbolic links.");
        if (File.Exists(path) && !OperatingSystem.IsWindows())
        {
            try
            {
                UnixFileIdentity.RequireOwned(path);
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
            // SQLite deletes its -wal and -shm files when the last connection closes; a file that
            // is gone by now has nothing left to protect.
            catch (IOException) when (!File.Exists(path) && !Directory.Exists(path)) { }
        }
    }

    public static FileStream OpenNewPrivateFile(string path)
    {
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None, Options = FileOptions.Asynchronous };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        return new FileStream(path, options);
    }

    /// <summary>Writes UTF-8 text to a private owner-only (0600) file without leaving a world-readable window.</summary>
    public static void WritePrivateText(string path, string content)
    {
        if (File.Exists(path) && new FileInfo(path).LinkTarget is not null)
            throw new IOException("Private server files cannot be symbolic links.");
        var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write, Share = FileShare.Read };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        using (var stream = new FileStream(path, options))
        using (var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false)))
        {
            writer.Write(content);
        }
        ProtectFile(path);
    }
}
