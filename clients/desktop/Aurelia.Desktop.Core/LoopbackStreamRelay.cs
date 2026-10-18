using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace Aurelia.Desktop.Core;

/// <summary>
/// Lets the video decoder read a server stream it could not verify itself. The decoder talks plain
/// HTTP to a random port on 127.0.0.1 with a secret path; each request is forwarded with its byte
/// range over the pinned HTTPS connection and the profile's token. Nothing is cached or written.
/// </summary>
public sealed class LoopbackStreamRelay : IStreamRelay
{
    private static readonly string[] ForwardedHeaders =
        ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"];
    private readonly HttpClient upstream;
    private readonly string token;
    private readonly string? purpose;
    private readonly string secret = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
    private readonly CancellationTokenSource lifetime = new();
    private readonly Lock gate = new();
    private Uri source;
    private TcpListener? listener;
    private bool reportedFailure;

    /// <param name="purpose">"preview" marks timeline-frame reads, which the server counts apart from playback.</param>
    public LoopbackStreamRelay(StreamSource stream, string? purpose = null)
    {
        upstream = stream.Client;
        token = stream.Token;
        source = stream.Address;
        this.purpose = purpose;
    }

    /// <summary>Raised once when the server refuses or ends the stream, so playback can recover.</summary>
    public event Action<int>? Failed;

    public Uri? LocalUrl { get; private set; }

    public Uri Start()
    {
        var started = new TcpListener(IPAddress.Loopback, 0);
        started.Start(backlog: 16);
        listener = started;
        var port = ((IPEndPoint)started.LocalEndpoint).Port;
        LocalUrl = new Uri($"http://127.0.0.1:{port}/stream/{secret}");
        _ = AcceptLoopAsync(started);
        return LocalUrl;
    }

    /// <summary>A renewed ticket continues the same stream at a new server address.</summary>
    public void UpdateSource(Uri address)
    {
        lock (gate) source = address;
    }

    public async ValueTask DisposeAsync()
    {
        await lifetime.CancelAsync();
        listener?.Stop();
        lifetime.Dispose();
    }

    private async Task AcceptLoopAsync(TcpListener server)
    {
        while (!lifetime.IsCancellationRequested)
        {
            TcpClient connection;
            try
            {
                connection = await server.AcceptTcpClientAsync(lifetime.Token);
            }
            catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or SocketException)
            {
                return;
            }
            _ = ServeAsync(connection);
        }
    }

    private async Task ServeAsync(TcpClient connection)
    {
        using (connection)
        {
            connection.NoDelay = true;
            var network = connection.GetStream();
            try
            {
                var head = await ReadHeadAsync(network, lifetime.Token);
                if (head is null || !TryParse(head, out var method, out var range, out var ifRange))
                {
                    await WriteStatusAsync(network, 400, "Bad Request");
                    return;
                }
                Uri address;
                lock (gate) address = source;
                using var request = new HttpRequestMessage(method == "HEAD" ? HttpMethod.Head : HttpMethod.Get, address);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                request.Headers.AcceptEncoding.Add(new StringWithQualityHeaderValue("identity"));
                if (range is not null) request.Headers.TryAddWithoutValidation("Range", range);
                if (ifRange is not null) request.Headers.TryAddWithoutValidation("If-Range", ifRange);
                if (purpose is not null) request.Headers.TryAddWithoutValidation("X-Aurelia-Stream-Purpose", purpose);
                using var response = await upstream.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, lifetime.Token);
                var status = (int)response.StatusCode;
                if (status is 401 or 403 or 404 or 410 or >= 500) ReportFailure(status);
                await WriteHeadAsync(network, response);
                if (method == "GET")
                {
                    await using var body = await response.Content.ReadAsStreamAsync(lifetime.Token);
                    await body.CopyToAsync(network, 128 * 1024, lifetime.Token);
                }
            }
            catch (Exception error) when (error is IOException or SocketException or OperationCanceledException or HttpRequestException)
            {
                // The decoder closing a connection after a seek is normal; a broken upstream is reported.
                if (error is HttpRequestException && !lifetime.IsCancellationRequested) ReportFailure(0);
            }
        }
    }

    private void ReportFailure(int status)
    {
        lock (gate)
        {
            if (reportedFailure) return;
            reportedFailure = true;
        }
        Failed?.Invoke(status);
    }

    private bool TryParse(string head, out string method, out string? range, out string? ifRange)
    {
        method = "";
        range = null;
        ifRange = null;
        var lines = head.Split("\r\n");
        var parts = lines[0].Split(' ');
        if (parts.Length != 3 || parts[2] != "HTTP/1.1" || parts[0] is not ("GET" or "HEAD") || parts[1] != "/stream/" + secret) return false;
        method = parts[0];
        string? host = null;
        foreach (var line in lines.Skip(1))
        {
            if (line.Length == 0) continue;
            var colon = line.IndexOf(':', StringComparison.Ordinal);
            if (colon <= 0) return false;
            var name = line[..colon].Trim().ToLowerInvariant();
            var value = line[(colon + 1)..].Trim();
            switch (name)
            {
                case "host": host = value; break;
                case "range": range = value; break;
                case "if-range": ifRange = value; break;
                case "content-length" or "transfer-encoding" or "upgrade": return false;
            }
        }
        // Only the decoder on this computer may use the relay, and only for byte ranges.
        if (host is null || !(host == "127.0.0.1" || host.StartsWith("127.0.0.1:", StringComparison.Ordinal))) return false;
        return range is null || IsValidRange(range);
    }

    internal static bool IsValidRange(string value)
    {
        if (!value.StartsWith("bytes=", StringComparison.Ordinal)) return false;
        var parts = value[6..].Split('-');
        if (parts.Length != 2 || (parts[0].Length == 0 && parts[1].Length == 0)) return false;
        if (!parts.All(part => part.All(char.IsAsciiDigit))) return false;
        if (parts[0].Length == 0) return long.TryParse(parts[1], CultureInfo.InvariantCulture, out var suffix) && suffix > 0;
        if (!long.TryParse(parts[0], CultureInfo.InvariantCulture, out var start)) return false;
        return parts[1].Length == 0 || (long.TryParse(parts[1], CultureInfo.InvariantCulture, out var end) && start <= end);
    }

    private static async Task<string?> ReadHeadAsync(NetworkStream stream, CancellationToken cancellation)
    {
        var buffer = new byte[32 * 1024];
        var length = 0;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        while (length < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(length), timeout.Token);
            if (read == 0) return null;
            length += read;
            var text = Encoding.ASCII.GetString(buffer, 0, length);
            var end = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
            if (end >= 0) return text[..end];
        }
        return null;
    }

    private static Task WriteStatusAsync(NetworkStream stream, int status, string reason) =>
        stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")).AsTask();

    private static async Task WriteHeadAsync(NetworkStream stream, HttpResponseMessage response)
    {
        var builder = new StringBuilder();
        builder.Append(CultureInfo.InvariantCulture, $"HTTP/1.1 {(int)response.StatusCode} {response.ReasonPhrase ?? "OK"}\r\n");
        foreach (var name in ForwardedHeaders)
        {
            if (response.Headers.TryGetValues(name, out var values) || response.Content.Headers.TryGetValues(name, out values))
                builder.Append(CultureInfo.InvariantCulture, $"{name}: {string.Join(", ", values)}\r\n");
        }
        builder.Append("Cache-Control: private, no-store\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(Encoding.ASCII.GetBytes(builder.ToString()));
    }
}
