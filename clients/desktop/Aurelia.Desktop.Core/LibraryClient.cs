using System.Globalization;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>What the library and the player ask the server, so both can be tested without a network.</summary>
public interface ILibraryApi
{
    Task<HomeResponse> HomeAsync(CancellationToken cancellation);
    Task<PagedResponse<CatalogItemSummary>> BrowseAsync(MediaKind kind, CatalogFilter filter, int offset, int limit, CancellationToken cancellation);
    Task<PagedResponse<CatalogItemSummary>> SearchAsync(string term, int offset, int limit, CancellationToken cancellation);
    Task<CatalogDetailPresentation> DetailAsync(Guid id, CancellationToken cancellation);
    Task<PlaybackPlanResponse> PlaybackPlanAsync(Guid id, CancellationToken cancellation);
    Task<bool> SetFavoriteAsync(Guid id, bool favorite, CancellationToken cancellation);
    /// <summary>Whether a title, a season or a whole series counts as watched, with the token a change needs.</summary>
    Task<WatchStateResponse> WatchStateAsync(Guid id, WatchStateScope scope, int? season, CancellationToken cancellation);
    Task<WatchStateResponse> SetWatchedAsync(Guid id, bool watched, WatchStateScope scope, int? season, string stateToken,
        CancellationToken cancellation);
    Task<byte[]> ArtworkAsync(ArtworkSummary artwork, int width, CancellationToken cancellation);
    Task<PlaybackSourceResponse> CreatePlaybackAsync(Guid mediaId, CancellationToken cancellation);
    Task RevokePlaybackAsync(Guid ticketId, CancellationToken cancellation);
    Task<PlaybackProgressResponse> ProgressAsync(Guid mediaId, CancellationToken cancellation);
    Task<PlaybackProgressResponse> SaveProgressAsync(Guid mediaId, long position, long duration, bool finished,
        long expectedRevision, Guid mutationId, CancellationToken cancellation);
    Task<IReadOnlyList<string>> CapabilitiesAsync(CancellationToken cancellation);
    /// <summary>Where the stream relay reads a ticket's media from, with the profile's token.</summary>
    StreamSource StreamSource(PlaybackSourceResponse ticket);
}

/// <summary>A media stream on the server: its address, the pinned client to read it with, and the token.</summary>
public sealed record StreamSource(Uri Address, HttpClient Client, string Token);

/// <summary>The library as one opened profile sees it.</summary>
public sealed class LibraryClient(AureliaServerApi api, StoredConnection connection, ProfileSessionResponse session) : ILibraryApi, IDisposable
{
    /// <summary>Artwork sizes the server prepares; the closest larger one is requested.</summary>
    public static readonly int[] ArtworkWidths = [320, 640, 1280, 1920];
    private readonly HttpClient client = api.Pinned(connection.Address, connection.Fingerprint);
    // Streams run for hours, so their client has no overall timeout; connections still pin the key.
    private readonly HttpClient streams = AureliaServerApi.CreateClient(connection.Address, connection.Fingerprint, null,
        Timeout.InfiniteTimeSpan);
    private IReadOnlyList<string>? capabilities;

    public ProfileSessionResponse Session => session;
    public StoredConnection Connection => connection;

    public Task<HomeResponse> HomeAsync(CancellationToken cancellation) => GetAsync<HomeResponse>("/api/v1/home", cancellation);

    public Task<PagedResponse<CatalogItemSummary>> BrowseAsync(MediaKind kind, CatalogFilter filter, int offset, int limit,
        CancellationToken cancellation)
    {
        if (kind is not (MediaKind.Movie or MediaKind.Series) || offset < 0 || limit is < 1 or > 200)
            throw new ArgumentOutOfRangeException(nameof(kind));
        return GetAsync<PagedResponse<CatalogItemSummary>>(
            $"/api/v1/catalog/items?kind={Wire(kind)}&{filter.Query()}&offset={offset}&limit={limit}", cancellation);
    }

    public Task<PagedResponse<CatalogItemSummary>> SearchAsync(string term, int offset, int limit, CancellationToken cancellation)
    {
        var trimmed = term.Trim();
        if (trimmed.Length is 0 or > 200 || offset < 0 || limit is < 1 or > 200) throw new ArgumentOutOfRangeException(nameof(term));
        return GetAsync<PagedResponse<CatalogItemSummary>>(
            $"/api/v1/catalog/search?query={Uri.EscapeDataString(trimmed)}&offset={offset}&limit={limit}", cancellation);
    }

    public async Task<CatalogDetailPresentation> DetailAsync(Guid id, CancellationToken cancellation)
    {
        var detail = await GetAsync<CatalogDetailPresentation>($"/api/v1/catalog/items/{id}", cancellation);
        if (detail.Item.Id != id) throw AureliaApiException.InvalidResponse();
        return detail;
    }

    public async Task<PlaybackPlanResponse> PlaybackPlanAsync(Guid id, CancellationToken cancellation)
    {
        var plan = await GetAsync<PlaybackPlanResponse>($"/api/v1/media/{id}/playback-plan", cancellation);
        if (plan.Target is { } target && target.Kind is MediaKind.Series) throw AureliaApiException.InvalidResponse();
        return plan;
    }

    public Task<bool> SetFavoriteAsync(Guid id, bool favorite, CancellationToken cancellation) =>
        AureliaServerApi.SendAsync<bool>(client, HttpMethod.Put, $"/api/v1/media/{id}/favorite", session.Token,
            new SetFavoriteRequest(favorite), inspecting: false, cancellation);

    public async Task<WatchStateResponse> WatchStateAsync(Guid id, WatchStateScope scope, int? season, CancellationToken cancellation)
    {
        var seasonQuery = season is { } number ? "&seasonNumber=" + number.ToString(CultureInfo.InvariantCulture) : "";
        var state = await GetAsync<WatchStateResponse>($"/api/v1/media/{id}/watch-state?scope={Wire(scope)}{seasonQuery}", cancellation);
        if (state.MediaId != id || state.Scope != scope || state.SeasonNumber != season || state.StateToken.Length == 0)
            throw AureliaApiException.InvalidResponse();
        return state;
    }

    public async Task<WatchStateResponse> SetWatchedAsync(Guid id, bool watched, WatchStateScope scope, int? season, string stateToken,
        CancellationToken cancellation)
    {
        var state = await AureliaServerApi.SendAsync<WatchStateResponse>(client, HttpMethod.Put, $"/api/v1/media/{id}/watch-state",
            session.Token, new SetWatchStateRequest(watched, scope, season, stateToken, Guid.NewGuid()), inspecting: false, cancellation);
        if (state.MediaId != id || state.Scope != scope || state.SeasonNumber != season) throw AureliaApiException.InvalidResponse();
        return state;
    }

    public async Task<byte[]> ArtworkAsync(ArtworkSummary artwork, int width, CancellationToken cancellation)
    {
        if (!string.Equals(artwork.Path, $"/api/v1/artwork/{artwork.Id}", StringComparison.OrdinalIgnoreCase))
            throw AureliaApiException.InvalidResponse();
        var features = await CapabilitiesAsync(cancellation);
        var sized = artwork.Revision is not null && features.Contains("artwork-variants-v1");
        var path = sized ? $"{artwork.Path}?width={ArtworkWidth(width)}" : artwork.Path;
        var bytes = await AureliaServerApi.SendAsync<byte[]>(client, HttpMethod.Get, path, session.Token, null, inspecting: false, cancellation);
        if (bytes.Length is 0 or > 24 * 1024 * 1024) throw AureliaApiException.InvalidResponse();
        return bytes;
    }

    public async Task<PlaybackSourceResponse> CreatePlaybackAsync(Guid mediaId, CancellationToken cancellation)
    {
        var ticket = await AureliaServerApi.SendAsync<PlaybackSourceResponse>(client, HttpMethod.Post, $"/api/v1/media/{mediaId}/playback",
            session.Token, null, inspecting: false, cancellation);
        if (ticket.MediaId != mediaId || ticket.ContentLength <= 0 || ticket.ExpiresAt <= DateTimeOffset.UtcNow
            || ticket.Progress.MediaId != mediaId || !IsStreamPath(ticket.StreamPath))
            throw AureliaApiException.InvalidResponse();
        return ticket;
    }

    public Task RevokePlaybackAsync(Guid ticketId, CancellationToken cancellation) =>
        AureliaServerApi.SendAsync<AureliaServerApi.NoContent>(client, HttpMethod.Delete, $"/api/v1/playback/{ticketId}", session.Token,
            null, inspecting: false, cancellation);

    public Task<PlaybackProgressResponse> ProgressAsync(Guid mediaId, CancellationToken cancellation) =>
        GetAsync<PlaybackProgressResponse>($"/api/v1/media/{mediaId}/progress", cancellation);

    public async Task<PlaybackProgressResponse> SaveProgressAsync(Guid mediaId, long position, long duration, bool finished,
        long expectedRevision, Guid mutationId, CancellationToken cancellation)
    {
        if (position < 0 || duration <= 0 || position > duration) throw new ArgumentOutOfRangeException(nameof(position));
        var saved = await AureliaServerApi.SendAsync<PlaybackProgressResponse>(client, HttpMethod.Put, $"/api/v1/media/{mediaId}/progress",
            session.Token, new UpdatePlaybackProgressRequest(position, duration, finished, mutationId, EnforceRevision: true,
                ExpectedRevision: expectedRevision), inspecting: false, cancellation);
        if (saved.MediaId != mediaId) throw AureliaApiException.InvalidResponse();
        return saved;
    }

    public async Task<IReadOnlyList<string>> CapabilitiesAsync(CancellationToken cancellation)
    {
        if (capabilities is { } known) return known;
        var response = await AureliaServerApi.SendAsync<ClientCapabilitiesResponse>(client, HttpMethod.Get, "/api/v1/capabilities", null,
            null, inspecting: false, cancellation);
        capabilities = response.Capabilities;
        return capabilities;
    }

    public StreamSource StreamSource(PlaybackSourceResponse ticket)
    {
        if (!IsStreamPath(ticket.StreamPath)) throw AureliaApiException.InvalidResponse();
        return new StreamSource(new Uri(connection.Address, ticket.StreamPath), streams, session.Token);
    }

    public void Dispose() => streams.Dispose();

    /// <summary>The smallest prepared width that still fills `width` pixels.</summary>
    public static int ArtworkWidth(int width) => ArtworkWidths.FirstOrDefault(candidate => candidate >= width, ArtworkWidths[^1]);

    internal static bool IsStreamPath(string path)
    {
        const string prefix = "/api/v1/streams/";
        if (!path.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var token = path[prefix.Length..];
        return token.Length is >= 32 and <= 256 && token.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_');
    }

    private Task<T> GetAsync<T>(string path, CancellationToken cancellation) =>
        AureliaServerApi.SendAsync<T>(client, HttpMethod.Get, path, session.Token, null, inspecting: false, cancellation);

    private static string Wire(MediaKind kind) => JsonNamingPolicyCamel(kind.ToString());
    private static string Wire(WatchStateScope scope) => JsonNamingPolicyCamel(scope.ToString());

    private static string JsonNamingPolicyCamel(string value) =>
        value.Length == 0 ? value : char.ToLower(value[0], CultureInfo.InvariantCulture) + value[1..];
}
