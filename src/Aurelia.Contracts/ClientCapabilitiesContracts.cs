namespace Aurelia.Contracts;

public static class ServerFeatures
{
    /// <summary>Catalog lists accept pages of up to this many entries ("catalog-pages-500-v1").</summary>
    public const int MaximumCatalogPageSize = 500;

    public static IReadOnlyList<string> All { get; } = Array.AsReadOnly(new[]
    {
        "library-state-v1", "server-readiness-v1", "device-authorization-v1", "artwork-variants-v1",
        "catalog-pages-500-v1", PreviewStreams, WebApp,
    });

    /// <summary>
    /// Stream reads marked "X-Aurelia-Stream-Purpose: preview" have their own concurrency and
    /// request budget, so clients may prepare timeline previews on several decoders.
    /// </summary>
    public const string PreviewStreams = "preview-streams-v1";

    /// <summary>The server serves the browser app and its cookie sign-in (docs/WEB_APP.md).</summary>
    public const string WebApp = "web-app-v1";
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
