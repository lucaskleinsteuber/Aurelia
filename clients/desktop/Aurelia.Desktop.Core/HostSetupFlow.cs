using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

public enum HostPhase { Inactive, Choose, Starting, Failed, OwnerSetup, SignIn, CreatePin, ResetPin, Storage, Scanning }

/// <summary>A folder chosen for the first import, with the kind of media it holds.</summary>
public sealed class StorageDraft(string path) : INotifyPropertyChanged
{
    public string Path { get; } = path;
    /// <summary>The folder's own name, or the drive itself (D:\) when a whole drive was chosen.</summary>
    public string Name
    {
        get
        {
            var trimmed = Path.TrimEnd('\\', '/');
            var separator = trimmed.LastIndexOfAny(['\\', '/']);
            return separator >= 0 && separator < trimmed.Length - 1 ? trimmed[(separator + 1)..] : Path;
        }
    }
    public LibraryKind Kind { get; set; } = LibraryKind.Automatic;
    public event PropertyChangedEventHandler? PropertyChanged;
    internal void Changed() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Kind)));
}

/// <summary>
/// "Set Up This PC", as "Set Up This Mac" in the Mac app: start the bundled server, create its owner
/// with a Server Password, choose the owner's viewing PIN, and pick the first storage locations.
/// Later starts go straight to the profiles. Hands the finished connection to the connection flow.
/// </summary>
public sealed class HostSetupFlow : INotifyPropertyChanged
{
    private readonly ILocalServerHost host;
    private readonly IAureliaServerApi api;
    private readonly ConnectionStore store;
    private readonly AppModeStore modes;
    private readonly Func<StoredConnection, ProfileSessionResponse, IServerManagement> management;
    private readonly string deviceName;
    private readonly Action<Action> dispatch;
    private StoredConnection? connection;
    private ProfileSessionResponse? session;
    private IServerManagement? manager;
    private string? setupPassword;
    private CancellationTokenSource? scanWatch;
    private bool handedOver;

    public HostSetupFlow(ILocalServerHost host, IAureliaServerApi api, ConnectionStore store, AppModeStore modes,
        Func<StoredConnection, ProfileSessionResponse, IServerManagement> management, string deviceName, Action<Action> dispatch)
    {
        this.host = host;
        this.api = api;
        this.store = store;
        this.modes = modes;
        this.management = management;
        this.deviceName = deviceName;
        this.dispatch = dispatch;
        ServerName = host.Settings.ServerName;
        var account = Environment.UserName.Trim();
        OwnerName = account.Length >= 3 ? account : "Owner";
        host.Changed += () => dispatch(HostChanged);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>The server is ready and a profile may be opened; the session is set when one already is.</summary>
    public event Action<StoredConnection, ProfileSessionResponse?>? Ready;

    /// <summary>The person chose to connect to a server elsewhere.</summary>
    public event Action? ClientModeChosen;

    /// <summary>The server restarted or stopped while a profile was open; its profile sessions ended with it.</summary>
    public event Action? ServerInterrupted;

    public HostPhase Phase { get; private set => Set(ref field, value, nameof(Phase), PhaseProperties); } = HostPhase.Inactive;
    public bool IsBusy { get; private set => Set(ref field, value); }
    public string? Error { get; private set => Set(ref field, value, nameof(Error), [nameof(HasError)]); }
    public bool HasError => Error is not null;
    public string ServerName { get; set => Set(ref field, value); }
    public string OwnerName { get; set => Set(ref field, value); }
    public string StatusTitle { get; private set => Set(ref field, value); } = "Starting your server…";
    public string? StatusMessage { get; private set => Set(ref field, value); }
    public string ScanProgress { get; private set => Set(ref field, value); } = "";
    /// <summary>Tells a new owner that the server keeps running when the window closes, where that applies.</summary>
    public string? BackgroundNote { get; set => Set(ref field, value, nameof(BackgroundNote), [nameof(HasBackgroundNote)]); }
    public bool HasBackgroundNote => BackgroundNote is not null;
    public ObservableCollection<StorageDraft> Locations { get; } = [];
    public bool HasLocations => Locations.Count > 0;
    /// <summary>The PIN step after a restart needs the password again; right after setup it is still known.</summary>
    public bool NeedsPasswordForPin => setupPassword is null;
    public bool IsActive => Phase != HostPhase.Inactive;
    public bool ShowsChoose => Phase == HostPhase.Choose;
    public bool ShowsStarting => Phase == HostPhase.Starting;
    public bool ShowsFailed => Phase == HostPhase.Failed;
    public bool ShowsOwnerSetup => Phase == HostPhase.OwnerSetup;
    public bool ShowsSignIn => Phase == HostPhase.SignIn;
    public bool ShowsCreatePin => Phase == HostPhase.CreatePin;
    public bool ShowsResetPin => Phase == HostPhase.ResetPin;
    public bool ShowsStorage => Phase == HostPhase.Storage;
    public bool ShowsScanning => Phase == HostPhase.Scanning;
    public ILocalServerHost Host => host;

    private static readonly string[] PhaseProperties =
        [nameof(IsActive), nameof(ShowsChoose), nameof(ShowsStarting), nameof(ShowsFailed), nameof(ShowsOwnerSetup), nameof(ShowsSignIn),
         nameof(ShowsCreatePin), nameof(ShowsResetPin), nameof(ShowsStorage), nameof(ShowsScanning), nameof(NeedsPasswordForPin)];

    /// <summary>The first screen when this computer has neither a server nor a connection yet.</summary>
    public void ShowChoice() => Phase = HostPhase.Choose;

    public Task ChooseHostAsync()
    {
        modes.Save(AppMode.Host);
        // A connection to another server does not belong to this computer's own server.
        if (store.Load() is { LocalHost: false }) store.Clear();
        return StartAsync();
    }

    public void ChooseClient()
    {
        modes.Save(AppMode.Client);
        handedOver = false;
        Phase = HostPhase.Inactive;
        ClientModeChosen?.Invoke();
    }

    /// <summary>Stops this computer's server and connects to another one instead.</summary>
    public async Task UseAnotherServerAsync()
    {
        CancelScanWatch();
        await host.StopAsync();
        if (store.Load() is { LocalHost: true }) store.Clear();
        ChooseClient();
    }

    public async Task StartAsync()
    {
        Error = null;
        StatusTitle = "Starting your server…";
        StatusMessage = null;
        Phase = HostPhase.Starting;
        await host.StartAsync();
        dispatch(HostChanged);
    }

    public async Task RetryAsync()
    {
        Error = null;
        Phase = HostPhase.Starting;
        StatusTitle = "Starting your server…";
        await host.RestartAsync();
    }

    public Task SetUpAsync(string password, string confirmation)
    {
        if (password != confirmation) return Fail("The passwords do not match.");
        if (password.Length < 12) return Fail("Use at least 12 characters for the Server Password.");
        if (ServerName.Trim().Length is 0 or > 128) return Fail("Enter a server name.");
        if (OwnerName.Trim().Length < 3) return Fail("Enter an owner name with at least three characters.");
        return RunAsync(async token =>
        {
            StatusTitle = "Setting up your server…";
            var owner = await host.SetUpOwnerAsync(ServerName, OwnerName, password, deviceName, token);
            setupPassword = password;
            await ConnectAsync(owner, token);
            Phase = HostPhase.CreatePin;
        });
    }

    public Task SignInAsync(string password) => RunAsync(async token =>
    {
        var owner = await host.SignInAsync(OwnerName, password, deviceName, token);
        await ConnectAsync(owner, token);
        var picker = await api.ProfilesAsync(connection!, token);
        if (picker.ManagementSetupRequired)
        {
            setupPassword = password;
            Phase = HostPhase.CreatePin;
            return;
        }
        Finish(null);
    }, onFailure: error => Error = error is AureliaApiException { Status: 401 or 400 }
        ? "The owner name or Server Password is not correct."
        : error.Message);

    /// <summary>Sets the owner's viewing PIN and opens the owner's profile with it.</summary>
    public Task CreatePinAsync(string pin, string confirmation, string? password)
    {
        if (!ProfilePin.IsValid(pin)) return Fail("Choose a PIN with four to eight digits.");
        if (pin != confirmation) return Fail("The PINs do not match.");
        var serverPassword = setupPassword ?? password;
        if (string.IsNullOrEmpty(serverPassword)) return Fail("Enter the Server Password.");
        return RunAsync(async token =>
        {
            await api.InitializeProfilesAsync(connection!, serverPassword, pin, token);
            var picker = await api.ProfilesAsync(connection!, token);
            var owner = picker.Profiles.FirstOrDefault(profile => profile.Role == UserRole.Owner) ?? picker.Profiles[0];
            session = await api.UnlockProfileAsync(connection!, owner.Id, pin, token);
            manager = management(connection!, session);
            await manager.UnlockAsync(serverPassword, token);
            setupPassword = null;
            Phase = HostPhase.Storage;
        });
    }

    /// <summary>The owner forgot the viewing PIN: the Server Password sets a new one on this computer.</summary>
    public void BeginPinReset()
    {
        Error = null;
        Phase = HostPhase.ResetPin;
    }

    public Task ResetPinAsync(string password, string pin, string confirmation)
    {
        if (!ProfilePin.IsValid(pin)) return Fail("Choose a PIN with four to eight digits.");
        if (pin != confirmation) return Fail("The PINs do not match.");
        return RunAsync(async token =>
        {
            await host.ResetOwnerPinAsync(password, pin, token);
            Finish(null);
        }, onFailure: error => Error = error is AureliaApiException { Status: 401 or 403 }
            ? "The Server Password is not correct."
            : error.Message);
    }

    public void CancelPinReset()
    {
        Error = null;
        if (connection is not null) Finish(null);
    }

    public void AddLocations(IEnumerable<string> paths)
    {
        foreach (var path in paths)
            if (!Locations.Any(location => string.Equals(location.Path, path, StringComparison.OrdinalIgnoreCase))) Locations.Add(new StorageDraft(path));
        Changed(nameof(HasLocations));
    }

    public void RemoveLocation(StorageDraft location)
    {
        Locations.Remove(location);
        Changed(nameof(HasLocations));
    }

    public static void SetKind(StorageDraft location, LibraryKind kind)
    {
        location.Kind = kind;
        location.Changed();
    }

    /// <summary>Registers each chosen folder as a storage location and scans it; files are only read.</summary>
    public Task ImportAsync() => RunAsync(async token =>
    {
        if (manager is null) return;
        var libraries = new List<Guid>();
        foreach (var location in Locations.ToArray())
        {
            var library = await manager.AddLibraryAsync(location.Name, location.Path, location.Kind, token);
            libraries.Add(library.Id);
            Locations.Remove(location);
        }
        Changed(nameof(HasLocations));
        foreach (var library in libraries) await manager.ScanAsync(library, token);
        ScanProgress = "Looking for movies and TV shows…";
        Phase = HostPhase.Scanning;
        WatchScans(manager);
    });

    public void SkipStorage() => Finish(session);

    /// <summary>Leaves the scan running in the background and opens the library.</summary>
    public void ContinueToLibrary()
    {
        CancelScanWatch();
        Finish(session);
    }

    private void WatchScans(IServerManagement scans)
    {
        CancelScanWatch();
        var source = new CancellationTokenSource();
        scanWatch = source;
        _ = Task.Run(async () =>
        {
            try
            {
                while (!source.IsCancellationRequested)
                {
                    await Task.Delay(1000, source.Token);
                    var active = await scans.ActiveScansAsync(source.Token);
                    var done = active.Count == 0;
                    var processed = active.Sum(scan => scan.FilesProcessed);
                    var found = active.Sum(scan => scan.FilesDiscovered);
                    dispatch(() =>
                    {
                        if (source.IsCancellationRequested) return;
                        if (done)
                        {
                            ContinueToLibrary();
                            return;
                        }
                        ScanProgress = found == 0 ? "Looking for movies and TV shows…" : $"Reading {processed} of {found} video files…";
                    });
                }
            }
            catch (OperationCanceledException) { }
            catch (AureliaApiException) { dispatch(ContinueToLibrary); }
        });
    }

    private void CancelScanWatch()
    {
        scanWatch?.Cancel();
        scanWatch = null;
    }

    /// <summary>Follows the server: setup when it is new, the profiles once it runs, help when it fails.</summary>
    private void HostChanged()
    {
        if (Phase == HostPhase.Choose || Phase == HostPhase.Inactive && !handedOver) return;
        if (Phase == HostPhase.Inactive)
        {
            if (host.State is not (LocalServerState.Starting or LocalServerState.Restarting or LocalServerState.Failed)) return;
            // The library cannot go on without the server: show its state until it is back.
            Phase = host.State == LocalServerState.Failed ? HostPhase.Failed : HostPhase.Starting;
            ServerInterrupted?.Invoke();
        }
        switch (host.State)
        {
            case LocalServerState.Starting or LocalServerState.Restarting:
                if (Phase is HostPhase.Starting or HostPhase.Failed)
                {
                    Phase = HostPhase.Starting;
                    StatusTitle = host.State == LocalServerState.Restarting ? "Restarting your server…" : "Starting your server…";
                    StatusMessage = host.Message;
                }
                break;
            case LocalServerState.Failed:
                if (IsBusy) return;
                Phase = HostPhase.Failed;
                StatusMessage = host.Message ?? "Aurelia Server could not start.";
                break;
            case LocalServerState.SetupRequired when Phase is HostPhase.Starting or HostPhase.Failed:
                ServerName = host.Settings.ServerName;
                Phase = HostPhase.OwnerSetup;
                break;
            case LocalServerState.Running when Phase is HostPhase.Starting or HostPhase.Failed:
                _ = OpenSavedAsync();
                break;
        }
    }

    /// <summary>A server set up earlier: its saved connection leads to the profiles, otherwise sign in.</summary>
    private Task OpenSavedAsync() => RunAsync(async token =>
    {
        if (store.Load() is not { LocalHost: true } saved || saved.ServerId != host.Info?.ServerId)
        {
            Phase = HostPhase.SignIn;
            return;
        }
        connection = saved;
        var picker = await api.ProfilesAsync(saved, token);
        if (picker.ManagementSetupRequired) Phase = HostPhase.CreatePin;
        else Finish(null);
    }, onFailure: error =>
    {
        if (error is AureliaApiException { IsAuthenticationFailure: true } or AureliaApiException { Code: "identity_mismatch" })
        {
            store.Clear();
            connection = null;
            Phase = HostPhase.SignIn;
            return;
        }
        Phase = HostPhase.Failed;
        StatusMessage = error.Message;
    });

    /// <summary>Reads the server's key over HTTPS on this computer and keeps the owner's device credential with it.</summary>
    private async Task ConnectAsync(AuthenticationResponse owner, CancellationToken token)
    {
        var inspected = await api.InspectAsync(host.SecureAddress, token);
        connection = new StoredConnection(inspected.Info.ServerId, inspected.Info.Name, inspected.Address, inspected.Fingerprint,
            owner.Token, owner.SessionId, LocalHost: true);
        store.Save(connection);
    }

    private void Finish(ProfileSessionResponse? opened)
    {
        if (connection is not { } ready) return;
        handedOver = true;
        Phase = HostPhase.Inactive;
        Error = null;
        Ready?.Invoke(ready, opened);
    }

    private Task Fail(string message)
    {
        Error = message;
        return Task.CompletedTask;
    }

    private async Task RunAsync(Func<CancellationToken, Task> operation, Action<Exception>? onFailure = null)
    {
        if (IsBusy) return;
        IsBusy = true;
        Error = null;
        try
        {
            await operation(CancellationToken.None);
        }
        catch (Exception failure) when (failure is AureliaApiException or IOException or UnauthorizedAccessException
            or System.Security.Cryptography.CryptographicException)
        {
            var error = failure as AureliaApiException
                ?? new AureliaApiException(0, "local_storage", "This computer could not save the connection. " + failure.Message);
            if (onFailure is null) Error = error.Message;
            else onFailure(error);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void Changed(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private void Set<T>(ref T field, T value, [CallerMemberName] string name = "", string[]? also = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Changed(name);
        if (also is null) return;
        foreach (var other in also) Changed(other);
    }
}
