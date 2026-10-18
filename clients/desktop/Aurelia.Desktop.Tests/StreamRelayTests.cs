using System.Net;
using System.Net.Sockets;
using System.Text;
using Aurelia.Desktop.Core;
using Xunit;

namespace Aurelia.Desktop.Tests;

public sealed class StreamRelayTests
{
    private sealed class Upstream : HttpMessageHandler
    {
        public List<HttpRequestMessage> Requests { get; } = [];
        public HttpStatusCode Status { get; set; } = HttpStatusCode.PartialContent;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request);
            var body = "0123456789ABCDEF"u8.ToArray()[2..6];
            var response = new HttpResponseMessage(Status) { Content = new ByteArrayContent(body) };
            response.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("video/x-msvideo");
            response.Content.Headers.ContentRange = new System.Net.Http.Headers.ContentRangeHeaderValue(2, 5, 16);
            response.Headers.AcceptRanges.Add("bytes");
            return Task.FromResult(response);
        }
    }

    private static async Task<string> SendAsync(Uri relay, string requestLine, string host)
    {
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, relay.Port);
        var stream = client.GetStream();
        await stream.WriteAsync(Encoding.ASCII.GetBytes($"{requestLine}\r\nHost: {host}\r\nRange: bytes=2-5\r\n\r\n"));
        using var reader = new StreamReader(stream, Encoding.ASCII);
        return await reader.ReadToEndAsync();
    }

    [Fact]
    public async Task ForwardsByteRangesWithTheTokenAndNothingElse()
    {
        var upstream = new Upstream();
        await using var relay = new LoopbackStreamRelay(
            new StreamSource(new Uri("https://192.168.1.20:43111/api/v1/streams/" + new string('t', 40)), new HttpClient(upstream),
                "synthetic-profile-token"), purpose: "preview");
        var url = relay.Start();
        Assert.Equal("127.0.0.1", url.Host);

        var response = await SendAsync(url, $"GET {url.AbsolutePath} HTTP/1.1", $"127.0.0.1:{url.Port}");
        Assert.StartsWith("HTTP/1.1 206", response, StringComparison.Ordinal);
        Assert.Contains("Content-Range: bytes 2-5/16", response, StringComparison.Ordinal);
        Assert.Contains("Cache-Control: private, no-store", response, StringComparison.Ordinal);
        Assert.EndsWith("2345", response, StringComparison.Ordinal);
        var forwarded = Assert.Single(upstream.Requests);
        Assert.Equal("Bearer synthetic-profile-token", forwarded.Headers.Authorization?.ToString());
        Assert.Equal("bytes=2-5", forwarded.Headers.Range?.ToString());
        Assert.Equal("preview", forwarded.Headers.GetValues("X-Aurelia-Stream-Purpose").Single());

        // Only the decoder on this computer, with the secret path, gets through.
        Assert.StartsWith("HTTP/1.1 400", await SendAsync(url, "GET /stream/guess HTTP/1.1", $"127.0.0.1:{url.Port}"), StringComparison.Ordinal);
        Assert.StartsWith("HTTP/1.1 400", await SendAsync(url, $"GET {url.AbsolutePath} HTTP/1.1", "evil.example"), StringComparison.Ordinal);
        Assert.StartsWith("HTTP/1.1 400", await SendAsync(url, $"POST {url.AbsolutePath} HTTP/1.1", $"127.0.0.1:{url.Port}"), StringComparison.Ordinal);
        Assert.Single(upstream.Requests);
    }

    [Fact]
    public async Task AServerThatEndsTheStreamIsReportedOnce()
    {
        var upstream = new Upstream { Status = HttpStatusCode.Unauthorized };
        await using var relay = new LoopbackStreamRelay(
            new StreamSource(new Uri("https://192.168.1.20:43111/api/v1/streams/" + new string('t', 40)), new HttpClient(upstream), "token"));
        var failures = new List<int>();
        relay.Failed += failures.Add;
        var url = relay.Start();
        await SendAsync(url, $"GET {url.AbsolutePath} HTTP/1.1", "127.0.0.1");
        await SendAsync(url, $"GET {url.AbsolutePath} HTTP/1.1", "127.0.0.1");
        Assert.Equal([401], failures);
    }

    [Theory]
    [InlineData("bytes=0-99", true)]
    [InlineData("bytes=100-", true)]
    [InlineData("bytes=-500", true)]
    [InlineData("bytes=9-1", false)]
    [InlineData("bytes=-", false)]
    [InlineData("items=0-1", false)]
    [InlineData("bytes=0-1,5-9", false)]
    public void OnlySingleByteRangesAreForwarded(string range, bool valid) => Assert.Equal(valid, LoopbackStreamRelay.IsValidRange(range));
}
