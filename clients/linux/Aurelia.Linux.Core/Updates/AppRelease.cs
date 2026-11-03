using System.Globalization;
using System.Text.Json.Nodes;

namespace Aurelia.Linux.Core.Updates;

public enum LinuxPackageKind { Debian, Rpm, Arch, Flatpak }

/// <summary>A Linux app release, independent of the Mac/server releases in the repository. A beta is a
/// GitHub pre-release, offered only when beta updates are on.</summary>
public sealed record AppRelease(string Tag, Version Version, int Build, string Notes, string FileName, Uri Download,
    Uri Checksums, long Bytes, string SourceRepository = UpdateFeed.StandardRepository, bool IsBeta = false)
{
    public const string Repository = UpdateFeed.StandardRepository;
    public const string TagPrefix = "linux-app-";

    public static (Version Version, int Build)? ParseTag(string tag)
    {
        if (!tag.StartsWith(TagPrefix, StringComparison.Ordinal)) return null;
        var parts = tag[TagPrefix.Length..].Split('-');
        if (parts.Length != 2 || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var build)
            || build < 1 || build.ToString(CultureInfo.InvariantCulture) != parts[1]) return null;
        var numbers = parts[0].Split('.');
        if (numbers.Length != 3 || numbers.Any(n => !int.TryParse(n, NumberStyles.None, CultureInfo.InvariantCulture, out var v)
            || v < 0 || v.ToString(CultureInfo.InvariantCulture) != n) || !Version.TryParse(parts[0], out var version)) return null;
        return (version, build);
    }

    public static string PackageName(Version version, int build, LinuxPackageKind kind) =>
        $"Aurelia-Desktop-{version}-{build}-" + (kind switch
        {
            LinuxPackageKind.Debian => "amd64.deb",
            LinuxPackageKind.Rpm => "x86_64.rpm",
            LinuxPackageKind.Arch => "x86_64.pkg.tar.zst",
            _ => "x86_64.flatpak",
        });

    public static AppRelease? Newest(JsonArray releases, LinuxPackageKind kind, Version currentVersion, int currentBuild, string repository = Repository,
        bool includeBeta = false)
    {
        if (!UpdateFeed.IsAllowed(repository)) return null;
        var candidates = new List<AppRelease>();
        foreach (var node in releases.OfType<JsonObject>())
        {
            var beta = node["prerelease"]?.GetValue<bool>() == true;
            if (node["draft"]?.GetValue<bool>() == true || (beta && !includeBeta)
                || node["tag_name"]?.GetValue<string>() is not { } tag || ParseTag(tag) is not { } parsed
                || parsed.Build <= currentBuild || parsed.Version < currentVersion || node["assets"] is not JsonArray assets) continue;
            var name = PackageName(parsed.Version, parsed.Build, kind);
            JsonObject? Asset(string file) => assets.OfType<JsonObject>().FirstOrDefault(a => a["name"]?.GetValue<string>() == file && a["state"]?.GetValue<string>() == "uploaded");
            var package = Asset(name);
            var sums = Asset("SHA256SUMS");
            if (package?["url"]?.GetValue<string>() is not { } address || sums?["url"]?.GetValue<string>() is not { } checksums
                || !IsAssetUrl(address, repository) || !IsAssetUrl(checksums, repository) || package["size"]?.GetValue<long>() is not > 0) continue;
            candidates.Add(new(tag, parsed.Version, parsed.Build, node["body"]?.GetValue<string>() ?? "", name,
                new Uri(address), new Uri(checksums), package["size"]!.GetValue<long>(), repository, beta));
        }
        return candidates.OrderByDescending(c => c.Version).ThenByDescending(c => c.Build).FirstOrDefault();
    }

    public static bool IsAssetUrl(string value, string repository = Repository) => UpdateFeed.IsAllowed(repository) && Uri.TryCreate(value, UriKind.Absolute, out var uri)
        && uri.Scheme == "https" && uri.Host == "api.github.com" && uri.IsDefaultPort
        && uri.UserInfo.Length == 0 && uri.Query.Length == 0 && uri.Fragment.Length == 0
        && uri.AbsolutePath.StartsWith($"/repos/{repository}/releases/assets/", StringComparison.Ordinal)
        && long.TryParse(uri.Segments.Last(), NumberStyles.None, CultureInfo.InvariantCulture, out var id) && id > 0;

    public static string? Checksum(string fileName, string sums)
    {
        var hashes = new List<string>();
        foreach (var line in sums.Split('\n'))
        {
            var fields = line.Trim().Split((char[]?)null, 2, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length != 2) continue;
            var name = fields[1].TrimStart('*');
            if (name.StartsWith("./", StringComparison.Ordinal)) name = name[2..];
            if (name == fileName && fields[0].Length == 64 && fields[0].All(char.IsAsciiHexDigit)) hashes.Add(fields[0].ToLowerInvariant());
        }
        return hashes.Count == 1 ? hashes[0] : null;
    }
}
