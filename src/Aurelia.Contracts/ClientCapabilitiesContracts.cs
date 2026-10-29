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
    /// User-created collections, smart lists, franchises, and collection management ("collections-v2").
    /// </summary>
    public const string CollectionsV2 = "collections-v2";

    /// <summary>
    /// Remote playback command queue and active player reporting ("remote-playback-v1").
    /// </summary>
    public const string RemotePlayback = "remote-playback-v1";

    /// <summary>
    /// Stream reads marked "X-Aurelia-Stream-Purpose: preview" have their own concurrency and
    /// request budget, so clients may prepare timeline previews on several decoders.
    /// </summary>
    public const string PreviewStreams = "preview-streams-v1";

    /// <summary>The server serves the browser app and its cookie sign-in (docs/WEB_APP.md).</summary>
    public const string WebApp = "web-app-v1";

    /// <summary>
    /// The server provides a shared per-profile watchlist and navigable cast and crew person pages.
    /// </summary>
    public const string WatchlistAndPeople = "watchlist-people-v1";

    /// <summary>
    /// The server can convert a title live into fragmented MP4 (docs/CLIENT_PROTOCOL.md). It is
    /// only reported when the server found a working ffmpeg, so it is not part of <see cref="All"/>.
    /// </summary>
    public const string LiveConversion = "live-conversion-v1";

    /// <summary>
    /// The server can extract small timeline preview stills and optionally store bounded strips in
    /// its data folder when configured. Reported when the server found a working ffmpeg.
    /// </summary>
    public const string ScrubPreviews = "scrub-previews-v1";

    /// <summary>The features this server reports: <see cref="All"/> and those its host provides.</summary>
    public static IReadOnlyList<string> Reported(bool liveConversion) =>
        liveConversion
            ? Array.AsReadOnly([.. All, WatchlistAndPeople, CollectionsV2, RemotePlayback, LiveConversion, ScrubPreviews])
            : Array.AsReadOnly([.. All, WatchlistAndPeople, CollectionsV2, RemotePlayback]);
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
