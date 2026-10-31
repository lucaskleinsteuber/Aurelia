namespace Aurelia.Linux.Core.Settings;

/// <summary>Folders and files that only the current user may open (0700 and 0600 on Linux).</summary>
public static class PrivateFiles
{
    public static void CreateDirectory(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            Directory.CreateDirectory(path);
            return;
        }
        Directory.CreateDirectory(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    public static void WriteAllText(string path, string contents)
    {
        if (OperatingSystem.IsWindows())
        {
            File.WriteAllText(path, contents);
            return;
        }
        using var stream = new FileStream(path, new FileStreamOptions
        {
            Mode = FileMode.Create,
            Access = FileAccess.Write,
            UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite,
        });
        using var writer = new StreamWriter(stream);
        writer.Write(contents);
    }
}
