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
            UnixFileIdentity.RequireOwned(path);
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }

    public static FileStream OpenNewPrivateFile(string path)
    {
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None, Options = FileOptions.Asynchronous };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        return new FileStream(path, options);
    }
}
