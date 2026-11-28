using System.Text;

namespace Tarven.Server.Services;

public static class MediaPath
{
    public static string Normalize(string path)
    {
        var fullPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path))
            .Normalize(NormalizationForm.FormC);
        return OperatingSystem.IsLinux() ? fullPath : fullPath.ToUpperInvariant();
    }

    /// <summary>
    /// Normalizes a library-relative path consistently with <see cref="Normalize"/>: NFC Unicode
    /// normalization, platform separators, and case folding only on case-insensitive OSes.
    /// </summary>
    public static string NormalizeRelative(string path, char separator = '\0')
    {
        var targetSeparator = separator == '\0' ? Path.DirectorySeparatorChar : separator;
        var altSeparator = targetSeparator == '/' ? '\\' : '/';
        var normalized = path.Replace(altSeparator, targetSeparator)
            .Trim(targetSeparator)
            .Normalize(NormalizationForm.FormC);
        return OperatingSystem.IsLinux() ? normalized : normalized.ToUpperInvariant();
    }

    public static bool Overlaps(string firstNormalizedPath, string secondNormalizedPath)
    {
        return IsSameOrDescendant(firstNormalizedPath, secondNormalizedPath)
            || IsSameOrDescendant(secondNormalizedPath, firstNormalizedPath);
    }

    public static bool IsSameOrDescendant(string path, string directory)
    {
        if (path.Equals(directory, StringComparison.Ordinal))
        {
            return true;
        }

        return path.StartsWith(
            directory + Path.DirectorySeparatorChar,
            StringComparison.Ordinal);
    }
}
