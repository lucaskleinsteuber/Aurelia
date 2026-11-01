using System.Net.Http.Headers;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Logging;

namespace Aurelia.Linux.IntegrationTests;

/// <summary>
/// The real Aurelia server in this process, with a temporary data folder and synthetic accounts
/// only. The Linux app's API client talks to it through <see cref="Transport"/>.
/// </summary>
public sealed class RealServer : WebApplicationFactory<Program>
{
    public const string BootstrapToken = "linux-client-test-bootstrap-token-with-256-bits-01";
    public const string OwnerPassword = "correct horse battery staple";
    public const string OwnerPin = "4321";

    /// <summary>The server's address as the client sees it: on this computer, so no network access is needed.</summary>
    public static readonly Uri Address = new("https://127.0.0.1:43111");

    private readonly string dataDirectory = Path.Combine(Path.GetTempPath(), "aurelia-linux-integration-" + Guid.NewGuid().ToString("N"));

    public RealServer()
    {
        Directory.CreateDirectory(dataDirectory);
        Transport = new InProcessTransport(this);
    }

    public IServerTransport Transport { get; }

    /// <summary>Creates the owner account, sets up profiles and returns a fresh eight-digit pairing code.</summary>
    public async Task<string> CreatePairingCodeAsync()
    {
        var owner = await SetUpOwnerAsync();
        using var client = Client();
        await SendAsync(client, HttpMethod.Post, "/api/v1/profiles/initialize", owner.Token, new InitializeProfilesRequest(OwnerPassword, OwnerPin));
        var profile = await SendAsync<ProfileSessionResponse>(client, HttpMethod.Post, $"/api/v1/profiles/{owner.User.Id}/unlock", owner.Token,
            new UnlockProfileRequest(OwnerPin));
        var code = await SendAsync<PairingCodeResponse>(client, HttpMethod.Post, "/api/v1/auth/pairings", profile.Token, new CreatePairingCodeRequest());
        return code.Code;
    }

    /// <summary>POST /api/v1/setup/owner with the one-time setup token, as the host app does.</summary>
    public async Task<AuthenticationResponse> SetUpOwnerAsync()
    {
        using var client = Client();
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/setup/owner")
        {
            Content = JsonContent.Create(new SetupOwnerRequest("owner", OwnerPassword, "Server Host"), options: AureliaJson.Options),
        };
        request.Headers.Add("X-Aurelia-Bootstrap-Token", BootstrapToken);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<AuthenticationResponse>(AureliaJson.Options))!;
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("Aurelia:DataDirectory", dataDirectory);
        builder.UseSetting("Aurelia:ListenUrl", "http://127.0.0.1:0");
        builder.UseSetting("Aurelia:BootstrapToken", BootstrapToken);
        builder.ConfigureLogging(logging => logging.SetMinimumLevel(LogLevel.Warning));
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing && Directory.Exists(dataDirectory)) Directory.Delete(dataDirectory, recursive: true);
    }

    private HttpClient Client() => new(Server.CreateHandler()) { BaseAddress = Address };

    private static async Task SendAsync(HttpClient client, HttpMethod method, string path, string token, object body)
    {
        using var request = new HttpRequestMessage(method, path) { Content = JsonContent.Create(body, body.GetType(), options: AureliaJson.Options) };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
    }

    private static async Task<T> SendAsync<T>(HttpClient client, HttpMethod method, string path, string token, object body)
    {
        using var request = new HttpRequestMessage(method, path) { Content = JsonContent.Create(body, body.GetType(), options: AureliaJson.Options) };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<T>(AureliaJson.Options))!;
    }

    /// <summary>
    /// Hands the client's requests straight to the in-process server. There is no TLS here, so the
    /// first contact reports a fixed key fingerprint; key pinning itself is tested on its own.
    /// </summary>
    private sealed class InProcessTransport(RealServer server) : IServerTransport
    {
        public const string Fingerprint = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";

        public HttpClient CreateClient(Uri address, string? expectedFingerprint, CapturedFingerprint? captured, TimeSpan timeout)
        {
            captured?.Set(Fingerprint);
            return new HttpClient(server.Server.CreateHandler()) { BaseAddress = address, Timeout = timeout };
        }
    }
}
