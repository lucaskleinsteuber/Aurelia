using System.Reflection;

namespace Aurelia.Linux.Core;

/// <summary>The product name and the version this build carries.</summary>
public static class AppInfo
{
    public const string ProductName = "Aurelia";

    /// <summary>The desktop file and Wayland app id; it also names the Flatpak.</summary>
    /// <summary>
    /// "Aurelia Test": the same program started with <c>AURELIA_EDITION=test</c>. It keeps its own settings,
    /// keyring entries, hosted server and ports beside the real app, and its Settings offer Reset App Data.
    /// </summary>
    public static bool IsTestEdition { get; } = Environment.GetEnvironmentVariable("AURELIA_EDITION") == "test";

    public static string ApplicationId { get; } = IsTestEdition ? "io.github.lucasfd3.Aurelia.Test" : "io.github.lucasfd3.Aurelia";

    /// <summary>The name in window titles: "Aurelia", or "Aurelia Test" for the test edition.</summary>
    public static string DisplayName => IsTestEdition ? "Aurelia Test" : ProductName;

    /// <summary>Version and build, for example "0.1.0 (1)".</summary>
    private static string? InformationalVersion => typeof(AppInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;

    public static string DisplayVersion { get; } = FormatVersion(InformationalVersion);

    public static Version CurrentVersion { get; } = Version.TryParse(InformationalVersion?.Split('+')[0], out var version) ? version : new Version(0, 0, 0);

    public static int Build { get; } = int.TryParse(InformationalVersion?.Split("build.").Last().Split('.')[0], out var build) ? build : 0;

    public const string RepositoryUrl = "https://github.com/lucaskleinsteuber/Aurelia";
    public const string PrivacyPolicyUrl = RepositoryUrl + "/blob/main/docs/PRIVACY.md";

    public const string Copyright = "© 2026 Lucas Kleinsteuber";

    /// <summary>What changed in this version, from the changelog built into the app.</summary>
    public static IReadOnlyList<string> WhatsNew { get; } = ChangesIn(Changelog(), CurrentVersion.ToString(3));

    /// <summary>
    /// The bullets of "## Linux Desktop &lt;version&gt; …" in a Keep a Changelog file, without the
    /// section headings and Markdown marks.
    /// </summary>
    public static IReadOnlyList<string> ChangesIn(string? changelog, string version)
    {
        if (string.IsNullOrEmpty(changelog)) return [];
        var lines = changelog.Split('\n');
        var start = Array.FindIndex(lines, line => line.StartsWith($"## Linux Desktop {version} ", StringComparison.Ordinal));
        if (start < 0) return [];
        var changes = new List<string>();
        for (var index = start + 1; index < lines.Length && !lines[index].StartsWith("## ", StringComparison.Ordinal); index++)
        {
            var line = lines[index].Trim();
            if (line.StartsWith("- ", StringComparison.Ordinal)) changes.Add(line[2..].Replace("**", "", StringComparison.Ordinal).Replace("`", "", StringComparison.Ordinal));
        }
        return changes;
    }

    private static string? Changelog()
    {
        using var stream = typeof(AppInfo).Assembly.GetManifestResourceStream("CHANGELOG.md");
        if (stream is null) return null;
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    public static string FormatVersion(string? informationalVersion)
    {
        if (string.IsNullOrWhiteSpace(informationalVersion)) return "0.0.0";
        var version = informationalVersion.Split('+', 2);
        if (version.Length == 2 && version[1].StartsWith("build.", StringComparison.Ordinal))
        {
            var build = version[1]["build.".Length..].Split('.', 2)[0];
            return $"{version[0]} ({build})";
        }
        return version[0];
    }
}
