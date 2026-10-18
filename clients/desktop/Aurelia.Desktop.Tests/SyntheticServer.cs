using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Tests;

/// <summary>
/// The real Aurelia server, started from its build output with a fresh temporary data folder,
/// synthetic accounts and no media. It listens on loopback only, never announces itself on the
/// network, and stops with the test process. Acts as the owner's Mac where a test needs that.
/// </summary>
internal sealed class SyntheticServer : IAsyncDisposable
{
    public const string OwnerName = "Synthetic Owner";
    public const string OwnerPin = "5682";
    public const string GuestName = "Synthetic Guest";
    private const string Password = "synthetic desktop owner password";
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
    };
    private readonly Process process;
    private readonly string root;
    private readonly HttpClient local;
    private string? ownerToken;

    private SyntheticServer(Process process, string root, HttpClient local, int httpsPort)
    {
        this.process = process;
        this.root = root;
        this.local = local;
        HttpsPort = httpsPort;
    }

    public int HttpsPort { get; }
    public string Fingerprint { get; private init; } = "";

    /// <summary>The server build that scripts/test-desktop.sh prepares; tests skip without it.</summary>
    public static string? Executable =>
        Environment.GetEnvironmentVariable("AURELIA_TEST_SERVER") is { Length: > 0 } path && File.Exists(path) ? path : null;

    public static async Task<SyntheticServer> StartAsync()
    {
        var executable = Executable ?? throw new InvalidOperationException("AURELIA_TEST_SERVER is not set.");
        var root = Path.Combine(Path.GetTempPath(), "aurelia-desktop-server-" + Guid.NewGuid().ToString("N"));
        CreatePrivateDirectory(root);
        var httpPort = FreePort();
        var httpsPort = FreePort();
        while (httpsPort == httpPort) httpsPort = FreePort();
        // A TLS identity created here makes the server offer HTTPS on 127.0.0.1 only, without
        // network access; the test knows the key's fingerprint independently of the server.
        var fingerprint = CreateTlsIdentity(root);
        // Loopback only, no Bonjour, no folder monitoring and no backups: nothing leaves this computer.
        WritePrivateFile(Path.Combine(root, "server-settings.json"), JsonSerializer.Serialize(new
        {
            version = 2,
            serverName = "Synthetic Desktop Test",
            lanAccessEnabled = false,
            lanHttpsPort = httpsPort,
            bonjourEnabled = false,
            monitoringEnabled = false,
            automaticBackupsEnabled = false,
        }));
        var bootstrap = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = root,
        };
        foreach (var argument in new[] { "run", "--data-dir", root, "--urls", $"http://127.0.0.1:{httpPort}", "--lan-port", httpsPort.ToString(CultureInfo.InvariantCulture) })
            start.ArgumentList.Add(argument);
        start.Environment["AURELIA_LAN_ENABLED"] = "false";
        start.Environment["AURELIA_BOOTSTRAP_TOKEN"] = bootstrap;
        start.Environment["AURELIA_HOST_PARENT_PID"] = Environment.ProcessId.ToString(CultureInfo.InvariantCulture);
        start.Environment["AURELIA_HOST_LIFELINE"] = "1";
        start.Environment["DOTNET_ROOT"] = Environment.GetEnvironmentVariable("DOTNET_ROOT")
            ?? Path.GetFullPath(Path.Combine(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", ".."));
        start.Environment["Logging__LogLevel__Default"] = "Warning";
        var process = Process.Start(start) ?? throw new InvalidOperationException("The synthetic server did not start.");
        process.OutputDataReceived += (_, _) => { };
        process.ErrorDataReceived += (_, _) => { };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        var local = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{httpPort}"), Timeout = TimeSpan.FromSeconds(10) };
        var server = new SyntheticServer(process, root, local, httpsPort) { Fingerprint = fingerprint };
        try
        {
            await server.WaitUntilReadyAsync();
            await server.SetUpOwnerAsync(bootstrap);
            return server;
        }
        catch
        {
            await server.DisposeAsync();
            throw;
        }
    }

    /// <summary>What the owner does on the Mac: look up the code shown by the new device and approve it.</summary>
    public async Task ApproveAsync(string code)
    {
        var preview = await SendAsync<DeviceAuthorizationPreview>(HttpMethod.Post, "/api/v1/server/device-pairings/lookup",
            new DeviceAuthorizationLookupRequest(code.Replace(" ", "", StringComparison.Ordinal)));
        await SendAsync<DeviceAuthorizationPreview>(HttpMethod.Post, $"/api/v1/server/device-pairings/{preview.Id}/approve", null, approve: true);
    }

    public async ValueTask DisposeAsync()
    {
        local.Dispose();
        try
        {
            if (!process.HasExited)
            {
                process.StandardInput.Close();
                if (!process.WaitForExit(5_000)) process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException) { }
        process.Dispose();
        await Task.Yield();
        try { Directory.Delete(root, recursive: true); }
        catch (IOException) { }
    }

    private async Task WaitUntilReadyAsync()
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(45);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (process.HasExited) throw new InvalidOperationException("The synthetic server exited during startup.");
            try
            {
                if (await local.GetFromJsonAsync<ServerInfoResponse>("/api/v1/server/info", Json) is not null) return;
            }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) { }
            await Task.Delay(100);
        }
        throw new TimeoutException("The synthetic server did not become ready.");
    }

    private async Task SetUpOwnerAsync(string bootstrap)
    {
        using var setup = new HttpRequestMessage(HttpMethod.Post, "/api/v1/setup/owner")
        {
            Content = JsonContent.Create(new SetupOwnerRequest(OwnerName, Password, "Synthetic Mac"), options: Json),
        };
        setup.Headers.Add("X-Aurelia-Bootstrap-Token", bootstrap);
        var device = await ReadAsync<AuthenticationResponse>(await local.SendAsync(setup));
        await SendAsync<object>(HttpMethod.Post, "/api/v1/profiles/initialize", new InitializeProfilesRequest(Password, OwnerPin), token: device.Token);
        var session = await SendAsync<ProfileSessionResponse>(HttpMethod.Post, $"/api/v1/profiles/{device.User.Id}/unlock",
            new UnlockProfileRequest(OwnerPin), token: device.Token);
        ownerToken = session.Token;
        await SendAsync<object>(HttpMethod.Post, "/api/v1/management/unlock", new UnlockManagementRequest(Password));
        // A second profile without a PIN, as households often have.
        await SendAsync<object>(HttpMethod.Post, "/api/v1/users",
            new CreateUserRequest(GuestName, null, UserRole.User, PinProtectionEnabled: false, AccessMode: ProfileAccessMode.EntireLibrary),
            approve: true);
    }

    private async Task<T> SendAsync<T>(HttpMethod method, string path, object? body, bool approve = false, string? token = null)
    {
        using var request = new HttpRequestMessage(method, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token ?? ownerToken);
        byte[] payload = body is null ? [] : JsonSerializer.SerializeToUtf8Bytes(body, body.GetType(), Json);
        if (body is not null)
        {
            request.Content = new ByteArrayContent(payload);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        }
        if (approve)
        {
            // Administrative changes need a one-time approval for exactly this request.
            var approval = await SendAsync<AdministrationApprovalResponse>(HttpMethod.Post, "/api/v1/server/approval",
                new AdministrationApprovalRequest($"{method.Method} {path}", Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant(), Password));
            request.Headers.Add("X-Aurelia-Approval", approval.Token);
        }
        return await ReadAsync<T>(await local.SendAsync(request));
    }

    private static async Task<T> ReadAsync<T>(HttpResponseMessage response)
    {
        using (response)
        {
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException($"Synthetic server setup failed: {(int)response.StatusCode} {await response.Content.ReadAsStringAsync()}");
            if (typeof(T) == typeof(object) || response.Content.Headers.ContentLength == 0) return default!;
            return (await response.Content.ReadFromJsonAsync<T>(Json))!;
        }
    }

    /// <summary>The same kind of identity the server creates for itself: a P-256 key and a self-signed certificate.</summary>
    private static string CreateTlsIdentity(string root)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=Aurelia Server", key, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid("1.3.6.1.5.5.7.3.1")], false));
        var names = new SubjectAlternativeNameBuilder();
        names.AddDnsName("localhost");
        names.AddIpAddress(IPAddress.Loopback);
        request.CertificateExtensions.Add(names.Build());
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(1));
        WritePrivateFile(Path.Combine(root, "server-private-key.pem"), key.ExportPkcs8PrivateKeyPem());
        WritePrivateFile(Path.Combine(root, "server-certificate.pem"), certificate.ExportCertificatePem());
        return Convert.ToHexString(SHA256.HashData(key.ExportSubjectPublicKeyInfo()));
    }

    private static int FreePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private static void CreatePrivateDirectory(string path)
    {
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(path);
        else Directory.CreateDirectory(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    private static void WritePrivateFile(string path, string text)
    {
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        using var writer = new StreamWriter(new FileStream(path, options));
        writer.Write(text);
    }
}
