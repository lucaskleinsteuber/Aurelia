namespace Aurelia.Contracts;

public static class ServerFeatures
{
    public static IReadOnlyList<string> All { get; } = Array.AsReadOnly(new[]
    {
        "library-state-v1", "server-readiness-v1", "device-authorization-v1", "artwork-variants-v1",
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
