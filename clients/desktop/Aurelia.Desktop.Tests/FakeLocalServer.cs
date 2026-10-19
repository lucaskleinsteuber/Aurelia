using System.Text.Json.Nodes;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Tests;

/// <summary>A scripted bundled server: the test decides its state; nothing starts.</summary>
internal sealed class FakeLocalServerHost : ILocalServerHost
{
    public event Action? Changed;

    public LocalServerState State { get; private set; } = LocalServerState.Stopped;
    public string? Message { get; private set; }
    public ServerInfoResponse? Info { get; private set; }
    public LocalServerSettings Settings { get; set; } = new("Synthetic PC Server", true, 43111);
    public Uri SecureAddress => new($"https://127.0.0.1:{Settings.LanHttpsPort}");
    public bool SetUp { get; set; }
    public LocalServerState StartsAs { get; set; } = LocalServerState.SetupRequired;
    public List<string> Calls { get; } = [];

    public Task StartAsync()
    {
        Calls.Add("start");
        Move(SetUp ? LocalServerState.Running : StartsAs);
        return Task.CompletedTask;
    }

    public Task RestartAsync()
    {
        Calls.Add("restart");
        Move(LocalServerState.Restarting);
        Move(LocalServerState.Running);
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        Calls.Add("stop");
        Move(LocalServerState.Stopped);
        return Task.CompletedTask;
    }

    public Task<AuthenticationResponse> SetUpOwnerAsync(string serverName, string ownerName, string password, string deviceName, CancellationToken cancellation)
    {
        Calls.Add($"setup {serverName} {ownerName}");
        SetUp = true;
        Move(LocalServerState.Restarting);
        Move(LocalServerState.Running);
        return Task.FromResult(Owner(ownerName));
    }

    public Task<AuthenticationResponse> SignInAsync(string ownerName, string password, string deviceName, CancellationToken cancellation) =>
        password == "synthetic server password"
            ? Task.FromResult(Owner(ownerName))
            : Task.FromException<AuthenticationResponse>(new AureliaApiException(401, "invalid_credentials", "The credentials are incorrect."));

    public Task ResetOwnerPinAsync(string password, string pin, CancellationToken cancellation)
    {
        Calls.Add("reset " + pin);
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    /// <summary>Moves the server as a real one would, telling the app.</summary>
    public void Move(LocalServerState state, string? message = null)
    {
        State = state;
        Message = message;
        Info = new ServerInfoResponse(FakeServerApi.ServerId, Settings.ServerName, "1.7.16", SetUp, Settings.LanAccessEnabled, Settings.LanHttpsPort, null, null);
        Changed?.Invoke();
    }

    private static AuthenticationResponse Owner(string name) => new(new UserSummary(FakeServerApi.Owner.Id, name, UserRole.Owner, DateTimeOffset.UtcNow),
        Guid.NewGuid(), "synthetic-device-token-0123456789-abcdef", DateTimeOffset.UtcNow.AddDays(90));
}

/// <summary>Scripted owner management with synthetic storage locations and devices.</summary>
internal sealed class FakeManagement : IServerManagement
{
    public bool Locked { get; set; }
    public List<string> Calls { get; } = [];
    public List<LibrarySummary> Libraries { get; } =
    [
        Library("Movies", @"D:\Media\Movies", LibraryKind.Movies, scanned: true),
        Library("TV Shows", @"E:\TV Shows", LibraryKind.TvShows, scanned: true, available: false),
    ];
    public List<LibraryScanSummary> Scans { get; } = [];
    public int ScanPollsUntilDone { get; set; } = 1;

    public Task<DateTimeOffset> UnlockAsync(string password, CancellationToken cancellation)
    {
        if (password != "synthetic server password")
            return Task.FromException<DateTimeOffset>(new AureliaApiException(401, "invalid_management_password", "Incorrect."));
        Locked = false;
        return Task.FromResult(DateTimeOffset.UtcNow.AddMinutes(10));
    }

    public Task<ServerStatusResponse> StatusAsync(CancellationToken cancellation) => Guard(new ServerStatusResponse("running", "1.7.16", 120, 0, 1 << 20, 2,
        Libraries.Count, 1L << 40, DateTime.UtcNow.AddYears(9), ["192.168.1.40"],
        new ServerReadinessSummary("degraded", [new ServerComponentStatus("media", "degraded")], DateTimeOffset.UtcNow), []));

    public Task<ServerSettingsDocument> SettingsAsync(CancellationToken cancellation) => Guard(new ServerSettingsDocument(new JsonObject
    {
        ["version"] = 2,
        ["serverName"] = "Synthetic PC Server",
        ["lanAccessEnabled"] = true,
        ["lanHttpsPort"] = 43111,
    }, false));

    public Task<IReadOnlyList<LibrarySummary>> LibrariesAsync(CancellationToken cancellation) => Guard<IReadOnlyList<LibrarySummary>>([.. Libraries]);

    public Task<IReadOnlyList<LibraryScanSummary>> ActiveScansAsync(CancellationToken cancellation)
    {
        if (ScanPollsUntilDone-- <= 0) Scans.Clear();
        return Guard<IReadOnlyList<LibraryScanSummary>>([.. Scans]);
    }

    public Task<LibrarySummary> AddLibraryAsync(string? name, string path, LibraryKind kind, CancellationToken cancellation)
    {
        Calls.Add($"add {path} {kind}");
        var library = Library(name ?? Path.GetFileName(path), path, kind, scanned: false);
        Libraries.Add(library);
        return Guard(library);
    }

    public Task<LibraryScanSummary> ScanAsync(Guid library, CancellationToken cancellation)
    {
        Calls.Add("scan " + Libraries.Single(value => value.Id == library).Name);
        var scan = new LibraryScanSummary(Guid.NewGuid(), library, LibraryScanState.Running, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, null,
            240, 96, 0, 0, 0, 0, null, []);
        Scans.Add(scan);
        return Guard(scan);
    }

    public Task RemoveLibraryAsync(Guid library, CancellationToken cancellation)
    {
        Calls.Add("remove " + library);
        Libraries.RemoveAll(value => value.Id == library);
        return Guard(0);
    }

    public Task<DeviceAuthorizationPreview> LookUpDeviceAsync(string code, CancellationToken cancellation) =>
        Guard(new DeviceAuthorizationPreview(Guid.NewGuid(), "Living Room Apple TV", FakeServerApi.ServerId, "Synthetic PC Server",
            DeviceAuthorizationState.Pending, DateTimeOffset.UtcNow.AddMinutes(5)));

    public Task AnswerDeviceAsync(Guid request, bool approve, CancellationToken cancellation)
    {
        Calls.Add(approve ? "approve" : "deny");
        return Guard(0);
    }

    public Task<IReadOnlyList<DeviceSessionSummary>> DevicesAsync(CancellationToken cancellation) => Guard<IReadOnlyList<DeviceSessionSummary>>(
    [
        new(Guid.NewGuid(), FakeServerApi.Owner.Id, "Synthetic PC", DateTimeOffset.UtcNow.AddDays(-3), DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddDays(87), null, true),
        new(Guid.NewGuid(), FakeServerApi.Owner.Id, "Living Room Apple TV", DateTimeOffset.UtcNow.AddDays(-30), DateTimeOffset.UtcNow.AddHours(-2),
            DateTimeOffset.UtcNow.AddDays(60), null, false),
    ]);

    public Task RemoveDeviceAsync(Guid session, CancellationToken cancellation)
    {
        Calls.Add("remove device");
        return Guard(0);
    }

    public Task<ServerOperationStatus> TryNetworkAsync(JsonObject settings, bool confirmDisconnect, CancellationToken cancellation)
    {
        Calls.Add($"trial {settings["serverName"]} {settings["lanAccessEnabled"]} {confirmDisconnect}");
        return Guard(new ServerOperationStatus(Guid.NewGuid(), "network", "awaitingConfirmation", DateTimeOffset.UtcNow.AddSeconds(60), 43111));
    }

    public Task ConfirmNetworkAsync(Guid operation, CancellationToken cancellation)
    {
        Calls.Add("confirm");
        return Guard(0);
    }

    private Task<T> Guard<T>(T value) => Locked
        ? Task.FromException<T>(new AureliaApiException(403, "management_locked", "Unlock server management."))
        : Task.FromResult(value);

    private static LibrarySummary Library(string name, string path, LibraryKind kind, bool scanned, bool available = true) =>
        new(Guid.NewGuid(), name, path, kind, available ? LibraryAvailability.Available : LibraryAvailability.Unavailable,
            DateTimeOffset.UtcNow.AddDays(-10), scanned ? DateTimeOffset.UtcNow.AddHours(-3) : null, scanned ? DateTimeOffset.UtcNow.AddHours(-3) : null, null);
}

/// <summary>Start at sign-in and keeping awake as Windows would record them, without touching this computer.</summary>
internal sealed class FakeSystemHosting : ISystemHosting
{
    public bool CanStartAtSignIn => true;
    public SignInStart StartAtSignIn { get; private set; } = SignInStart.Off;
    public bool CanKeepAwake => true;
    public bool Awake { get; private set; }

    public void SetStartAtSignIn(bool enabled) => StartAtSignIn = enabled ? SignInStart.On : SignInStart.Off;
    public void KeepAwake(bool enabled) => Awake = enabled;

    /// <summary>The person turned Aurelia off in Task Manager's Startup apps.</summary>
    public void TurnOffInWindows() => StartAtSignIn = SignInStart.TurnedOffInWindows;
}
