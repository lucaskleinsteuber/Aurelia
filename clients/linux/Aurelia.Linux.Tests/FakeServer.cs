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

    public List<string> Requests { get; } = [];

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
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var key = request.Method.Method + " " + request.RequestUri!.AbsolutePath;
            server.Requests.Add(key);
            if (!server.answers.TryGetValue(key, out var queue) || queue.Count == 0)
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound));
            var (status, body) = queue.Count > 1 ? queue.Dequeue() : queue.Peek();
            return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
        }
    }
}
