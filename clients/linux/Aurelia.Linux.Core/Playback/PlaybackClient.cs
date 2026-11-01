using System.Globalization;
using System.Net.Http.Headers;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Library;

namespace Aurelia.Linux.Core.Playback;

/// <summary>The playback endpoints for the open profile: tickets, progress, subtitles, scene notes, timeline previews and Play On.</summary>
public sealed class PlaybackClient(AureliaApi api, LibraryClient library)
{
    public LibraryClient Library { get; } = library;

    private HttpClient Pinned => api.Pinned(Library.Server.Address, Library.Server.Fingerprint);

    private string Token => Library.Profile.Token;

    /// <summary>POST /api/v1/media/{id}/playback: a short-lived ticket for one stream.</summary>
    public async Task<PlaybackSourceResponse> StartAsync(Guid mediaId, CancellationToken cancellation)
    {
        var ticket = await Send<PlaybackSourceResponse>(HttpMethod.Post, $"/api/v1/media/{mediaId}/playback", null, cancellation);
        if (ticket.MediaId != mediaId || ticket.Progress.MediaId != mediaId) throw AureliaApiException.InvalidResponse();
        if (!ticket.StreamPath.StartsWith("/api/v1/streams/", StringComparison.Ordinal) || ticket.StreamPath.Contains('?') || ticket.StreamPath.Contains('#'))
            throw AureliaApiException.InvalidResponse();
        return ticket;
    }

    /// <summary>The stream's full address on the server, which only the relay uses.</summary>
    public Uri StreamUri(PlaybackSourceResponse ticket) => new(Library.Server.Address, ticket.StreamPath);

    public HttpClient StreamConnection => Pinned;

    public string StreamToken => Token;

    public Task RevokeAsync(Guid ticketId, CancellationToken cancellation) =>
        Send<AureliaApi.NoContent>(HttpMethod.Delete, $"/api/v1/playback/{ticketId}", null, cancellation);

    public Task<PlaybackProgressResponse> ProgressAsync(Guid mediaId, CancellationToken cancellation) =>
        Send<PlaybackProgressResponse>(HttpMethod.Get, $"/api/v1/media/{mediaId}/progress", null, cancellation);

    public Task<PlaybackProgressResponse> SaveProgressAsync(Guid mediaId, UpdatePlaybackProgressRequest request, CancellationToken cancellation) =>
        Send<PlaybackProgressResponse>(HttpMethod.Put, $"/api/v1/media/{mediaId}/progress", request, cancellation);

    public Task<IReadOnlyList<LiveSubtitleTrack>> SubtitlesAsync(PlaybackSourceResponse ticket, CancellationToken cancellation) =>
        Send<IReadOnlyList<LiveSubtitleTrack>>(HttpMethod.Get, ticket.StreamPath.TrimEnd('/') + "/subtitles", null, cancellation);

    public Task SleepTimerEndedAsync(CancellationToken cancellation) =>
        Send<AureliaApi.NoContent>(HttpMethod.Post, "/api/v1/playback/sleep-timer-ended", null, cancellation);

    public Task<IReadOnlyList<SceneNoteSummary>> NotesAsync(Guid mediaId, CancellationToken cancellation) =>
        Send<IReadOnlyList<SceneNoteSummary>>(HttpMethod.Get, $"/api/v1/media/{mediaId}/notes", null, cancellation);

    public Task<SceneNoteSummary> SaveNoteAsync(Guid mediaId, Guid noteId, SaveSceneNoteRequest request, CancellationToken cancellation) =>
        Send<SceneNoteSummary>(HttpMethod.Put, $"/api/v1/media/{mediaId}/notes/{noteId}", request, cancellation);

    public Task DeleteNoteAsync(Guid mediaId, Guid noteId, long revision, CancellationToken cancellation) =>
        Send<AureliaApi.NoContent>(HttpMethod.Delete, $"/api/v1/media/{mediaId}/notes/{noteId}?revision={revision.ToString(CultureInfo.InvariantCulture)}", null, cancellation);

    /// <summary>A timeline preview picture the server prepared, or null when it has none for that moment.</summary>
    public async Task<byte[]?> ScrubPreviewAsync(Guid mediaId, int seconds, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/v1/media/{mediaId}/scrub-previews/{seconds.ToString(CultureInfo.InvariantCulture)}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("image/jpeg"));
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(8));
        try
        {
            using var response = await Pinned.SendAsync(request, timeout.Token);
            return response.IsSuccessStatusCode ? await response.Content.ReadAsByteArrayAsync(timeout.Token) : null;
        }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException)
        {
            return null;
        }
    }

    public Task<PlayerHeartbeatResponse> HeartbeatAsync(PlayerHeartbeatRequest request, CancellationToken cancellation) =>
        Send<PlayerHeartbeatResponse>(HttpMethod.Post, "/api/v1/devices/player/heartbeat", request, cancellation);

    public Task<IReadOnlyList<RemotePlayerDevice>> PlayersAsync(string currentDeviceId, CancellationToken cancellation) =>
        Send<IReadOnlyList<RemotePlayerDevice>>(HttpMethod.Get, "/api/v1/devices/players?currentDeviceId=" + Uri.EscapeDataString(currentDeviceId), null, cancellation);

    public Task<RemotePlayerDevice> PlayerStatusAsync(string deviceId, CancellationToken cancellation) =>
        Send<RemotePlayerDevice>(HttpMethod.Get, $"/api/v1/devices/players/{Uri.EscapeDataString(deviceId)}/status", null, cancellation);

    public Task<RemotePlaybackCommandResponse> SendCommandAsync(string deviceId, RemotePlaybackCommandRequest request, CancellationToken cancellation) =>
        Send<RemotePlaybackCommandResponse>(HttpMethod.Post, $"/api/v1/devices/players/{Uri.EscapeDataString(deviceId)}/commands", request, cancellation);

    /// <summary>Waits up to ten seconds for commands sent to this computer from another device.</summary>
    public async Task<IReadOnlyList<RemotePlaybackCommand>> CommandsAsync(string deviceId, CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        return await Send<IReadOnlyList<RemotePlaybackCommand>>(HttpMethod.Get,
            $"/api/v1/devices/player/commands?deviceId={Uri.EscapeDataString(deviceId)}&waitMs=10000", null, timeout.Token);
    }

    private Task<T> Send<T>(HttpMethod method, string path, object? body, CancellationToken cancellation) =>
        AureliaApi.SendAsync<T>(Pinned, method, path, Token, body, false, cancellation);
}
