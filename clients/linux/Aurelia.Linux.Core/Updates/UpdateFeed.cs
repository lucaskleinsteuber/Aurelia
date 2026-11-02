using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Updates;

/// <summary>Only these owner-controlled feeds can supply an update.</summary>
public static class UpdateFeed
{
    public const string StandardRepository = "lucaskleinsteuber/Aurelia";
    public const string PublicTestRepository = "lucaskleinsteuber/Aurelia-Update-Test";
    public const string PublicTestKey = "publicUpdateTestEnabled";

    public static bool IsPublicTest(ISettingsStore? settings) => settings?.Read<bool?>(PublicTestKey) == true;
    public static string Repository(ISettingsStore? settings) => IsPublicTest(settings) ? PublicTestRepository : StandardRepository;
    public static bool IsAllowed(string repository) => repository is StandardRepository or PublicTestRepository;
}
