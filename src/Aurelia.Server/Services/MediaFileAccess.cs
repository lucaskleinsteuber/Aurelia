using Aurelia.Server.Data;

namespace Aurelia.Server.Services;

public sealed record OpenMediaFile(
    FileStream Stream,
    string ContentType,
    long Length,
    DateTimeOffset LastModified);

public static class MediaFileAccess
{
    private static readonly Dictionary<string, string> ContentTypes =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            [".mkv"] = "video/x-matroska",
            [".mp4"] = "video/mp4",
            [".mov"] = "video/quicktime",
            [".m4v"] = "video/x-m4v",
            [".avi"] = "video/x-msvideo",
            [".webm"] = "video/webm",
        };

    private static readonly HashSet<string> PackageExtensions = new(
        [".app", ".bundle", ".framework", ".plugin", ".pkg", ".xcodeproj"],
        StringComparer.OrdinalIgnoreCase);

    public static OpenMediaFile OpenRead(MediaItem mediaItem)
    {
        var sourcePath = mediaItem.SourcePath;
        var libraryPath = mediaItem.LibraryRoot.Path;
        if (!Path.IsPathFullyQualified(sourcePath)
            || !Path.IsPathFullyQualified(libraryPath))
        {
            throw Unavailable();
        }

        string fullSourcePath;
        string normalizedSourcePath;
        string normalizedLibraryPath;
        try
        {
            fullSourcePath = Path.GetFullPath(sourcePath);
            normalizedSourcePath = MediaPath.Normalize(fullSourcePath);
            normalizedLibraryPath = MediaPath.Normalize(libraryPath);
        }
        catch (Exception exception) when (exception is ArgumentException
                                           or NotSupportedException
                                           or PathTooLongException)
        {
            throw Unavailable();
        }

        if (normalizedSourcePath == normalizedLibraryPath
            || !MediaPath.IsSameOrDescendant(normalizedSourcePath, normalizedLibraryPath)
            || normalizedSourcePath != mediaItem.NormalizedSourcePath)
        {
            throw Unavailable();
        }

        var extension = Path.GetExtension(fullSourcePath);
        if (!ContentTypes.TryGetValue(extension, out var contentType)
            || !string.Equals(extension, mediaItem.Extension, StringComparison.OrdinalIgnoreCase))
        {
            throw Unavailable();
        }

        EnsureSafePath(libraryPath, fullSourcePath);

        try
        {
            var file = new FileInfo(fullSourcePath);
            file.Refresh();
            if (!file.Exists
                || file.LinkTarget is not null
                || (file.Attributes & (FileAttributes.Directory
                                       | FileAttributes.Hidden
                                       | FileAttributes.ReparsePoint)) != 0)
            {
                throw Unavailable();
            }

            var stream = PinnedMediaHandle.Open(libraryPath, fullSourcePath);
            try
            {
                file.Refresh();
                if (!file.Exists || file.LinkTarget is not null)
                {
                    throw Unavailable();
                }

                return new OpenMediaFile(
                    stream,
                    contentType,
                    stream.Length,
                    new DateTimeOffset(File.GetLastWriteTimeUtc(stream.SafeFileHandle), TimeSpan.Zero));
            }
            catch
            {
                stream.Dispose();
                throw;
            }
        }
        catch (PlaybackException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException
                                           or UnauthorizedAccessException
                                           or NotSupportedException)
        {
            throw Unavailable();
        }
    }

    private static void EnsureSafePath(string libraryPath, string sourcePath)
    {
        var relativePath = Path.GetRelativePath(libraryPath, sourcePath);
        var components = relativePath.Split(
            Path.DirectorySeparatorChar,
            StringSplitOptions.RemoveEmptyEntries);
        if (components.Length == 0 || components.Any(component => component is "." or ".."))
        {
            throw Unavailable();
        }

        var currentPath = Path.GetFullPath(libraryPath);
        try
        {
            var library = new DirectoryInfo(currentPath);
            if (!library.Exists
                || library.LinkTarget is not null
                || (library.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw Unavailable();
            }

            for (var index = 0; index < components.Length - 1; index += 1)
            {
                var component = components[index];
                if (component.StartsWith('.') || PackageExtensions.Contains(Path.GetExtension(component)))
                {
                    throw Unavailable();
                }

                currentPath = Path.Combine(currentPath, component);
                var directory = new DirectoryInfo(currentPath);
                if (!directory.Exists
                    || directory.LinkTarget is not null
                    || (directory.Attributes & (FileAttributes.Hidden | FileAttributes.ReparsePoint)) != 0)
                {
                    throw Unavailable();
                }
            }

            if (components[^1].StartsWith('.'))
            {
                throw Unavailable();
            }
        }
        catch (PlaybackException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException
                                           or UnauthorizedAccessException
                                           or NotSupportedException)
        {
            throw Unavailable();
        }
    }

    private static PlaybackException Unavailable()
    {
        return new PlaybackException(
            "media_file_unavailable",
            "The media file is not currently available for playback.",
            StatusCodes.Status409Conflict);
    }
}
