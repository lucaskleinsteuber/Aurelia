namespace Aurelia.Server.Services;

/// <summary>
/// On Linux a drive mounted through /etc/fstab leaves its empty mount point behind when it is
/// unplugged. A storage location at or below such a mount point must count as unavailable then,
/// not as an empty folder whose titles all disappeared.
/// </summary>
internal static class StorageMounts
{
    private static readonly System.Buffers.SearchValues<char> OctalDigits = System.Buffers.SearchValues.Create("01234567");

    public static bool IsDetached(string path) =>
        OperatingSystem.IsLinux() && IsDetached(path, ReadTargets("/etc/fstab"), ReadTargets("/proc/self/mounts"));

    internal static bool IsDetached(string path, IReadOnlySet<string> configured, IReadOnlySet<string> mounted)
    {
        for (var current = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)); !string.IsNullOrEmpty(current);
             current = Path.GetDirectoryName(current))
        {
            if (current != "/" && configured.Contains(current) && !mounted.Contains(current)) return true;
        }

        return false;
    }

    /// <summary>The mount targets of an fstab-style table (second field, octal escapes decoded).</summary>
    internal static HashSet<string> ParseTargets(IEnumerable<string> lines)
    {
        var targets = new HashSet<string>(StringComparer.Ordinal);
        foreach (var line in lines)
        {
            var fields = line.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2 || fields[0].StartsWith('#') || !fields[1].StartsWith('/')) continue;
            targets.Add(Path.TrimEndingDirectorySeparator(Unescape(fields[1])) is { Length: > 0 } target ? target : "/");
        }

        return targets;
    }

    private static HashSet<string> ReadTargets(string table)
    {
        try { return ParseTargets(File.ReadLines(table)); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return []; }
    }

    private static string Unescape(string value)
    {
        if (!value.Contains('\\', StringComparison.Ordinal)) return value;
        var result = new System.Text.StringBuilder(value.Length);
        for (var index = 0; index < value.Length; index++)
        {
            if (value[index] == '\\' && IsOctal(value, index + 1))
            {
                result.Append((char)Convert.ToInt32(value.Substring(index + 1, 3), 8));
                index += 3;
            }
            else
            {
                result.Append(value[index]);
            }
        }

        return result.ToString();
    }

    private static bool IsOctal(string value, int start) =>
        start + 3 <= value.Length && value.AsSpan(start, 3).IndexOfAnyExcept(OctalDigits) < 0;
}
