using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;

if (args.Length is < 2 or > 4) throw new ArgumentException("Arguments: server executable, report path, duration seconds (default 7200), clients (default 4).");
var executable = Path.GetFullPath(args[0]);
var reportPath = Path.GetFullPath(args[1]);
var seconds = args.Length >= 3 ? int.Parse(args[2], CultureInfo.InvariantCulture) : 7200;
var clients = args.Length >= 4 ? int.Parse(args[3], CultureInfo.InvariantCulture) : 4;
if (!File.Exists(executable) || seconds is < 1 or > 86400 || clients is < 1 or > 8)
    throw new ArgumentException("Select an existing server executable, 1 to 86400 seconds, and 1 to 8 clients.");
Directory.CreateDirectory(Path.GetDirectoryName(reportPath)!);
var root = Path.Combine(Path.GetDirectoryName(reportPath)!, ".transport-probe-" + Guid.NewGuid().ToString("N"));
PrivateFilePermissions.CreatePrivateDirectory(root);
var json = new JsonSerializerOptions(JsonSerializerDefaults.Web)
{
    Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) }
};
var metrics = new ProbeMetrics(seconds);
var started = DateTimeOffset.UtcNow;
var pass = false;
string? failureType = null;
var phase = "synthetic_setup";
object? payloadEvidence = null;
string? serverVersion = null;
double actualSoakSeconds = 0;
Stopwatch? soakWatch = null;
using var lifetime = new CancellationTokenSource(TimeSpan.FromSeconds(seconds + 180));
Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; lifetime.Cancel(); };
var httpPort = FreePort();
var httpsPort = FreePort();
while (httpsPort == httpPort) httpsPort = FreePort();
var stagedExecutable = Path.Combine(root, "HostPayload", Path.GetFileName(executable));
await using var host = new ProbeHost(stagedExecutable, root, httpPort, httpsPort, metrics);
try
{
    _ = StagePayload(executable, root);
    payloadEvidence = PayloadEvidence(Path.GetDirectoryName(stagedExecutable)!);
    var seed = await SeedAsync(root);
    using (var identity = ServerTlsIdentity.LoadOrCreate(seed.Runtime with { LanAccessEnabled = true }))
    {
        var pin = Convert.FromHexString(identity.PublicKeyFingerprint!);
        phase = "protocol_and_authentication";
        await host.StartAsync(lifetime.Token);
        using var plain = MakeClient(false, HttpVersion.Version11, null);
        using var secureOne = MakeClient(true, HttpVersion.Version11, pin);
        using var secureTwo = MakeClient(true, HttpVersion.Version20, pin);
        foreach (var client in new[] { plain, secureOne, secureTwo })
        {
            using var info = await SendAsync(client, HttpMethod.Get, "/api/v1/server/info", null, null, HttpStatusCode.OK, lifetime.Token);
            serverVersion = info.RootElement.GetProperty("version").GetString();
        }
        await RejectWrongPinAsync();
        await RejectRedirectAsync(secureOne);

        var owner = await LoginAsync(secureTwo, "probe-owner");
        var first = await LoginAsync(secureOne, "probe-first");
        var second = await LoginAsync(secureTwo, "probe-second");
        phase = "library_grants_and_ranges";
        await CheckCatalogAsync(secureTwo, first.Token, seed.FirstMovie, seed.SecondMovie);
        await CheckCatalogAsync(secureOne, second.Token, seed.SecondMovie, seed.FirstMovie);
        var source = await PlaybackAsync(secureTwo, first.Token, seed.FirstMovie);
        foreach (var client in new[] { plain, secureOne, secureTwo })
        {
            await CheckRangeAsync(client, first.Token, source.StreamPath, head: false, lifetime.Token);
            await CheckRangeAsync(client, first.Token, source.StreamPath, head: true, lifetime.Token);
        }
        phase = "pairing_and_revocation";
        using (var pair = await SendAsync(secureTwo, HttpMethod.Post, "/api/v1/auth/pairings", owner.Token, new CreatePairingCodeRequest(), HttpStatusCode.OK, lifetime.Token))
        {
            var code = pair.RootElement.GetProperty("code").GetString()!;
            using var redeem = await SendAsync(secureTwo, HttpMethod.Post, "/api/v1/auth/pair", null,
                new RedeemPairingCodeRequest(code, "Synthetic paired device"), HttpStatusCode.OK, lifetime.Token);
            var paired = redeem.Deserialize<AuthenticationResponse>(json)!;
            using var removed = await SendAsync(secureTwo, HttpMethod.Delete, "/api/v1/device", paired.Token, null, HttpStatusCode.NoContent, lifetime.Token);
            using var rejected = await SendAsync(secureTwo, HttpMethod.Get, "/api/v1/auth/me", paired.Token, null, HttpStatusCode.Unauthorized, lifetime.Token);
            metrics.Check("pairing_and_self_revocation");
        }
        phase = "restart_and_cancellation";
        var progressMutation = new UpdatePlaybackProgressRequest(37_000, 600_000, false, Guid.NewGuid(), true, 0);
        using var progress = await SendAsync(secureTwo, HttpMethod.Put, $"/api/v1/media/{seed.FirstMovie}/progress", first.Token,
            progressMutation, HttpStatusCode.OK, lifetime.Token);
        var committedProgress = progress.Deserialize<PlaybackProgressResponse>(json)!;
        using (var replay = await SendAsync(secureTwo, HttpMethod.Put, $"/api/v1/media/{seed.FirstMovie}/progress", first.Token,
                   progressMutation, HttpStatusCode.OK, lifetime.Token))
            if (replay.Deserialize<PlaybackProgressResponse>(json) != committedProgress)
                throw new InvalidDataException("Idempotent progress replay changed the committed snapshot.");
        using (var conflict = await SendAsync(secureTwo, HttpMethod.Put, $"/api/v1/media/{seed.FirstMovie}/progress", first.Token,
                   progressMutation with { ClientMutationId = Guid.NewGuid() }, HttpStatusCode.Conflict, lifetime.Token))
            if (conflict.RootElement.GetProperty("code").GetString() != "playback_progress_conflict")
                throw new InvalidDataException("A stale progress revision was not rejected.");
        metrics.Check("guarded_progress_replay_and_conflict");
        var initialId = await ServerIdAsync(secureTwo);
        await CancelPollAsync(secureTwo, first.Token, lifetime.Token);
        await AbortStreamAsync(secureTwo, first.Token, source.StreamPath, lifetime.Token);
        await host.StopAsync();
        await host.StartAsync(lifetime.Token);
        using var expiredProfile = await SendAsync(secureTwo, HttpMethod.Get, "/api/v1/auth/me", first.Token, null, HttpStatusCode.Unauthorized, lifetime.Token);
        first = await LoginAsync(secureOne, "probe-first");
        second = await LoginAsync(secureTwo, "probe-second");
        using var resumed = await SendAsync(secureTwo, HttpMethod.Get, "/api/v1/auth/me", first.Token, null, HttpStatusCode.OK, lifetime.Token);
        if (await ServerIdAsync(secureTwo) != initialId) throw new InvalidDataException("Synthetic server identity changed on restart.");
        using (var replay = await SendAsync(secureTwo, HttpMethod.Put, $"/api/v1/media/{seed.FirstMovie}/progress", first.Token,
                   progressMutation, HttpStatusCode.OK, lifetime.Token))
            if (replay.Deserialize<PlaybackProgressResponse>(json) != committedProgress)
                throw new InvalidDataException("The progress replay marker was lost on server restart.");
        metrics.Check("guarded_progress_replay_after_restart");
        using (var saved = await SendAsync(secureTwo, HttpMethod.Get, $"/api/v1/media/{seed.FirstMovie}/progress", first.Token, null, HttpStatusCode.OK, lifetime.Token))
            if (saved.RootElement.GetProperty("positionMilliseconds").GetInt64() != 37_000) throw new InvalidDataException("Progress changed on restart.");
        metrics.Check("restart_preserves_identity_session_progress");
        Console.WriteLine($"Transport checks passed; starting {seconds.ToString(CultureInfo.InvariantCulture)} second synthetic soak with {clients.ToString(CultureInfo.InvariantCulture)} clients.");
        var soakEnd = DateTimeOffset.UtcNow.AddSeconds(seconds);
        soakWatch = Stopwatch.StartNew();
        phase = "soak";
        await Task.WhenAll(Enumerable.Range(0, clients).Select(async index =>
        {
            try
            {
                using var client = MakeClient(true, index % 2 == 0 ? HttpVersion.Version20 : HttpVersion.Version11, pin);
                var token = index % 2 == 0 ? first.Token : second.Token;
                var media = index % 2 == 0 ? seed.FirstMovie : seed.SecondMovie;
                var playback = await PlaybackAsync(client, token, media);
                var renewAt = DateTimeOffset.UtcNow;
                var iteration = 0;
                while (DateTimeOffset.UtcNow < soakEnd)
                {
                    lifetime.Token.ThrowIfCancellationRequested();
                    if (DateTimeOffset.UtcNow >= renewAt || playback.ExpiresAt <= DateTimeOffset.UtcNow.AddMinutes(1))
                    {
                        playback = await PlaybackAsync(client, token, media);
                        renewAt = DateTimeOffset.UtcNow.AddMinutes(15);
                        metrics.Check("renewed_playback_ticket");
                    }
                    using var catalog = await SendAsync(client, HttpMethod.Get, "/api/v1/home", token, null, HttpStatusCode.OK, lifetime.Token);
                    await CheckRangeAsync(client, token, playback.StreamPath, head: iteration % 3 == 0, lifetime.Token);
                    if (iteration % 5 == 0)
                    {
                        using var update = await SendAsync(client, HttpMethod.Put, $"/api/v1/media/{media}/progress", token,
                            new UpdatePlaybackProgressRequest((40 + iteration % 100) * 1000, 600_000, false), HttpStatusCode.OK, lifetime.Token);
                        await CancelPollAsync(client, token, lifetime.Token);
                        await AbortStreamAsync(client, token, playback.StreamPath, lifetime.Token);
                    }
                    iteration++;
                    host.Sample();
                    // Keep normal work below the deliberate pre-auth IP rate limit.
                    await Task.Delay(TimeSpan.FromSeconds(10), lifetime.Token);
                }
            }
            catch (Exception error)
            {
                metrics.Failure("soak_client_" + error.GetType().Name);
                lifetime.Cancel();
                throw;
            }
        }));
        actualSoakSeconds = soakWatch.Elapsed.TotalSeconds;
        pass = true;
    }
}
catch (Exception error)
{
    failureType = error.GetType().Name; // Never serialize request URI/tickets, headers, passwords or exception bodies.
    metrics.Failure(failureType);
    Console.Error.WriteLine("Synthetic transport probe failed: " + failureType);
}
finally
{
    if (actualSoakSeconds == 0 && soakWatch is not null) actualSoakSeconds = soakWatch.Elapsed.TotalSeconds;
    try { await host.StopAsync(); }
    catch (Exception error)
    {
        pass = false;
        failureType ??= error.GetType().Name;
        metrics.Failure("owned_host_shutdown");
    }
    var report = new
    {
        formatVersion = 1,
        startedAt = started,
        finishedAt = DateTimeOffset.UtcNow,
        passed = pass,
        requestedSeconds = seconds,
        actualSoakSeconds,
        clients,
        failureType,
        phase,
        serverVersion,
        payloadEvidence,
        methodology = "Owned synthetic database and byte-pattern media only. Real loopback Kestrel HTTP/1.1 plus SPKI-pinned HTTPS HTTP/1.1 and HTTP/2 exact-version requests; no TestServer and no personal media. CPU/RSS sample one local machine, not a capacity guarantee. Native TLS-close diagnostics are counted separately from functional request failures.",
        results = metrics.Snapshot()
    };
    await File.WriteAllTextAsync(reportPath, JsonSerializer.Serialize(report, new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
    Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
    Directory.Delete(root, true);
    Console.WriteLine("Synthetic transport report: " + reportPath);
}
Environment.ExitCode = pass ? 0 : 1;

HttpClient MakeClient(bool tls, Version version, byte[]? pin)
{
    var handler = new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.FromSeconds(15),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(10),
        ConnectTimeout = TimeSpan.FromSeconds(5),
        MaxConnectionsPerServer = 4,
        AllowAutoRedirect = false
    };
    if (tls)
    {
        handler.SslOptions.RemoteCertificateValidationCallback = (_, certificate, _, errors) =>
        {
            if (certificate is not X509Certificate2 observed || pin is null
                || (errors & SslPolicyErrors.RemoteCertificateNameMismatch) != 0
                || observed.NotBefore.ToUniversalTime() > DateTime.UtcNow || observed.NotAfter.ToUniversalTime() < DateTime.UtcNow)
                return false;
            using var key = observed.GetECDsaPublicKey();
            return key is not null && CryptographicOperations.FixedTimeEquals(pin, SHA256.HashData(key.ExportSubjectPublicKeyInfo()));
        };
    }
    return new HttpClient(handler)
    {
        BaseAddress = new Uri((tls ? "https" : "http") + "://127.0.0.1:" + (tls ? httpsPort : httpPort).ToString(CultureInfo.InvariantCulture)),
        DefaultRequestVersion = version,
        DefaultVersionPolicy = HttpVersionPolicy.RequestVersionExact,
        Timeout = TimeSpan.FromSeconds(40)
    };
}

async Task<JsonDocument> SendAsync(HttpClient client, HttpMethod method, string path, string? token, object? body,
    HttpStatusCode status, CancellationToken cancellation)
{
    using var request = NewRequest(client, method, path, token);
    if (body is not null) request.Content = new StringContent(JsonSerializer.Serialize(body, json), System.Text.Encoding.UTF8, "application/json");
    if (method == HttpMethod.Post && path == "/api/v1/auth/pairings")
    {
        var payload = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(cancellation);
        using var approval = await SendAsync(client, HttpMethod.Post, "/api/v1/management/approval", token,
            new AdministrationApprovalRequest(method.Method + " " + path, AdministrationApprovalStore.Hash(payload), ProbeSeed.Password), HttpStatusCode.OK, cancellation);
        request.Headers.Add("X-Aurelia-Approval", approval.Deserialize<AdministrationApprovalResponse>(json)!.Token);
    }
    var watch = Stopwatch.StartNew();
    using var response = await client.SendAsync(request, cancellation);
    metrics.Response(response.StatusCode, watch.Elapsed.TotalMilliseconds, response.Version);
    if (response.StatusCode != status || response.Version != client.DefaultRequestVersion)
        throw new InvalidDataException("Unexpected synthetic HTTP response status or negotiated protocol.");
    var bytes = await response.Content.ReadAsByteArrayAsync(cancellation);
    return bytes.Length == 0 ? JsonDocument.Parse("{}") : JsonDocument.Parse(bytes);
}

static HttpRequestMessage NewRequest(HttpClient client, HttpMethod method, string path, string? token)
{
    var request = new HttpRequestMessage(method, path) { Version = client.DefaultRequestVersion, VersionPolicy = HttpVersionPolicy.RequestVersionExact };
    if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
    return request;
}

async Task<AuthenticationResponse> LoginAsync(HttpClient client, string username)
{
    using var response = await SendAsync(client, HttpMethod.Post, "/api/v1/auth/login", null,
        new LoginRequest("probe-owner", ProbeSeed.Password, "Synthetic transport client"), HttpStatusCode.OK, lifetime.Token);
    var device = response.Deserialize<AuthenticationResponse>(json)!;
    using var picker = await SendAsync(client, HttpMethod.Get, "/api/v1/profiles", device.Token, null, HttpStatusCode.OK, lifetime.Token);
    var selected = picker.Deserialize<ProfilePickerResponse>(json)!.Profiles.Single(profile => profile.Name == username);
    using var unlock = await SendAsync(client, HttpMethod.Post, $"/api/v1/profiles/{selected.Id}/unlock", device.Token,
        new UnlockProfileRequest("5682"), HttpStatusCode.OK, lifetime.Token);
    var session = unlock.Deserialize<ProfileSessionResponse>(json)!;
    if (session.User.Role == UserRole.Owner)
    {
        using var management = await SendAsync(client, HttpMethod.Post, "/api/v1/management/unlock", session.Token,
            new UnlockManagementRequest(ProbeSeed.Password), HttpStatusCode.OK, lifetime.Token);
    }
    return new(session.User, device.SessionId, session.Token, session.ExpiresAt);
}

async Task RejectWrongPinAsync()
{
    using var wrong = MakeClient(true, HttpVersion.Version20, RandomNumberGenerator.GetBytes(32));
    try
    {
        using var response = await wrong.GetAsync("/api/v1/server/info", lifetime.Token);
        throw new InvalidDataException("A certificate with the wrong SPKI pin was accepted.");
    }
    catch (HttpRequestException error) when (error.HttpRequestError == HttpRequestError.SecureConnectionError)
    {
        metrics.Check("wrong_spki_rejected");
    }
}

async Task RejectRedirectAsync(HttpClient client)
{
    using var redirect = new TcpListener(IPAddress.Loopback, 0);
    using var sink = new TcpListener(IPAddress.Loopback, 0);
    redirect.Start(); sink.Start();
    var redirectPort = ((IPEndPoint)redirect.LocalEndpoint).Port;
    var sinkPort = ((IPEndPoint)sink.LocalEndpoint).Port;
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
    timeout.CancelAfter(TimeSpan.FromSeconds(5));
    var server = Task.Run(async () =>
    {
        using var connection = await redirect.AcceptTcpClientAsync(timeout.Token);
        await using var stream = connection.GetStream();
        var input = new byte[4096];
        if (await stream.ReadAsync(input, timeout.Token) == 0) throw new InvalidDataException("No synthetic redirect request.");
        var reply = System.Text.Encoding.ASCII.GetBytes("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:"
            + sinkPort.ToString(CultureInfo.InvariantCulture) + "/credential-sink\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(reply, timeout.Token);
    }, timeout.Token);
    using var request = NewRequest(client, HttpMethod.Get, "http://127.0.0.1:" + redirectPort.ToString(CultureInfo.InvariantCulture) + "/redirect", "synthetic-redirect-only");
    using var response = await client.SendAsync(request, timeout.Token);
    await server;
    if (response.StatusCode != HttpStatusCode.TemporaryRedirect || sink.Pending())
        throw new InvalidDataException("A redirect carrying credentials was followed.");
    metrics.Check("credential_redirect_rejected");
}

async Task<PlaybackSourceResponse> PlaybackAsync(HttpClient client, string token, Guid media)
{
    using var response = await SendAsync(client, HttpMethod.Post, $"/api/v1/media/{media}/playback", token, null, HttpStatusCode.OK, lifetime.Token);
    return response.Deserialize<PlaybackSourceResponse>(json)!;
}

async Task<Guid> ServerIdAsync(HttpClient client)
{
    using var response = await SendAsync(client, HttpMethod.Get, "/api/v1/server/info", null, null, HttpStatusCode.OK, lifetime.Token);
    return response.RootElement.GetProperty("serverId").GetGuid();
}

async Task CheckCatalogAsync(HttpClient client, string token, Guid visible, Guid hidden)
{
    using var response = await SendAsync(client, HttpMethod.Get, "/api/v1/catalog/items?limit=100", token, null, HttpStatusCode.OK, lifetime.Token);
    var ids = response.RootElement.GetProperty("items").EnumerateArray().Select(item => item.GetProperty("id").GetGuid()).ToArray();
    if (!ids.Contains(visible) || ids.Contains(hidden)) throw new InvalidDataException("Library grants were not enforced.");
    using var denied = await SendAsync(client, HttpMethod.Post, $"/api/v1/media/{hidden}/playback", token, null, HttpStatusCode.NotFound, lifetime.Token);
    metrics.Check("separate_library_grants");
}

async Task CheckRangeAsync(HttpClient client, string token, string path, bool head, CancellationToken cancellation)
{
    using var request = NewRequest(client, head ? HttpMethod.Head : HttpMethod.Get, path, token);
    request.Headers.Range = new RangeHeaderValue(123, 4218);
    var watch = Stopwatch.StartNew();
    using var response = await client.SendAsync(request, cancellation);
    metrics.Response(response.StatusCode, watch.Elapsed.TotalMilliseconds, response.Version);
    if (response.StatusCode != HttpStatusCode.PartialContent || response.Version != client.DefaultRequestVersion
        || response.Content.Headers.ContentRange?.From != 123 || response.Content.Headers.ContentRange?.To != 4218
        || response.Content.Headers.ContentLength != 4096)
        throw new InvalidDataException("Synthetic range headers were incorrect.");
    var body = await response.Content.ReadAsByteArrayAsync(cancellation);
    if (head ? body.Length != 0 : body.Length != 4096 || body.Where((value, offset) => value != (byte)((123 + offset) % 256)).Any())
        throw new InvalidDataException("Synthetic range body was incorrect.");
    metrics.Check(head ? "head_range" : "get_range");
}

async Task CancelPollAsync(HttpClient client, string token, CancellationToken cancellation)
{
    using var snapshot = await SendAsync(client, HttpMethod.Get, "/api/v1/sync/changes?after=0&waitSeconds=0", token, null, HttpStatusCode.OK, cancellation);
    var cursor = snapshot.RootElement.GetProperty("cursor").GetInt64();
    using var request = NewRequest(client, HttpMethod.Get, "/api/v1/sync/changes?after=" + cursor.ToString(CultureInfo.InvariantCulture) + "&waitSeconds=30", token);
    using var cancel = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
    cancel.CancelAfter(TimeSpan.FromMilliseconds(100));
    try
    {
        using var response = await client.SendAsync(request, cancel.Token);
        metrics.Response(response.StatusCode, 0, response.Version);
        response.EnsureSuccessStatusCode(); // A concurrent update may legitimately end the poll first.
    }
    catch (OperationCanceledException) when (cancel.IsCancellationRequested && !cancellation.IsCancellationRequested) { metrics.Check("cancelled_long_poll"); }
}

async Task AbortStreamAsync(HttpClient client, string token, string path, CancellationToken cancellation)
{
    using var request = NewRequest(client, HttpMethod.Get, path, token);
    using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
    metrics.Response(response.StatusCode, 0, response.Version);
    response.EnsureSuccessStatusCode();
    await using var stream = await response.Content.ReadAsStreamAsync(cancellation);
    var sample = new byte[1024];
    if (await stream.ReadAsync(sample, cancellation) == 0) throw new InvalidDataException("Synthetic stream unexpectedly empty.");
    metrics.Check("client_aborted_stream"); // Disposing the unfinished body exercises connection/stream cancellation.
}

static int FreePort()
{
    using var listener = new TcpListener(IPAddress.Loopback, 0);
    listener.Start();
    return ((IPEndPoint)listener.LocalEndpoint).Port;
}

static string StagePayload(string executable, string root)
{
    // Snapshot compiled binaries so a parallel later build cannot change the
    // managed assemblies or native libraries of a running soak server.
    var destination = Path.Combine(root, "HostPayload");
    PrivateFilePermissions.CreatePrivateDirectory(destination);
    var source = Path.GetDirectoryName(executable)!;
    foreach (var file in Directory.EnumerateFiles(source))
    {
        var extension = Path.GetExtension(file);
        if (file != executable && extension is not (".dll" or ".json" or ".dylib" or ".so" or ".pdb")) continue;
        var target = Path.Combine(destination, Path.GetFileName(file));
        File.Copy(file, target);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(target, File.GetUnixFileMode(file));
    }
    var nativeRoot = Path.Combine(source, "runtimes");
    if (Directory.Exists(nativeRoot))
        foreach (var file in Directory.EnumerateFiles(nativeRoot, "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(destination, "runtimes", Path.GetRelativePath(nativeRoot, file));
            PrivateFilePermissions.CreatePrivateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target);
        }
    return Path.Combine(destination, Path.GetFileName(executable));
}

static object PayloadEvidence(string directory)
{
    var entries = Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal).Select(path =>
    {
        using var input = File.OpenRead(path);
        return Path.GetRelativePath(directory, path) + ":" + Convert.ToHexString(SHA256.HashData(input));
    }).ToArray();
    return new
    {
        fileCount = entries.Length,
        manifestSha256 = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(string.Join('\n', entries)))),
        assemblyVersion = FileVersionInfo.GetVersionInfo(Path.Combine(directory, "Aurelia.Server.dll")).ProductVersion
    };
}

static async Task<ProbeSeed> SeedAsync(string root)
{
    var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["run", "--data-dir", root]);
    var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={runtime.DatabasePath};Pooling=False").Options;
    await using var database = new AureliaDbContext(options);
    await database.Database.MigrateAsync();
    var now = DateTimeOffset.UtcNow;
    database.ServerIdentities.Add(new ServerIdentity { Id = 1, ServerId = Guid.NewGuid(), CreatedAt = now });
    var users = ProbeSeed.Usernames.Select(name =>
    {
        var user = new ServerUser { Id = Guid.NewGuid(), Username = name, NormalizedUsername = name.ToUpperInvariant(), PasswordHash = "", Role = name == "probe-owner" ? UserRole.Owner : UserRole.User, CreatedAt = now };
        user.PasswordHash = new PasswordHasher<ServerUser>().HashPassword(user, ProbeSeed.Password);
        user.PinHash = new PasswordHasher<ServerUser>().HashPassword(user, "5682");
        return user;
    }).ToArray();
    database.Users.AddRange(users);
    database.AdministrationCredentials.Add(new ServerAdministrationCredential { PasswordHash = users.Single(user => user.Role == UserRole.Owner).PasswordHash });
    var movies = new List<Guid>();
    for (var index = 0; index < 2; index++)
    {
        var storage = Path.Combine(root, "SyntheticStorage" + index.ToString(CultureInfo.InvariantCulture));
        PrivateFilePermissions.CreatePrivateDirectory(storage);
        var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic library " + index.ToString(CultureInfo.InvariantCulture), Path = storage, NormalizedPath = MediaPath.Normalize(storage), Kind = LibraryKind.Movies, MonitoringEnabled = false, Availability = LibraryAvailability.Available, CreatedAt = now };
        database.LibraryRoots.Add(library);
        database.UserLibraryGrants.Add(new UserLibraryGrant { UserId = users[index + 1].Id, LibraryRootId = library.Id });
        var path = Path.Combine(storage, "Synthetic.mp4");
        await using (var file = PrivateFilePermissions.OpenNewPrivateFile(path))
        {
            var block = Enumerable.Range(0, 65536).Select(offset => (byte)(offset % 256)).ToArray();
            for (var count = 0; count < 128; count++) await file.WriteAsync(block);
        }
        var movie = new MediaItem { Id = Guid.NewGuid(), LibraryRootId = library.Id, Kind = MediaKind.Movie, DetectedTitle = "Synthetic movie " + index.ToString(CultureInfo.InvariantCulture), SourcePath = path, NormalizedSourcePath = MediaPath.Normalize(path), Extension = ".mp4", Availability = MediaAvailability.Available, CreatedAt = now, UpdatedAt = now };
        database.MediaItems.Add(movie);
        movies.Add(movie.Id);
    }
    await database.SaveChangesAsync();
    var settings = new ServerHostSettings(2, runtime.ServerName, false, runtime.LanHttpsPort)
    {
        MonitoringEnabled = false,
        BonjourEnabled = false
    };
    using (var configurationFile = PrivateFilePermissions.OpenNewPrivateFile(Path.Combine(root, ServerHostSettings.FileName)))
        JsonSerializer.Serialize(configurationFile, settings, new JsonSerializerOptions(JsonSerializerDefaults.Web));
    await database.Database.ExecuteSqlRawAsync("PRAGMA wal_checkpoint(TRUNCATE);");
    return new ProbeSeed(runtime, movies[0], movies[1]);
}

internal sealed record ProbeSeed(ServerRuntimeOptions Runtime, Guid FirstMovie, Guid SecondMovie)
{
    internal const string Password = "synthetic transport probe password";
    internal static readonly string[] Usernames = ["probe-owner", "probe-first", "probe-second"];
}

internal sealed class ProbeMetrics(int requestedSeconds)
{
    private readonly ConcurrentDictionary<string, long> counts = new(StringComparer.Ordinal);
    private long peakRss;
    private long samples;
    private long totalRss;
    private long cpuTicks;
    private readonly object timingsGate = new();
    private readonly List<double> timings = [];
    private readonly Stopwatch lifetime = Stopwatch.StartNew();
    private readonly List<ResourceWindow> windows = [];
    private readonly int windowSeconds = Math.Max(30, (int)Math.Ceiling(requestedSeconds / 240d));
    internal void Check(string name) => Count("check_" + name);
    internal void Failure(string name) => Count("failure_" + name);
    internal void Count(string name) { if (counts.Count < 64 || counts.ContainsKey(name)) counts.AddOrUpdate(name, 1, (_, count) => count + 1); }
    internal void Response(HttpStatusCode status, double ms, Version version)
    {
        Count("http_" + ((int)status).ToString(CultureInfo.InvariantCulture));
        Count("protocol_" + version);
        lock (timingsGate) if (timings.Count < 10000) timings.Add(ms);
    }
    internal void Sample(long rss, TimeSpan processCpu)
    {
        lock (timingsGate)
        {
            var elapsed = lifetime.Elapsed.TotalSeconds;
            var cpuMs = TimeSpan.FromTicks(Interlocked.Read(ref cpuTicks)).TotalMilliseconds + processCpu.TotalMilliseconds;
            var index = (int)(elapsed / windowSeconds);
            if (windows.Count == 0 || windows[^1].Index != index)
            {
                if (windows.Count < 256) windows.Add(new ResourceWindow(index, elapsed, rss, cpuMs));
            }
            if (windows.Count > 0) windows[^1].Update(elapsed, rss, cpuMs);
        }
        Interlocked.Increment(ref samples);
        Interlocked.Add(ref totalRss, rss);
        long previous;
        do { previous = Interlocked.Read(ref peakRss); if (rss <= previous) return; } while (Interlocked.CompareExchange(ref peakRss, rss, previous) != previous);
    }
    internal void Cpu(TimeSpan value) => Interlocked.Add(ref cpuTicks, value.Ticks);
    internal object Snapshot()
    {
        double[] ordered;
        object[] resourceWindows;
        lock (timingsGate)
        {
            ordered = timings.Order().ToArray();
            resourceWindows = windows.Select(window => window.Snapshot()).ToArray();
        }
        return new
        {
            counts = counts.OrderBy(entry => entry.Key).ToDictionary(),
            sampledResponses = ordered.Length,
            p50Ms = ordered.Length == 0 ? 0 : ordered[ordered.Length / 2],
            p95Ms = ordered.Length == 0 ? 0 : ordered[(int)(ordered.Length * .95)],
            peakRssBytes = peakRss,
            averageSampledRssBytes = samples == 0 ? 0 : totalRss / samples,
            serverCpuMs = TimeSpan.FromTicks(cpuTicks).TotalMilliseconds,
            resourceWindowSeconds = windowSeconds,
            resourceWindows,
            tlsCloseDiagnosticsRequireInvestigation = counts.ContainsKey("tls_bad_address") || counts.ContainsKey("tls_goaway_stack")
        };
    }

    private sealed class ResourceWindow(int index, double elapsed, long rss, double cpu)
    {
        internal int Index => index;
        private readonly double startSeconds = elapsed;
        private readonly long startRss = rss;
        private readonly double startCpu = cpu;
        private double endSeconds = elapsed;
        private long endRss = rss;
        private long peakRss = rss;
        private double endCpu = cpu;
        internal void Update(double seconds, long memory, double cpuMs)
        { endSeconds = seconds; endRss = memory; peakRss = Math.Max(peakRss, memory); endCpu = cpuMs; }
        internal object Snapshot() => new { startSeconds, endSeconds, startRssBytes = startRss, endRssBytes = endRss, peakRssBytes = peakRss, startCpuMs = startCpu, endCpuMs = endCpu };
    }
}

internal sealed class ProbeHost(string executable, string root, int httpPort, int httpsPort, ProbeMetrics metrics) : IAsyncDisposable
{
    private Process? process;
    private TimeSpan lastCpu;
    internal async Task StartAsync(CancellationToken token)
    {
        if (process is not null) throw new InvalidOperationException("The synthetic host is already running.");
        var candidate = new Process { StartInfo = new ProcessStartInfo(executable) { RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, UseShellExecute = false, WorkingDirectory = root } };
        process = candidate;
        foreach (var argument in new[] { "run", "--data-dir", root, "--urls", "http://127.0.0.1:" + httpPort.ToString(CultureInfo.InvariantCulture), "--lan-port", httpsPort.ToString(CultureInfo.InvariantCulture) }) process.StartInfo.ArgumentList.Add(argument);
        process.StartInfo.Environment["AURELIA_LAN_ENABLED"] = "false";
        process.StartInfo.Environment["AURELIA_HOST_PARENT_PID"] = Environment.ProcessId.ToString(CultureInfo.InvariantCulture);
        process.StartInfo.Environment["AURELIA_HOST_LIFELINE"] = "1";
        // Use the runtime executing this framework-dependent probe, not the
        // directory of a possibly symlinked dotnet command on PATH.
        process.StartInfo.Environment["DOTNET_ROOT"] = Path.GetFullPath(Path.Combine(
            System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", ".."));
        process.StartInfo.Environment["Logging__LogLevel__Default"] = "Warning";
        process.StartInfo.Environment["Logging__LogLevel__Microsoft.EntityFrameworkCore.Database.Command"] = "Warning";
        process.OutputDataReceived += (_, entry) => Observe(entry.Data);
        process.ErrorDataReceived += (_, entry) => Observe(entry.Data);
        try { process.Start(); }
        catch { process = null; candidate.Dispose(); throw; }
        lastCpu = TimeSpan.Zero;
        process.BeginOutputReadLine(); process.BeginErrorReadLine();
        using var readyClient = new HttpClient { BaseAddress = new Uri("http://127.0.0.1:" + httpPort.ToString(CultureInfo.InvariantCulture)), Timeout = TimeSpan.FromSeconds(1) };
        var deadline = DateTimeOffset.UtcNow.AddSeconds(30);
        while (DateTimeOffset.UtcNow < deadline)
        {
            token.ThrowIfCancellationRequested();
            if (process.HasExited) throw new InvalidOperationException("The owned synthetic host exited before readiness.");
            try { using var response = await readyClient.GetAsync("/api/v1/server/info", token); if (response.IsSuccessStatusCode) { Sample(); return; } }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) when (!token.IsCancellationRequested) { }
            await Task.Delay(100, token);
        }
        throw new TimeoutException("The owned synthetic host did not become ready.");
    }
    private void Observe(string? text)
    {
        if (text is null) return;
        if (text.Contains("Bad address", StringComparison.Ordinal)) metrics.Count("tls_bad_address");
        if (text.Contains("WriteGoAwayAsync", StringComparison.Ordinal)) metrics.Count("tls_goaway_stack");
        if (text.StartsWith("fail:", StringComparison.Ordinal)) { metrics.Count("server_failure_log"); CountLoggerHeader(text, "failure"); }
        if (text.StartsWith("warn:", StringComparison.Ordinal))
        {
            metrics.Count("server_warning_log");
            CountLoggerHeader(text, "warning");
            metrics.Count(text.Contains("DataProtection", StringComparison.Ordinal) ? "warning_data_protection"
                : text.Contains("HttpsRedirection", StringComparison.Ordinal) ? "warning_https_redirection"
                : text.Contains("EntityFrameworkCore", StringComparison.Ordinal) ? "warning_database_model"
                : text.Contains("Kestrel", StringComparison.Ordinal) ? "warning_kestrel"
                : "warning_other");
        }
    }
    private void CountLoggerHeader(string text, string severity)
    {
        var start = text.IndexOf(':') + 1;
        var bracket = text.IndexOf('[', start);
        var end = text.IndexOf(']', Math.Max(start, bracket));
        if (bracket < 0 || end < bracket) return;
        var category = text[start..bracket].Trim();
        if (category.Length > 128 || !(category.StartsWith("Microsoft.", StringComparison.Ordinal) || category.StartsWith("Aurelia.", StringComparison.Ordinal) || category.StartsWith("System.", StringComparison.Ordinal))
            || category.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not '.' and not '_')
            || !int.TryParse(text.AsSpan(bracket + 1, end - bracket - 1), NumberStyles.None, CultureInfo.InvariantCulture, out var eventId)) return;
        metrics.Count(severity + "_logger_" + category + "_event_" + eventId.ToString(CultureInfo.InvariantCulture));
    }
    internal void Sample()
    {
        if (process is null || process.HasExited) throw new InvalidOperationException("The owned synthetic host exited unexpectedly.");
        process.Refresh(); lastCpu = process.TotalProcessorTime; metrics.Sample(process.WorkingSet64, lastCpu);
    }
    internal async Task StopAsync()
    {
        if (process is null) return;
        var owned = process; process = null;
        try
        {
            if (owned.HasExited)
            {
                metrics.Count("unexpected_host_exit");
                throw new InvalidOperationException("The owned host exited without a requested shutdown.");
            }
            else
            {
                lastCpu = owned.TotalProcessorTime;
                // Closing the private lifeline requests normal host shutdown;
                // it also closes automatically if the probe itself crashes.
                owned.StandardInput.Close();
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                try { await owned.WaitForExitAsync(timeout.Token); }
                catch (OperationCanceledException)
                {
                    metrics.Count("forced_host_shutdown"); owned.Kill(entireProcessTree: true); await owned.WaitForExitAsync();
                    throw new TimeoutException("The owned host required forced shutdown.");
                }
            }
            metrics.Cpu(lastCpu);
        }
        finally { owned.Dispose(); }
    }
    public async ValueTask DisposeAsync() => await StopAsync();
}
