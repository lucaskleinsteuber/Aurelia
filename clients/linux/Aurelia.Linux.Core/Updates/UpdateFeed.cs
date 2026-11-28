using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Updates;

/// <summary>Only these owner-controlled feeds can supply an update.</summary>
public static class UpdateFeed
{
    public const string StandardRepository = "lucaskleinsteuber/Aurelia";
    /// <summary>
    /// Aurelia's new name is Tarven, and the repository is renamed to it. This version looks there
    /// first and falls back to the old name until the rename, so it finds the first Tarven release
    /// (GitHub's redirect for a renamed repository is never followed).
    /// </summary>
    public const string RenamedRepository = "lucaskleinsteuber/Tarven";
    public const string PublicTestRepository = "lucaskleinsteuber/Aurelia-Update-Test";
    public const string PublicTestKey = "publicUpdateTestEnabled";

    /// <summary>
    /// The owner's minisign public key (the second line of minisign.pub). Every Linux release signs
    /// its SHA256SUMS with the matching secret key, which never goes to GitHub. While this is empty,
    /// this build installs no update at all. See docs/LINUX_UPDATE_SIGNING.md.
    /// </summary>
    public const string SigningPublicKey = "RWT0nYptHNjXQSXnVurY9XXdPF2Ssq5sUlSP+WoBwjA5GPXWnugBc7lE";

    public static bool IsPublicTest(ISettingsStore? settings) => settings?.Read<bool?>(PublicTestKey) == true;
    public static string Repository(ISettingsStore? settings) => IsPublicTest(settings) ? PublicTestRepository : StandardRepository;
    public static bool IsAllowed(string repository) => repository is StandardRepository or RenamedRepository or PublicTestRepository;

    /// <summary>The feeds to ask, in order; the next one only when a feed does not exist.</summary>
    public static IReadOnlyList<string> Repositories(ISettingsStore? settings) =>
        IsPublicTest(settings) ? [PublicTestRepository] : [RenamedRepository, StandardRepository];

    /// <summary>Whether a release found in <paramref name="repository"/> belongs to the selected feed.</summary>
    public static bool Serves(ISettingsStore? settings, string repository) => Repositories(settings).Contains(repository);
}
