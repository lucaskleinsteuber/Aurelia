namespace Aurelia.Contracts;

public static class ServerFeatures
{
    /// <summary>Catalog lists accept pages of up to this many entries ("catalog-pages-500-v1").</summary>
    public const int MaximumCatalogPageSize = 500;

    public static IReadOnlyList<string> All { get; } = Array.AsReadOnly(new[]
    {
        "library-state-v1", "server-readiness-v1", "device-authorization-v1", "artwork-variants-v1",
        "catalog-pages-500-v1", PreviewStreams, WebApp, ProfilePersonalization, AgeLimits,
        WebPairingCode, CinemaTrailers, MovieNight, YearWrapped, MonthlyWrapped, MediaSegments, ServerSpeech, Suggestions,
        ScreenTime, Wishes,
    });

    /// <summary>
    /// Intro and credits times found by the server come with the playback ticket and can be
    /// corrected ("media-segments-v2", docs/CLIENT_PROTOCOL.md). "media-segments-v1" was removed in
    /// 1.7.9 and is never reported again.
    /// </summary>
    public const string MediaSegments = "media-segments-v2";

    /// <summary>Movie Night: the household swipes through one deck until everyone likes a title ("movie-night-v1").</summary>
    public const string MovieNight = "movie-night-v1";

    /// <summary>A profile's year as slides with cheeky lines ("year-wrapped-v1", docs/CLIENT_PROTOCOL.md).</summary>
    public const string YearWrapped = "year-wrapped-v1";

    /// <summary>
    /// Wrapped for one month, ready from the 2nd of the following month ("monthly-wrapped-v1",
    /// docs/CLIENT_PROTOCOL.md).
    /// </summary>
    public const string MonthlyWrapped = "monthly-wrapped-v1";

    /// <summary>
    /// The browser app signs in with the pairing code from the main device, like every other
    /// client ("web-pairing-code-v1").
    /// </summary>
    public const string WebPairingCode = "web-pairing-code-v1";

    /// <summary>
    /// Trailers of films the profile has not watched yet, for a film's pre-show in cinema mode
    /// ("cinema-trailers-v1", docs/CLIENT_PROTOCOL.md).
    /// </summary>
    public const string CinemaTrailers = "cinema-trailers-v1";

    /// <summary>
    /// Subtitles from speech and Sync to Speech on the server with whisper.cpp ("server-speech-v1"):
    /// GET /api/v1/media/{id}/speech says whether it is installed and has a model.
    /// </summary>
    public const string ServerSpeech = "server-speech-v1";

    /// <summary>
    /// Suggestions of what to watch next ("suggestions-v1"): GET /api/v1/media/{id}/suggestions and
    /// Home's "Because You Watched" rails, each suggestion with its reason.
    /// </summary>
    public const string Suggestions = "suggestions-v1";

    /// <summary>Display names and profile pictures ("profile-personalization-v1").</summary>
    public const string ProfilePersonalization = "profile-personalization-v1";

    /// <summary>Children's profiles limited by FSK age, with per-title exceptions ("age-limits-v1").</summary>
    public const string AgeLimits = "age-limits-v1";

    /// <summary>Bedtime, a daily limit and "one more episode" for children's profiles ("screen-time-v1", docs/SCREEN_TIME.md).</summary>
    public const string ScreenTime = "screen-time-v1";

    /// <summary>Family wishlist ("wishes-v1", docs/WISHES.md).</summary>
    public const string Wishes = "wishes-v1";

    /// <summary>
    /// User-created collections, smart lists, franchises, and collection management ("collections-v2").
    /// </summary>
    public const string CollectionsV2 = "collections-v2";

    /// <summary>
    /// Box Sets: collection descriptions, custom/mosaic artwork, sort modes, season and episode members, box progress, next-to-play, provider and editability ("collections-v3").
    /// </summary>
    public const string CollectionsV3 = "collections-v3";

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

    /// <summary>
    /// A sound track can be read as 16 kHz mono PCM and subtitles written from it saved
    /// (docs/CLIENT_PROTOCOL.md). Reported when the server's ffmpeg can write plain PCM.
    /// </summary>
    public const string SpeechSubtitles = "speech-subtitles-v1";

    /// <summary>
    /// Subtitles a device moved to fit the speech can be saved as a "Synced" copy
    /// (docs/CLIENT_PROTOCOL.md). Reported together with <see cref="SpeechSubtitles"/>.
    /// </summary>
    public const string SubtitleSync = "subtitle-sync-v1";

    /// <summary>
    /// A title can be streamed over HLS in several qualities, converted live and kept in memory
    /// only (docs/CLIENT_PROTOCOL.md). Reported when the server's ffmpeg can encode pictures.
    /// </summary>
    public const string AdaptiveStreaming = "adaptive-streaming-v1";

    /// <summary>The features this server reports: <see cref="All"/> and those its host provides.</summary>
    public static IReadOnlyList<string> Reported(bool liveConversion, bool speechAudio = false, bool adaptiveStreaming = false)
    {
        if (!liveConversion) return Array.AsReadOnly([.. All, WatchlistAndPeople, CollectionsV2, CollectionsV3, RemotePlayback]);
        List<string> features = [.. All, WatchlistAndPeople, CollectionsV2, CollectionsV3, RemotePlayback, LiveConversion, ScrubPreviews];
        if (speechAudio) features.AddRange([SpeechSubtitles, SubtitleSync]);
        if (adaptiveStreaming) features.Add(AdaptiveStreaming);
        return features.AsReadOnly();
    }
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
