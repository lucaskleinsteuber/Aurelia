using System.Text;

namespace Aurelia.Home.Server.Services;

public static class MediaPath
{
    public static string Normalize(string path)
    {
        var fullPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path))
            .Normalize(NormalizationForm.FormC);
        return OperatingSystem.IsLinux() ? fullPath : fullPath.ToUpperInvariant();
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
