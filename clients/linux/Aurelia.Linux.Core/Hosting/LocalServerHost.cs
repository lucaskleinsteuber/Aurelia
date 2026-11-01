using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Hosting;

public enum LocalServerState
{
    Stopped,
    Starting,
    SetupRequired,
    Running,
    Restarting,
    Failed,

    /// <summary>Another Aurelia Server already answers on this computer's ports, such as the Linux package's service.</summary>
    PortInUse,
}

/// <summary>Whether the hosted server keeps running with the window closed, starts at login and keeps the computer awake.</summary>
public sealed record HostingPreferences(bool KeepRunning, bool StartAtSignIn, bool KeepAwake);

/// <summary>The server's name, network access and HTTPS port as stored in its settings file.</summary>
public sealed record LocalServerSettings(string ServerName, bool LanAccessEnabled, int LanHttpsPort);

/// <summary>Where the bundled server lives and keeps its data on this computer.</summary>
public sealed record LocalServerOptions(
    string Executable,
    string DataDirectory,
    string LogDirectory,
    int HttpPort,
    int DefaultHttpsPort,
    bool DefaultLanAccess,
    string DefaultServerName)
{
    public const int StandardHttpPort = 43110;
    public const int StandardHttpsPort = 43111;

    /// <summary>
    /// The server that comes with the package, in its data folder under <c>$XDG_DATA_HOME</c>. It uses
    /// the ports a standalone Aurelia Server uses and is open to the home network, as on a Mac.
    /// </summary>
    public static LocalServerOptions ForThisComputer(AppPaths paths)
    {
        var executable = Environment.GetEnvironmentVariable("AURELIA_DESKTOP_SERVER") is { Length: > 0 } custom
            ? custom
            : Path.Combine(AppContext.BaseDirectory, "server", "Aurelia.Server");
        var name = $"Aurelia on {Environment.MachineName}";
        return new LocalServerOptions(executable, paths.ServerDirectory, paths.LogDirectory, StandardHttpPort, StandardHttpsPort,
            DefaultLanAccess: true, name.Length <= 128 ? name : "Aurelia");
    }
}

/// <summary>The bundled server as the app sees it; tests replace it with a scripted one.</summary>
public interface ILocalServerHost : IAsyncDisposable
{
    event Action? Changed;
    LocalServerState State { get; }
    string? Message { get; }
    ServerInfoResponse? Info { get; }
    LocalServerSettings Settings { get; }
    /// <summary>Where this app reaches its own server: HTTPS on this computer, whatever the network setting.</summary>
    Uri SecureAddress { get; }
    ServerInfoResponse? OtherServer { get; }
    Task StartAsync();
    Task RestartAsync();
    Task StopAsync();
    Task<AuthenticationResponse> SetUpOwnerAsync(string serverName, string ownerName, string password, int httpsPort, string deviceName, CancellationToken cancellation);
    Task<AuthenticationResponse> SignInAsync(string ownerName, string password, string deviceName, CancellationToken cancellation);
    Task ResetOwnerPinAsync(string password, string pin, CancellationToken cancellation);
}

/// <summary>
/// Starts and watches the server that ships inside the app, like the Mac app's server host: one
/// child process with a lifeline pipe (it stops when the app goes away, even after a crash), a
/// private control channel for restarts and network trials, a bounded log, and automatic recovery
/// within limits. The server first starts without network access so a new server can be set up
/// with a one-time bootstrap token; with an owner it runs with the stored network setting.
/// </summary>
public sealed class LocalServerHost : ILocalServerHost
{
    private const int AutomaticRestartLimit = 3;
    private static readonly TimeSpan RestartWindow = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan ReadyTimeout = TimeSpan.FromSeconds(90);
    private static readonly JsonSerializerOptions Json = AureliaJson.Options;
    private readonly LocalServerOptions options;
    private readonly string secret = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private readonly Lock gate = new();
    private readonly Lock operationGate = new();
    private readonly TimeProvider operationTime;
    private readonly HttpClient local;
    private readonly Queue<DateTimeOffset> automaticRestarts = new();
    private readonly CancellationTokenSource disposal = new();
    private HostControlChannel? control;
    private ServerLog? log;
    private Process? process;
    private int generation;
    private string? bootstrapToken;
    private string? readyMarker;
    private TaskCompletionSource? ready;
    private bool stopping;
    private Task? watchdog;
    private volatile bool trialPending;

    public LocalServerHost(LocalServerOptions options, TimeProvider? time = null)
    {
        this.options = options;
        operationTime = time ?? TimeProvider.System;
        local = new HttpClient(new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false })
        {
            BaseAddress = new Uri($"http://127.0.0.1:{options.HttpPort}"),
            Timeout = TimeSpan.FromSeconds(15),
        };
    }

    public event Action? Changed;

    public LocalServerState State { get; private set; } = LocalServerState.Stopped;
    public string? Message { get; private set; }
    public ServerInfoResponse? Info { get; private set; }
    public LocalServerSettings Settings => ReadSettings();
    public Uri SecureAddress => new($"https://127.0.0.1:{Settings.LanHttpsPort}");
    /// <summary>The hosting choices the server reports to owners on other devices.</summary>
    public Func<HostingPreferences>? Hosting { get; set; }
    internal string ControlSecret => secret;
    /// <summary>The running server process, for tests that end it unexpectedly.</summary>
    internal int? ProcessId
    {
        get
        {
            lock (gate)
            {
                try { return process is { HasExited: false } running ? running.Id : null; }
                catch (InvalidOperationException) { return null; }
            }
        }
    }

    public async Task StartAsync()
    {
        await lifecycle.WaitAsync();
        try
        {
            if (State is LocalServerState.Running or LocalServerState.SetupRequired or LocalServerState.Starting) return;
            stopping = false;
            control ??= HostControlChannel.Start(secret, HandleControlAsync);
            log ??= new ServerLog(options.LogDirectory);
            automaticRestarts.Clear();
            // A network change from before the app closed may still wait for its confirmation.
            trialPending = ReadOperation()?["state"]?.GetValue<string>() == "awaitingConfirmation";
            await LaunchAsync(LocalServerState.Starting);
        }
        finally { lifecycle.Release(); }
        watchdog ??= Task.Run(() => WatchAsync(disposal.Token));
    }

    /// <summary>An explicit Try Again or Restart, which also resets the automatic recovery budget.</summary>
    public async Task RestartAsync()
    {
        await lifecycle.WaitAsync();
        try
        {
            stopping = false;
            control ??= HostControlChannel.Start(secret, HandleControlAsync);
            log ??= new ServerLog(options.LogDirectory);
            automaticRestarts.Clear();
            await StopProcessAsync();
            await LaunchAsync(LocalServerState.Restarting);
        }
        finally { lifecycle.Release(); }
        watchdog ??= Task.Run(() => WatchAsync(disposal.Token));
    }

    public async Task StopAsync()
    {
        await lifecycle.WaitAsync();
        try
        {
            stopping = true;
            await StopProcessAsync();
            Update(LocalServerState.Stopped, null);
        }
        finally { lifecycle.Release(); }
    }

    public async Task<AuthenticationResponse> SetUpOwnerAsync(string serverName, string ownerName, string password, int httpsPort, string deviceName,
        CancellationToken cancellation)
    {
        string token;
        lock (gate)
        {
            if (State != LocalServerState.SetupRequired || bootstrapToken is null)
                throw new AureliaApiException(409, "setup_unavailable", "This server is already set up or not ready. Try again in a moment.");
            token = bootstrapToken;
        }
        var name = serverName.Trim();
        if (name.Length is 0 or > 128) throw new AureliaApiException(400, "invalid_server_name", "Enter a server name of up to 128 characters.");
        if (httpsPort is < 1024 or > 65535 || httpsPort == options.HttpPort)
            throw new AureliaApiException(400, "invalid_port", "Choose an HTTPS port from 1024 to 65535 other than " + options.HttpPort.ToString(CultureInfo.InvariantCulture) + ".");
        // The name and port are the host's to set before the first owner exists, as on the Mac.
        UpdateSettings(settings =>
        {
            settings["serverName"] = name;
            settings["lanHttpsPort"] = httpsPort;
        });
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/setup/owner")
        {
            Content = JsonContent.Create(new SetupOwnerRequest(ownerName.Trim(), password, deviceName), options: Json),
        };
        request.Headers.Add("X-Aurelia-Bootstrap-Token", token);
        var owner = await SendLocalAsync<AuthenticationResponse>(request, cancellation);
        lock (gate) bootstrapToken = null;
        if (Info is { } info) Info = info with { IsSetup = true };
        // With an owner the server may now open to the network, as its settings ask.
        await RestartAsync();
        await WaitUntilRunningAsync(cancellation);
        return owner;
    }

    public async Task<AuthenticationResponse> SignInAsync(string ownerName, string password, string deviceName, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/auth/login")
        {
            Content = JsonContent.Create(new LoginRequest(ownerName.Trim(), password, deviceName), options: Json),
        };
        return await SendLocalAsync<AuthenticationResponse>(request, cancellation);
    }

    /// <summary>The other server found on this computer's port, when <see cref="State"/> is <see cref="LocalServerState.PortInUse"/>.</summary>
    public ServerInfoResponse? OtherServer { get; private set; }

    /// <summary>A forgotten owner PIN, reset with the Server Password through the private host channel.</summary>
    public async Task ResetOwnerPinAsync(string password, string pin, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/local/owner-pin")
        {
            Content = JsonContent.Create(new InitializeProfilesRequest(password, pin), options: Json),
        };
        request.Headers.Add("X-Aurelia-Host-Recovery", secret);
        await SendLocalAsync<AureliaApi.NoContent>(request, cancellation);
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        await disposal.CancelAsync();
        if (watchdog is not null)
        {
            try { await watchdog; }
            catch (OperationCanceledException) { }
        }
        control?.Dispose();
        log?.Dispose();
        local.Dispose();
        lifecycle.Dispose();
        disposal.Dispose();
    }

    internal async Task WaitUntilRunningAsync(CancellationToken cancellation)
    {
        var deadline = DateTimeOffset.UtcNow + ReadyTimeout;
        while (State != LocalServerState.Running)
        {
            if (State is LocalServerState.Failed or LocalServerState.Stopped)
                throw new AureliaApiException(503, "server_unavailable", Message ?? "Aurelia Server is not running.");
            if (DateTimeOffset.UtcNow > deadline) throw new AureliaApiException(503, "server_unavailable", "Aurelia Server did not become ready.");
            await Task.Delay(100, cancellation);
        }
    }

    /// <summary>Starts the server and waits for it; runs inside the lifecycle lock.</summary>
    private async Task LaunchAsync(LocalServerState showing)
    {
        Update(showing, null);
        if (!File.Exists(options.Executable))
        {
            Update(LocalServerState.Failed, "The server that comes with Aurelia is missing. Install Aurelia again.");
            return;
        }
        EnsureSettings();
        if (await OtherServerAsync() is { } other)
        {
            OtherServer = other;
            Update(LocalServerState.PortInUse, $"“{other.Name}” already runs on this computer, for example as the Aurelia Server system service.");
            return;
        }
        OtherServer = null;
        var settings = ReadSettings();
        // An owner known from an earlier run lets the server start with network access directly;
        // without one it starts closed with a bootstrap token, and opens after setup.
        var lan = settings.LanAccessEnabled && Info?.IsSetup == true;
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var exit = await RunOnceAsync(lan);
            if (exit is null) return;
            if (exit == 2 && lan)
            {
                // The server refuses network access without an owner; set it up first.
                lan = false;
                continue;
            }
            Update(LocalServerState.Failed, exit == -1
                ? "Aurelia Server did not become ready. Choose Try Again."
                : "Aurelia Server could not start. Another Aurelia may be using it, or its port is taken.");
            return;
        }
    }

    /// <summary>An Aurelia Server that answers on this computer's port before this app started one.</summary>
    private async Task<ServerInfoResponse?> OtherServerAsync()
    {
        lock (gate)
        {
            if (process is not null) return null;
        }
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            return await local.GetFromJsonAsync<ServerInfoResponse>("/api/v1/server/info", Json, timeout.Token);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or JsonException or NotSupportedException)
        {
            return null;
        }
    }

    /// <summary>Null when the server became ready; otherwise its exit code, or -1 for a timeout.</summary>
    private async Task<int?> RunOnceAsync(bool lan)
    {
        var settings = ReadSettings();
        var nonce = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
        var token = lan ? null : Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
        var start = new ProcessStartInfo(options.Executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(options.Executable) ?? AppContext.BaseDirectory,
        };
        foreach (var argument in new[]
        {
            "run", "--data-dir", options.DataDirectory, "--urls", $"http://127.0.0.1:{options.HttpPort}",
            "--lan-port", settings.LanHttpsPort.ToString(CultureInfo.InvariantCulture),
            "--host-parent-pid", Environment.ProcessId.ToString(CultureInfo.InvariantCulture), "--local-https",
        }) start.ArgumentList.Add(argument);
        if (lan) start.ArgumentList.Add("--lan");
        start.Environment["AURELIA_LAN_ENABLED"] = lan ? "true" : "false";
        start.Environment["AURELIA_HOST_READY_NONCE"] = nonce;
        start.Environment["AURELIA_HOST_LIFELINE"] = "1";
        start.Environment["AURELIA_HOST_CONTROL_URL"] = control!.Address.AbsoluteUri.TrimEnd('/');
        if (token is null) start.Environment.Remove("AURELIA_BOOTSTRAP_TOKEN");
        else start.Environment["AURELIA_BOOTSTRAP_TOKEN"] = token;
        // Only the arguments above decide how the server runs, never a leftover test environment.
        foreach (var name in new[] { "ASPNETCORE_ENVIRONMENT", "DOTNET_ENVIRONMENT", "ASPNETCORE_URLS", "AURELIA_LOCAL_HTTPS" })
            start.Environment.Remove(name);

        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var child = new Process { StartInfo = start, EnableRaisingEvents = true };
        int current;
        lock (gate)
        {
            current = ++generation;
            readyMarker = "AURELIA_SERVER_READY:" + nonce;
            ready = started;
            bootstrapToken = token;
        }
        child.OutputDataReceived += (_, line) => Received(current, line.Data);
        child.ErrorDataReceived += (_, line) => Received(current, line.Data);
        child.Exited += (_, _) => _ = Task.Run(() => ExitedAsync(current, child));
        try
        {
            child.Start();
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            child.Dispose();
            log?.Write("The bundled server could not be started: " + error.Message);
            return 1;
        }
        lock (gate) process = child;
        child.BeginOutputReadLine();
        child.BeginErrorReadLine();

        var exited = child.WaitForExitAsync();
        var first = await Task.WhenAny(started.Task, exited, Task.Delay(ReadyTimeout));
        if (first != started.Task)
        {
            if (first != exited)
            {
                await StopProcessAsync();
                return -1;
            }
            lock (gate)
            {
                if (ReferenceEquals(process, child)) process = null;
            }
            var code = ExitCode(child);
            child.Dispose();
            return code;
        }
        ServerInfoResponse? info = null;
        for (var attempt = 0; attempt < 50 && info is null && !child.HasExited; attempt++)
        {
            try { info = await local.GetFromJsonAsync<ServerInfoResponse>("/api/v1/server/info", Json); }
            catch (Exception error) when (error is HttpRequestException or TaskCanceledException or JsonException) { await Task.Delay(100); }
        }
        if (info is null)
        {
            var failed = child.HasExited ? ExitCode(child) : -1;
            await StopProcessAsync();
            return failed;
        }
        Info = info;
        if (!lan && info.IsSetup && ReadSettings().LanAccessEnabled)
        {
            // Set up earlier, but this start did not know it yet: reopen with network access.
            await StopProcessAsync();
            return await RunOnceAsync(lan: true);
        }
        Update(info.IsSetup ? LocalServerState.Running : LocalServerState.SetupRequired, null);
        return null;
    }

    private static int ExitCode(Process child)
    {
        try { return child.ExitCode; }
        catch (InvalidOperationException) { return 1; }
    }

    private void Received(int current, string? line)
    {
        if (line is null) return;
        TaskCompletionSource? signal = null;
        lock (gate)
        {
            if (current == generation && readyMarker is not null && line.Contains(readyMarker, StringComparison.Ordinal))
                signal = ready;
        }
        if (signal is not null)
        {
            signal.TrySetResult();
            return;
        }
        // The readiness markers carry the nonce; everything else is the server's own log.
        if (!line.Contains("AURELIA_SERVER_READY:", StringComparison.Ordinal) && !line.Contains("AURELIA_SERVER_STOPPING:", StringComparison.Ordinal))
            log?.Write(line);
    }

    /// <summary>An exit nobody asked for: restart within the recovery budget, then ask the person.</summary>
    private async Task ExitedAsync(int exited, Process child)
    {
        // A start, restart or stop in progress owns the process and handles this exit itself.
        if (!await lifecycle.WaitAsync(0)) return;
        try
        {
            lock (gate)
            {
                if (exited != generation || stopping || !ReferenceEquals(process, child)) return;
                process = null;
            }
            child.Dispose();
            await RecoverAsync("Aurelia Server stopped unexpectedly. Restarting…");
        }
        finally { lifecycle.Release(); }
    }

    private async Task RecoverAsync(string reason)
    {
        var now = DateTimeOffset.UtcNow;
        while (automaticRestarts.Count > 0 && now - automaticRestarts.Peek() > RestartWindow) automaticRestarts.Dequeue();
        if (automaticRestarts.Count >= AutomaticRestartLimit)
        {
            await StopProcessAsync();
            Update(LocalServerState.Failed, "Aurelia Server stopped repeatedly. Choose Try Again.");
            return;
        }
        automaticRestarts.Enqueue(now);
        log?.Write(reason);
        await StopProcessAsync();
        Update(LocalServerState.Restarting, reason);
        await Task.Delay(1000);
        await LaunchAsync(LocalServerState.Restarting);
    }

    /// <summary>Liveness every 15 seconds; three silent probes in a row count as a stopped server.</summary>
    private async Task WatchAsync(CancellationToken cancellation)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        var silent = 0;
        var tick = 0;
        while (await timer.WaitForNextTickAsync(cancellation))
        {
            if (trialPending)
            {
                try { await RollBackExpiredTrialAsync(); }
                catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException) { log?.Write(error.Message); }
            }
            if (++tick % 15 != 0 || State is not (LocalServerState.Running or LocalServerState.SetupRequired)) continue;
            var answered = false;
            try
            {
                using var probe = new HttpRequestMessage(HttpMethod.Head, "/api/v1/health/live");
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
                timeout.CancelAfter(TimeSpan.FromSeconds(3));
                using var response = await local.SendAsync(probe, timeout.Token);
                answered = true;
            }
            catch (Exception error) when (error is HttpRequestException or TaskCanceledException && !cancellation.IsCancellationRequested) { }
            silent = answered ? 0 : silent + 1;
            if (silent < 3) continue;
            silent = 0;
            if (!await lifecycle.WaitAsync(0, CancellationToken.None)) continue;
            try
            {
                if (State is LocalServerState.Running or LocalServerState.SetupRequired)
                    await RecoverAsync("Aurelia Server stopped answering. Restarting…");
            }
            finally { lifecycle.Release(); }
        }
    }

    /// <summary>Closes the lifeline so the server shuts down cleanly, and ends it only if it does not.</summary>
    private async Task StopProcessAsync()
    {
        Process? child;
        lock (gate)
        {
            child = process;
            process = null;
            generation++;
            bootstrapToken = null;
        }
        if (child is null) return;
        try
        {
            if (!child.HasExited)
            {
                try { child.StandardInput.Close(); }
                catch (IOException) { }
                using var wait = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                try { await child.WaitForExitAsync(wait.Token); }
                catch (OperationCanceledException) { child.Kill(entireProcessTree: true); }
            }
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        finally { child.Dispose(); }
    }

    private void Update(LocalServerState state, string? message)
    {
        lock (gate)
        {
            if (State == state && Message == message) return;
            State = state;
            Message = message;
        }
        Changed?.Invoke();
    }

    private async Task<T> SendLocalAsync<T>(HttpRequestMessage request, CancellationToken cancellation)
    {
        request.Headers.Accept.Add(new System.Net.Http.Headers.MediaTypeWithQualityHeaderValue("application/json"));
        HttpResponseMessage response;
        try { response = await local.SendAsync(request, cancellation); }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException && !cancellation.IsCancellationRequested)
        {
            throw new AureliaApiException(0, "server_unavailable", "Aurelia Server on this computer is not answering. Try again in a moment.");
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                ApiProblem? problem = null;
                try { problem = await response.Content.ReadFromJsonAsync<ApiProblem>(Json, cancellation); }
                catch (JsonException) { }
                throw new AureliaApiException((int)response.StatusCode, problem?.Code,
                    problem?.Message is { Length: > 0 } message ? message : "Aurelia Server could not complete this.");
            }
            if (typeof(T) == typeof(AureliaApi.NoContent)) return default!;
            return await response.Content.ReadFromJsonAsync<T>(Json, cancellation) ?? throw AureliaApiException.InvalidResponse();
        }
    }

    private string SettingsPath => Path.Combine(options.DataDirectory, "server-settings.json");
    private string OperationPath => Path.Combine(options.DataDirectory, "host-operation.json");

    /// <summary>A new server starts with this computer's name, the default port and network access as the platform suggests.</summary>
    private void EnsureSettings()
    {
        PrivateFiles.CreateDirectory(options.DataDirectory);
        if (File.Exists(SettingsPath)) return;
        WritePrivateJson(SettingsPath, new JsonObject
        {
            ["version"] = 1,
            ["serverName"] = options.DefaultServerName.Length <= 128 ? options.DefaultServerName : "Aurelia",
            ["lanAccessEnabled"] = options.DefaultLanAccess,
            ["lanHttpsPort"] = options.DefaultHttpsPort,
        });
    }

    private LocalServerSettings ReadSettings()
    {
        try
        {
            if (JsonNode.Parse(File.ReadAllText(SettingsPath)) is JsonObject stored)
                return new LocalServerSettings(
                    stored["serverName"]?.GetValue<string>() ?? options.DefaultServerName,
                    stored["lanAccessEnabled"]?.GetValue<bool>() ?? options.DefaultLanAccess,
                    stored["lanHttpsPort"]?.GetValue<int>() ?? options.DefaultHttpsPort);
        }
        catch (Exception error) when (error is IOException or JsonException or InvalidOperationException or FormatException) { }
        return new LocalServerSettings(options.DefaultServerName, options.DefaultLanAccess, options.DefaultHttpsPort);
    }

    /// <summary>Changes only the named fields; the server's own fields stay as it wrote them.</summary>
    private void UpdateSettings(Action<JsonObject> change)
    {
        var stored = JsonNode.Parse(File.ReadAllText(SettingsPath)) as JsonObject ?? throw new InvalidDataException("The server settings are unreadable.");
        change(stored);
        WritePrivateJson(SettingsPath, stored);
    }

    private static void WritePrivateJson(string path, JsonNode value)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        try
        {
            using (var file = new FileStream(temporary, options)) file.Write(System.Text.Encoding.UTF8.GetBytes(value.ToJsonString()));
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private JsonObject? ReadOperation()
    {
        try
        {
            var info = new FileInfo(OperationPath);
            if (!info.Exists || info.LinkTarget is not null || info.Length > 65_536) return null;
            return JsonNode.Parse(File.ReadAllText(OperationPath)) is JsonObject operation && operation["version"]?.GetValue<int>() == 1
                ? operation : null;
        }
        catch (Exception error) when (error is IOException or JsonException or InvalidOperationException or FormatException) { return null; }
    }

    private static bool Matches(JsonObject? operation, JsonObject? body, string? kind = null, string? state = null) =>
        operation is not null && body?["id"]?.GetValue<string>() is { } id
        && string.Equals(operation["id"]?.GetValue<string>(), id, StringComparison.OrdinalIgnoreCase)
        && (kind is null || operation["kind"]?.GetValue<string>() == kind)
        && (state is null || operation["state"]?.GetValue<string>() == state);

    private static DateTimeOffset? Deadline(JsonObject operation) =>
        DateTimeOffset.TryParse(operation["confirmBefore"]?.GetValue<string>(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var value)
            ? value : null;

    /// <summary>The server's calls to its host: the same small protocol the Mac's server host answers.</summary>
    private async Task<(int Status, string Body)> HandleControlAsync(string method, string action, JsonObject? body)
    {
        switch (method, action)
        {
            case ("GET", "hosting-status"):
                {
                    // The server runs inside this app either way; it keeps running in the notification area when asked to.
                    var hosting = Hosting?.Invoke() ?? new HostingPreferences(false, false, false);
                    return (200, JsonSerializer.Serialize(new
                    {
                        backgroundEnabled = hosting.KeepRunning,
                        backgroundRequested = hosting.KeepRunning,
                        startAtLogin = hosting.StartAtSignIn,
                        preventIdleSleep = hosting.KeepAwake,
                        state = "unchanged"
                    }));
                }
            case ("POST", "restart"):
                Later(RestartAsync);
                return (202, "");
            case ("POST", "network-trial") when Matches(ReadOperation(), body, state: "awaitingConfirmation"):
                trialPending = true;
                Later(RestartAsync);
                return (202, "");
            case ("POST", "network-confirm"):
                return (ConfirmNetwork(body) ? 204 : 409, "");
            case ("POST", "restore-prepared") when Matches(ReadOperation(), body, kind: "restore")
                && Guid.TryParse(body!["id"]!.GetValue<string>(), out var restore):
                Later(() => ApplyRestoreAsync(restore));
                return (202, "");
            default:
                return (method, action) is ("POST", "hosting-authorized") ? (409, "") : (404, "");
        }
    }

    /// <summary>Lets the response to the server go out before the server is stopped.</summary>
    private void Later(Func<Task> operation) => _ = Task.Run(async () =>
    {
        await Task.Delay(250);
        try { await operation(); }
        catch (Exception error) when (error is IOException or InvalidOperationException or AureliaApiException) { log?.Write(error.Message); }
    });

    /// <summary>Serializes a confirmation with the watchdog's deadline check and journal update.</summary>
    internal bool ConfirmNetwork(JsonObject? body)
    {
        lock (operationGate)
        {
            var operation = ReadOperation();
            if (!Matches(operation, body, state: "awaitingConfirmation") || Deadline(operation!) is not { } deadline || deadline <= operationTime.GetUtcNow())
                return false;
            operation!["state"] = "completed";
            operation["confirmBefore"] = null;
            operation["previousSettings"] = null;
            WritePrivateJson(OperationPath, operation);
            trialPending = false;
            return true;
        }
    }

    /// <summary>A network change that was not confirmed within its minute returns to the previous settings.</summary>
    internal async Task RollBackExpiredTrialAsync()
    {
        lock (operationGate)
        {
            var operation = ReadOperation();
            if (operation?["state"]?.GetValue<string>() != "awaitingConfirmation")
            {
                trialPending = false;
                return;
            }
            if (Deadline(operation) is not { } deadline || deadline > operationTime.GetUtcNow() || operation["previousSettings"] is not JsonObject previous) return;
            trialPending = false;
            WritePrivateJson(SettingsPath, previous.DeepClone());
            operation["state"] = "rolledBack";
            operation["confirmBefore"] = null;
            operation["previousSettings"] = null;
            WritePrivateJson(OperationPath, operation);
        }
        log?.Write("The network change was not confirmed in time; the previous settings are back.");
        await RestartAsync();
    }

    /// <summary>Replaces the server state with a verified backup while the server is stopped, then starts it again.</summary>
    private async Task ApplyRestoreAsync(Guid restore)
    {
        await lifecycle.WaitAsync();
        try
        {
            Update(LocalServerState.Restarting, "Restoring verified server state. All devices will need to sign in again.");
            await StopProcessAsync();
            var start = new ProcessStartInfo(options.Executable)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            foreach (var argument in new[] { "database", "restore-prepared", "--id", restore.ToString("D"), "--data-dir", options.DataDirectory })
                start.ArgumentList.Add(argument);
            var succeeded = false;
            using (var restoring = Process.Start(start))
            {
                if (restoring is not null)
                {
                    restoring.OutputDataReceived += (_, line) => { if (line.Data is not null) log?.Write(line.Data); };
                    restoring.ErrorDataReceived += (_, line) => { if (line.Data is not null) log?.Write(line.Data); };
                    restoring.BeginOutputReadLine();
                    restoring.BeginErrorReadLine();
                    using var limit = new CancellationTokenSource(TimeSpan.FromMinutes(10));
                    await restoring.WaitForExitAsync(limit.Token);
                    succeeded = restoring.ExitCode == 0;
                }
            }
            if (ReadOperation() is { } operation)
            {
                operation["state"] = succeeded ? "completed" : "failed";
                WritePrivateJson(OperationPath, operation);
            }
            await LaunchAsync(LocalServerState.Restarting);
        }
        finally { lifecycle.Release(); }
    }
}

/// <summary>
/// The private channel the server uses to ask its host for restarts and network trials: plain HTTP
/// on 127.0.0.1 at a random port, and only requests carrying the secret path are answered.
/// </summary>
internal sealed class HostControlChannel : IDisposable
{
    private readonly System.Net.Sockets.TcpListener listener;
    private readonly string secret;
    private readonly Func<string, string, JsonObject?, Task<(int Status, string Body)>> handle;
    private readonly CancellationTokenSource stop = new();

    private HostControlChannel(string secret, Func<string, string, JsonObject?, Task<(int, string)>> handle)
    {
        this.secret = secret;
        this.handle = handle;
        listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
    }

    public Uri Address { get; private set; } = null!;

    public static HostControlChannel Start(string secret, Func<string, string, JsonObject?, Task<(int, string)>> handle)
    {
        var channel = new HostControlChannel(secret, handle);
        channel.listener.Start();
        channel.Address = new Uri($"http://127.0.0.1:{((IPEndPoint)channel.listener.LocalEndpoint).Port}/{secret}");
        _ = Task.Run(channel.AcceptAsync);
        return channel;
    }

    public void Dispose()
    {
        stop.Cancel();
        listener.Stop();
        stop.Dispose();
    }

    private async Task AcceptAsync()
    {
        while (!stop.IsCancellationRequested)
        {
            System.Net.Sockets.TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(stop.Token); }
            catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or System.Net.Sockets.SocketException) { return; }
            _ = Task.Run(() => ServeAsync(client));
        }
    }

    private async Task ServeAsync(System.Net.Sockets.TcpClient client)
    {
        using (client)
        {
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                var stream = client.GetStream();
                var (method, target, body) = await ReadRequestAsync(stream, timeout.Token);
                var prefix = "/" + secret + "/";
                var (status, text) = method is null || target is null || !target.StartsWith(prefix, StringComparison.Ordinal)
                    ? (404, "")
                    : await handle(method, target[prefix.Length..], body);
                var payload = System.Text.Encoding.UTF8.GetBytes(text);
                var reason = status switch { 200 => "OK", 202 => "Accepted", 204 => "No Content", 404 => "Not Found", 409 => "Conflict", _ => "Bad Request" };
                var head = $"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
                await stream.WriteAsync(System.Text.Encoding.ASCII.GetBytes(head), timeout.Token);
                await stream.WriteAsync(payload, timeout.Token);
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or JsonException or InvalidOperationException) { }
        }
    }

    /// <summary>One bounded request with a Content-Length body, which is all the server sends.</summary>
    internal static async Task<(string? Method, string? Target, JsonObject? Body)> ReadRequestAsync(Stream stream, CancellationToken cancellation)
    {
        var buffer = new byte[16_384];
        var length = 0;
        int headerEnd;
        while ((headerEnd = IndexOfHeaderEnd(buffer, length)) < 0)
        {
            if (length == buffer.Length) return (null, null, null);
            var read = await stream.ReadAsync(buffer.AsMemory(length), cancellation);
            if (read == 0) return (null, null, null);
            length += read;
        }
        var lines = System.Text.Encoding.ASCII.GetString(buffer, 0, headerEnd).Split("\r\n");
        var request = lines[0].Split(' ');
        if (request.Length != 3 || request[1].Contains('?', StringComparison.Ordinal)) return (null, null, null);
        var contentLength = 0;
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':', StringComparison.Ordinal);
            if (colon <= 0) continue;
            var name = line[..colon].Trim();
            if (name.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase)) return (null, null, null);
            if (name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)
                && (!int.TryParse(line[(colon + 1)..].Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out contentLength) || contentLength > 65_536))
                return (null, null, null);
        }
        var body = new byte[contentLength];
        var have = Math.Min(contentLength, length - headerEnd - 4);
        Array.Copy(buffer, headerEnd + 4, body, 0, have);
        while (have < contentLength)
        {
            var read = await stream.ReadAsync(body.AsMemory(have), cancellation);
            if (read == 0) return (null, null, null);
            have += read;
        }
        JsonObject? parsed = contentLength == 0 ? null : JsonNode.Parse(body) as JsonObject;
        return (request[0], request[1], parsed);
    }

    private static int IndexOfHeaderEnd(byte[] buffer, int length)
    {
        for (var index = 3; index < length; index++)
            if (buffer[index - 3] == '\r' && buffer[index - 2] == '\n' && buffer[index - 1] == '\r' && buffer[index] == '\n') return index - 3;
        return -1;
    }
}

/// <summary>The server's output in the app's log folder, kept to about 10 MB across two files.</summary>
internal sealed class ServerLog : IDisposable
{
    private const long Limit = 5 * 1024 * 1024;
    private readonly Lock gate = new();
    private readonly string path;
    private StreamWriter? writer;

    public ServerLog(string directory)
    {
        PrivateFiles.CreateDirectory(directory);
        path = Path.Combine(directory, "server.log");
    }

    public void Write(string line)
    {
        lock (gate)
        {
            try
            {
                writer ??= Open();
                if (writer.BaseStream.Length > Limit)
                {
                    writer.Dispose();
                    File.Move(path, path + ".1", overwrite: true);
                    writer = Open();
                }
                writer.WriteLine($"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss} {line}");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            writer?.Dispose();
            writer = null;
        }
    }

    private StreamWriter Open()
    {
        var options = new FileStreamOptions { Mode = FileMode.Append, Access = FileAccess.Write, Share = FileShare.Read };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        return new StreamWriter(new FileStream(path, options)) { AutoFlush = true };
    }
}
