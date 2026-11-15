using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Moving;

namespace Aurelia.Linux.Core.Hosting;

/// <summary>
/// "Move from another Aurelia server" on this computer's new server while it has no owner
/// (docs/SERVER_MOVE.md, "On the new server while it has no owner").
/// </summary>
public interface ISetupMoveChannel
{
    Task<SetupMoveStatus> StatusAsync(CancellationToken cancellation);

    /// <summary>Starts fetching from the old server at <paramref name="address"/> with its move code.</summary>
    Task StartNetworkAsync(Uri address, string code, CancellationToken cancellation);

    /// <summary>Uploads the moving file and opens it with its passphrase.</summary>
    Task OpenFileAsync(Stream file, string passphrase, CancellationToken cancellation);

    Task<MoveMatch> PreviewAsync(Guid locationId, string path, CancellationToken cancellation);

    /// <summary>Applies the moved data with the chosen folders; the server then restarts with the moved identity.</summary>
    Task FinishAsync(FinishMoveRequest request, CancellationToken cancellation);

    /// <summary>Discards the staged data.</summary>
    Task DiscardAsync(CancellationToken cancellation);
}

/// <summary>
/// The setup move calls to the server this app started, over plain HTTP on 127.0.0.1 with the
/// one-time bootstrap token the app already uses to create the owner (X-Aurelia-Bootstrap-Token).
/// The token is sent only while that server waits for its setup, so another program on the port
/// never receives it. A moving file or a long fetch may take minutes, so each call has its own limit.
/// </summary>
internal sealed class LocalSetupMoveChannel(Uri baseAddress, Func<string?> setupToken) : ISetupMoveChannel, IDisposable
{
    internal const string TokenHeader = "X-Aurelia-Bootstrap-Token";
    private static readonly TimeSpan ShortLimit = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan UploadLimit = TimeSpan.FromHours(1);
    private static readonly TimeSpan FinishLimit = TimeSpan.FromMinutes(10);
    private readonly HttpClient client = new(new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false })
    {
        BaseAddress = baseAddress,
        Timeout = Timeout.InfiniteTimeSpan,
    };

    public Task<SetupMoveStatus> StatusAsync(CancellationToken cancellation) =>
        SendAsync<SetupMoveStatus>(HttpMethod.Get, "/api/v1/setup/move", null, ShortLimit, cancellation);

    public Task StartNetworkAsync(Uri address, string code, CancellationToken cancellation) =>
        SendAsync<AureliaApi.NoContent>(HttpMethod.Post, "/api/v1/setup/move/network",
            JsonContent.Create(new { address = address.GetLeftPart(UriPartial.Authority), code }, options: AureliaJson.Options), FinishLimit, cancellation);

    public async Task OpenFileAsync(Stream file, string passphrase, CancellationToken cancellation)
    {
        var body = new StreamContent(file);
        body.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        var upload = await SendAsync<UploadedMovingFile>(HttpMethod.Put, "/api/v1/setup/move/file", body, UploadLimit, cancellation);
        if (string.IsNullOrWhiteSpace(upload.UploadId)) throw AureliaApiException.InvalidResponse();
        await SendAsync<AureliaApi.NoContent>(HttpMethod.Post, $"/api/v1/setup/move/file/{Uri.EscapeDataString(upload.UploadId)}/open",
            JsonContent.Create(new { passphrase }, options: AureliaJson.Options), FinishLimit, cancellation);
    }

    public Task<MoveMatch> PreviewAsync(Guid locationId, string path, CancellationToken cancellation) =>
        SendAsync<MoveMatch>(HttpMethod.Post, "/api/v1/setup/move/locations/preview",
            JsonContent.Create(new { id = locationId, path }, options: AureliaJson.Options), FinishLimit, cancellation);

    public Task FinishAsync(FinishMoveRequest request, CancellationToken cancellation) =>
        SendAsync<AureliaApi.NoContent>(HttpMethod.Post, "/api/v1/setup/move/finish", JsonContent.Create(request, options: AureliaJson.Options), FinishLimit, cancellation);

    public Task DiscardAsync(CancellationToken cancellation) =>
        SendAsync<AureliaApi.NoContent>(HttpMethod.Delete, "/api/v1/setup/move", null, ShortLimit, cancellation);

    public void Dispose() => client.Dispose();

    private async Task<T> SendAsync<T>(HttpMethod method, string path, HttpContent? body, TimeSpan limit, CancellationToken cancellation)
    {
        using var content = body;
        var token = setupToken() ?? throw new AureliaApiException(409, "setup_unavailable",
            "This server is already set up or not ready. Try again in a moment.");
        using var request = new HttpRequestMessage(method, path) { Content = content };
        request.Headers.Add(TokenHeader, token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(limit);
        HttpResponseMessage response;
        try
        {
            response = await client.SendAsync(request, timeout.Token);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException && !cancellation.IsCancellationRequested)
        {
            throw new AureliaApiException(0, "server_unavailable", "Aurelia Server on this computer is not answering. Try again in a moment.");
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                ApiProblem? problem = null;
                try { problem = await response.Content.ReadFromJsonAsync<ApiProblem>(AureliaJson.Options, timeout.Token); }
                catch (Exception error) when (error is JsonException or NotSupportedException) { }
                throw new AureliaApiException((int)response.StatusCode, problem?.Code,
                    problem?.Message is { Length: > 0 and <= 300 } message ? message : "Aurelia Server could not complete this.");
            }
            if (typeof(T) == typeof(AureliaApi.NoContent)) return default!;
            try
            {
                return await response.Content.ReadFromJsonAsync<T>(AureliaJson.Options, timeout.Token) ?? throw AureliaApiException.InvalidResponse();
            }
            catch (JsonException)
            {
                throw AureliaApiException.InvalidResponse();
            }
        }
    }
}
