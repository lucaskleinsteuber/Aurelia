using System.Net;
using System.Text;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Tests;

/// <summary>
/// A scripted Aurelia server for interface tests: each request gets the prepared answer for its
/// method and path. The full protocol is tested against the real server in the integration tests.
/// </summary>
internal sealed class FakeServer : IServerTransport
{
    public const string Fingerprint = "A1B2C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F60718293A4B5C6D7E8F90";
    public static readonly Guid ServerId = Guid.Parse("7a1d2c3b-0000-4000-8000-0000000000aa");

    private readonly Dictionary<string, Queue<(HttpStatusCode Status, string Body)>> answers = [];
    private readonly Dictionary<string, byte[]> images = [];

    public List<string> Requests { get; } = [];

    /// <summary>Every request with its query string, for checking filters.</summary>
    public List<string> RequestUris { get; } = [];

    /// <summary>Request bodies by "METHOD path", for checking what the app sent.</summary>
    public Dictionary<string, string> Bodies { get; } = [];

    public FakeServer Image(string path, byte[] bytes)
    {
        images[path] = bytes;
        return this;
    }

    public FakeServer Answer(string method, string path, string json, HttpStatusCode status = HttpStatusCode.OK)
    {
        var key = method + " " + path;
        if (!answers.TryGetValue(key, out var queue)) answers[key] = queue = new();
        queue.Enqueue((status, json));
        return this;
    }

    public static FakeServer WithServerInfo(string name = "Living Room Server") => new FakeServer().Answer("GET", "/api/v1/server/info", $$"""
        {"serverId":"{{ServerId}}","name":"{{name}}","version":"1.26.3","isSetup":true,"lanAccessEnabled":true,"lanHttpsPort":43111,
         "publicKeyFingerprint":"{{Fingerprint}}","displayFingerprint":"A1B2-C3D4-E5F6-0718-293A-4B5C","capabilities":["library-state-v1"],
         "wakeOnLanAddresses":["aa:bb:cc:dd:ee:01"]}
        """);

    public HttpClient CreateClient(Uri address, string? expectedFingerprint, CapturedFingerprint? captured, TimeSpan timeout)
    {
        captured?.Set(Fingerprint);
        return new HttpClient(new Handler(this)) { BaseAddress = address, Timeout = timeout };
    }

    private sealed class Handler(FakeServer server) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var key = request.Method.Method + " " + request.RequestUri!.AbsolutePath;
            server.Requests.Add(key);
            server.RequestUris.Add(request.Method.Method + " " + request.RequestUri.PathAndQuery);
            if (request.Content is not null) server.Bodies[key] = await request.Content.ReadAsStringAsync(cancellationToken);
            if (server.images.TryGetValue(request.RequestUri.AbsolutePath, out var image))
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(image) };
            if (!server.answers.TryGetValue(key, out var queue) || queue.Count == 0)
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            var (status, body) = queue.Count > 1 ? queue.Dequeue() : queue.Peek();
            return new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
    }
}
