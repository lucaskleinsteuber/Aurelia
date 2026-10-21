using Aurelia.Contracts;

namespace Aurelia.Server.Services;

/// <summary>
/// Lists folders on the server computer so an owner or administrator on another computer can
/// choose a storage location there. It shows folder names only, never files or their contents,
/// and changes nothing. Links are left out, as storage locations cannot be links.
/// </summary>
public static class ServerFolderBrowser
{
    private const int MaximumFolders = 2_000;

    // Kernel and system folders that never hold media on Linux.
    private static readonly HashSet<string> LinuxSystemFolders =
        ["/proc", "/sys", "/dev", "/run", "/boot", "/etc", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/usr", "/var",
            "/tmp", "/snap", "/lost+found", "/opt", "/root", "/cdrom"];

    public static ServerFolderListing List(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return new(null, null, Places());
        if (!System.IO.Path.IsPathFullyQualified(path))
            throw new LibraryException("folder_path_invalid", "Choose a folder by its full path on the server.", StatusCodes.Status400BadRequest);
        var full = System.IO.Path.GetFullPath(path);
        var directory = new DirectoryInfo(full);
        if (!directory.Exists || directory.LinkTarget is not null)
            throw new LibraryException("folder_not_found", "This folder is not available on the server.", StatusCodes.Status404NotFound);
        try
        {
            var folders = directory.EnumerateDirectories()
                .Where(child => child.LinkTarget is null && !child.Name.StartsWith('.')
                    && (child.Attributes & (FileAttributes.Hidden | FileAttributes.System)) == 0
                    && !(OperatingSystem.IsLinux() && LinuxSystemFolders.Contains(child.FullName)))
                .Take(MaximumFolders + 1)
                .Select(child => new ServerFolder(child.Name, child.FullName))
                .ToList();
            if (folders.Count > MaximumFolders)
                throw new LibraryException("folder_too_large", "This folder contains too many folders. Choose a folder further down.", StatusCodes.Status413PayloadTooLarge);
            return new(full, directory.Parent?.FullName,
                [.. folders.OrderBy(folder => folder.Name, StringComparer.CurrentCultureIgnoreCase)]);
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or IOException)
        {
            throw new LibraryException("folder_unreadable", "Aurelia Server may not read this folder.", StatusCodes.Status403Forbidden);
        }
    }

    /// <summary>Where drives and media usually are on this kind of computer.</summary>
    internal static IReadOnlyList<ServerFolder> Places()
    {
        if (OperatingSystem.IsWindows())
        {
            return [.. DriveInfo.GetDrives().Where(drive => drive.IsReady && drive.DriveType is DriveType.Fixed or DriveType.Removable or DriveType.Network)
                .Select(drive => new ServerFolder(drive.Name.TrimEnd('\\'), drive.RootDirectory.FullName))];
        }

        var candidates = OperatingSystem.IsMacOS()
            ? new[] { ("Drives", "/Volumes"), ("Home", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)) }
            : [("Mounted Drives", "/mnt"), ("Removable Drives", "/media"), ("Server Data", "/srv"), ("Home Folders", "/home")];
        return [.. candidates.Where(place => !string.IsNullOrEmpty(place.Item2) && Directory.Exists(place.Item2))
            .Select(place => new ServerFolder(place.Item1, place.Item2))
            .Append(new ServerFolder("Computer", "/"))];
    }
}
