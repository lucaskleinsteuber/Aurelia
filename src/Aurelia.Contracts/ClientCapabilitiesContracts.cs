namespace Aurelia.Contracts;

public static class ServerFeatures
{
    /// <summary>Catalog lists accept pages of up to this many entries ("catalog-pages-500-v1").</summary>
    public const int MaximumCatalogPageSize = 500;

    public static IReadOnlyList<string> All { get; } = Array.AsReadOnly(new[]
    {
        "library-state-v1", "server-readiness-v1", "device-authorization-v1", "artwork-variants-v1",
        "catalog-pages-500-v1",
    });
}

public sealed record ClientCapabilitiesResponse(
    int FormatVersion,
    string MinimumClientVersion,
    bool ProfilePins,
    bool OptionalProfilePins,
    bool AtomicProfileEditing,
    bool AutomaticManagementApprovals,
    bool SceneNotes,
    bool TitleAccess,
    IReadOnlyList<string> Capabilities);
