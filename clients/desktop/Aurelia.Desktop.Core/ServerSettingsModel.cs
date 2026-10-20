using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

public enum SettingsSection { General, Storage, Devices, Profiles }

/// <summary>A storage location as the settings list shows it, with its scan when one runs.</summary>
public sealed record StorageRow(LibrarySummary Library, LibraryScanSummary? Scan)
{
    public string Name => Library.Name;
    public string Path => Library.Path;
    public string KindName => Library.Kind switch { LibraryKind.Movies => "Movies", LibraryKind.TvShows => "TV Shows", _ => "Movies and TV Shows" };
    public string Status => Library.ImportPreviewRequired ? "Waiting for your review in Import Preview before it is added."
        : Scan is { } scan
        ? scan.FilesDiscovered == 0 ? "Scanning…" : $"Scanning… {scan.FilesProcessed} of {scan.FilesDiscovered} files"
        : Library.Availability switch
        {
            LibraryAvailability.Unavailable => "Not connected. Reconnect the drive and scan again.",
            LibraryAvailability.Error => Library.LastError ?? "Aurelia cannot read this location.",
            _ => Library.LastScanCompletedAt is { } done ? $"Scanned {done.ToLocalTime():g}" : "Not scanned yet",
        };
    public bool IsScanning => Scan is not null;
    public bool WaitsForReview => Library.ImportPreviewRequired;
}

/// <summary>A paired device as the settings list shows it.</summary>
public sealed record DeviceRow(DeviceSessionSummary Session)
{
    public string Name => Session.IsCurrent ? $"{Session.DeviceName} (this computer)" : Session.DeviceName;
    public string LastSeen => $"Last used {Session.LastSeenAt.ToLocalTime():g}";
    public bool CanRemove => !Session.IsCurrent;
}

/// <summary>
/// Server Settings for the owner of this computer's server: General (name, network access and
/// restart), Storage (locations and scans) and Devices (approve a code, remove a device). Management
/// opens with the Server Password for ten minutes, as on the Mac; files are never changed.
/// </summary>
public sealed class ServerSettingsModel : INotifyPropertyChanged, IDisposable
{
    private readonly ILocalServerHost host;
    private readonly IAureliaServerApi api;
    private readonly StoredConnection connection;
    private readonly Func<ProfileSessionResponse, IServerManagement> managementFor;
    private readonly Action<Action> dispatch;
    private readonly Func<bool> publicNetwork;
    private readonly CancellationTokenSource closing = new();
    private ProfileSessionResponse session;
    private IServerManagement management;
    private ServerSettingsDocument? settings;
    private ServerOperationStatus? trial;
    private DeviceAuthorizationPreview? pending;
    private volatile bool restartSeen;
    private volatile bool trialStarting;

    public ServerSettingsModel(ILocalServerHost host, IAureliaServerApi api, StoredConnection connection, ProfileSessionResponse session,
        Func<ProfileSessionResponse, IServerManagement> managementFor, Action<Action> dispatch, HostingController? hosting = null,
        Func<bool>? publicNetwork = null)
    {
        this.host = host;
        Hosting = hosting;
        this.publicNetwork = publicNetwork ?? (() => false);
        this.api = api;
        this.connection = connection;
        this.session = session;
        this.managementFor = managementFor;
        this.dispatch = dispatch;
        management = managementFor(session);
        Profiles = new ProfilesModel(() => management);
        Profiles.Locked += () => IsLocked = true;
        Maintenance = new LibraryMaintenanceModel(() => management);
        Maintenance.LibraryChanged += () => _ = RefreshStorageAsync();
        host.Changed += () =>
        {
            if (host.State != LocalServerState.Running) restartSeen = true;
        };
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>A confirmed network change replaced the profile session; the library continues with the new one.</summary>
    public event Action<ProfileSessionResponse>? SessionReplaced;

    public SettingsSection Section
    {
        get;
        set
        {
            if (field != value) Notice = null;
            Set(ref field, value, nameof(Section), [nameof(ShowsGeneral), nameof(ShowsStorage), nameof(ShowsDevices), nameof(ShowsProfiles)]);
            if (value == SettingsSection.Profiles && IsUnlocked && !Profiles.IsEditing) _ = Profiles.LoadAsync();
        }
    }
    public bool ShowsGeneral => Section == SettingsSection.General;
    public bool ShowsStorage => Section == SettingsSection.Storage;
    public bool ShowsDevices => Section == SettingsSection.Devices;
    public bool ShowsProfiles => Section == SettingsSection.Profiles;
    /// <summary>Management for the windows Server Settings opens, such as Import Preview.</summary>
    public IAdministrationClient Administration => management;

    /// <summary>Excluded sources and resetting storage locations.</summary>
    public LibraryMaintenanceModel Maintenance { get; }
    /// <summary>Review before adding: the location is analyzed and shown in Import Preview first.</summary>
    public bool ReviewNewStorage { get; set => Set(ref field, value); }
    /// <summary>A new location that contains existing ones takes them over, with their titles.</summary>
    public bool CombineNewStorage { get; set => Set(ref field, value); }

    /// <summary>A location waits in Import Preview; the window shows it.</summary>
    public event Action<LibrarySummary>? ImportPreviewRequested;

    public void ReviewImport(StorageRow row) => ImportPreviewRequested?.Invoke(row.Library);

    /// <summary>Who may watch: profiles, roles, PINs and title access.</summary>
    public ProfilesModel Profiles { get; }
    public bool IsLocked { get; private set => Set(ref field, value, nameof(IsLocked), [nameof(IsUnlocked)]); } = true;
    public bool IsUnlocked => !IsLocked;
    public bool IsBusy { get; private set => Set(ref field, value); }
    public string? Error { get; private set => Set(ref field, value, nameof(Error), [nameof(HasError)]); }
    public bool HasError => Error is not null;
    public string? Notice { get; private set => Set(ref field, value, nameof(Notice), [nameof(HasNotice)]); }
    public bool HasNotice => Notice is not null;

    public string ServerName { get; set => Set(ref field, value, nameof(ServerName), [nameof(HasNetworkChange)]); } = "";
    public bool LanAccessEnabled { get; set => Set(ref field, value, nameof(LanAccessEnabled), [nameof(HasNetworkChange), nameof(TurnsNetworkOff)]); }
    public bool ConfirmDisconnect { get; set => Set(ref field, value); }
    public bool HasNetworkChange => settings is not null && trial is null
        && (ServerName.Trim() != settings.ServerName || LanAccessEnabled != settings.LanAccessEnabled);
    public bool TurnsNetworkOff => settings?.LanAccessEnabled == true && !LanAccessEnabled;
    public bool IsTrialPending => trial is not null;
    /// <summary>A network trial restarts the server; these settings must stay open to confirm it afterwards.</summary>
    public bool AwaitsRestart => trial is not null || trialStarting;
    public string TrialDeadline => trial?.ConfirmBefore is { } deadline ? deadline.ToLocalTime().ToString("T", CultureInfo.CurrentCulture) : "";
    public bool NeedsPinToConfirm => session.User.PinProtectionEnabled;
    public string StateText { get; private set => Set(ref field, value); } = "";
    public string Version { get; private set => Set(ref field, value); } = "";
    public string Attention { get; private set => Set(ref field, value, nameof(Attention), [nameof(HasAttention)]); } = "";
    public bool HasAttention => Attention.Length > 0;
    public string Addresses { get; private set => Set(ref field, value); } = "";
    public string Fingerprint => ServerIdentity.Display(connection.Fingerprint);
    public bool NetworkActive => settings?.LanAccessEnabled == true;
    /// <summary>Windows marks the current network Public, so devices cannot reach the server until it is Private.</summary>
    public bool OnPublicNetwork { get; private set => Set(ref field, value); }

    /// <summary>When the server runs: keep running when the window closes, start at sign-in, keep awake.</summary>
    public HostingController? Hosting { get; }
    public bool HasHosting => Hosting is not null;
    public static string KeepRunningText => OperatingSystem.IsWindows()
        ? "Keep the server running in the notification area when Aurelia is closed"
        : "Keep the server running in the menu bar when Aurelia is closed";
    public static string SleepCaption => OperatingSystem.IsWindows()
        ? "Other devices can't reach the server while this PC is asleep or turned off."
        : "Other devices can't reach the server while this computer is asleep or turned off.";

    public ObservableCollection<StorageRow> Storage { get; } = [];
    public bool HasStorage => Storage.Count > 0;
    public ObservableCollection<DeviceRow> Devices { get; } = [];
    public string DeviceCode { get; set => Set(ref field, value); } = "";
    public string? PendingDevice { get; private set => Set(ref field, value, nameof(PendingDevice), [nameof(HasPendingDevice)]); }
    public bool HasPendingDevice => PendingDevice is not null;

    /// <summary>Opens unlocked when management is still unlocked from setup, otherwise asks for the password.</summary>
    public Task OpenAsync() => RunAsync(async token =>
    {
        try
        {
            await LoadAsync(token);
            IsLocked = false;
        }
        catch (AureliaApiException error) when (error.Code == "management_locked")
        {
            IsLocked = true;
        }
    });

    public Task UnlockAsync(string password) => RunAsync(async token =>
    {
        await management.UnlockAsync(password, token);
        IsLocked = false;
        await LoadAsync(token);
        if (ShowsProfiles) _ = Profiles.LoadAsync();
    }, wrongPassword: true);

    public Task RefreshAsync() => RunAsync(LoadAsync);

    public Task RestartAsync() => RunAsync(async _ =>
    {
        Notice = "Restarting the server. Profiles open again once it is back.";
        await host.RestartAsync();
    });

    /// <summary>Tries the new name and network setting; they must be confirmed within a minute or return.</summary>
    public Task ApplyNetworkAsync() => RunAsync(async token =>
    {
        if (settings is null) return;
        if (TurnsNetworkOff && !ConfirmDisconnect)
        {
            Error = "Confirm that other devices will lose access first.";
            return;
        }
        var changed = (System.Text.Json.Nodes.JsonObject)settings.Stored.DeepClone();
        changed["serverName"] = ServerName.Trim();
        changed["lanAccessEnabled"] = LanAccessEnabled;
        restartSeen = false;
        trialStarting = true;
        try { trial = await management.TryNetworkAsync(changed, TurnsNetworkOff, token); }
        finally { trialStarting = false; }
        Notice = null;
        Changed(nameof(IsTrialPending), nameof(TrialDeadline), nameof(HasNetworkChange));
    });

    /// <summary>On the restarted server: open the profile again, unlock management and keep the change.</summary>
    public Task ConfirmNetworkAsync(string? pin, string password) => RunAsync(async token =>
    {
        if (trial is not { } pendingTrial) return;
        await WaitForServerAsync(token);
        var replacement = await api.UnlockProfileAsync(connection, session.User.Id, string.IsNullOrEmpty(pin) ? null : pin, token);
        var manager = managementFor(replacement);
        await manager.UnlockAsync(password, token);
        await manager.ConfirmNetworkAsync(pendingTrial.Id, token);
        session = replacement;
        management = manager;
        trial = null;
        Changed(nameof(IsTrialPending), nameof(TrialDeadline));
        Notice = "The new settings are kept.";
        SessionReplaced?.Invoke(replacement);
        await LoadAsync(token);
    }, wrongPassword: true);

    public Task AddStorageAsync(string path, LibraryKind kind) => RunAsync(async token =>
    {
        var review = ReviewNewStorage;
        var library = await management.SendAsync<LibrarySummary>(HttpMethod.Post, "/api/v1/libraries",
            new CreateLibraryRequest(null, path, kind, CombineNewStorage, review), token);
        if (!review) await management.ScanAsync(library.Id, token);
        await LoadStorageAsync(token);
        if (review) ImportPreviewRequested?.Invoke(library);
    });

    public Task RefreshStorageAsync() => RunAsync(LoadStorageAsync);

    public Task ScanAsync(StorageRow row) => RunAsync(async token =>
    {
        await management.ScanAsync(row.Library.Id, token);
        await LoadStorageAsync(token);
    });

    /// <summary>Removes the location and its titles from Aurelia; the files stay where they are.</summary>
    public Task RemoveStorageAsync(StorageRow row) => RunAsync(async token =>
    {
        await management.RemoveLibraryAsync(row.Library.Id, token);
        Notice = $"{row.Name} was removed from Aurelia. Its files were not touched.";
        await LoadStorageAsync(token);
    });

    public Task LookUpDeviceAsync() => RunAsync(async token =>
    {
        var digits = new string([.. DeviceCode.Where(char.IsAsciiDigit)]);
        if (digits.Length != 8)
        {
            Error = "Enter the eight-digit code shown on the device.";
            return;
        }
        pending = await management.LookUpDeviceAsync(digits, token);
        PendingDevice = pending.DeviceName;
    });

    public Task AnswerDeviceAsync(bool approve) => RunAsync(async token =>
    {
        if (pending is not { } request) return;
        await management.AnswerDeviceAsync(request.Id, approve, token);
        Notice = approve ? $"{request.DeviceName} can now connect." : $"{request.DeviceName} was not approved.";
        pending = null;
        PendingDevice = null;
        DeviceCode = "";
        await LoadDevicesAsync(token);
    });

    public Task RemoveDeviceAsync(DeviceRow row) => RunAsync(async token =>
    {
        await management.RemoveDeviceAsync(row.Session.Id, token);
        await LoadDevicesAsync(token);
    });

    /// <summary>Keeps the scan states current while the window is open.</summary>
    public void WatchScans() => _ = Task.Run(async () =>
    {
        try
        {
            while (!closing.IsCancellationRequested)
            {
                await Task.Delay(2000, closing.Token);
                if (IsLocked || IsBusy || !Storage.Any(row => row.IsScanning)) continue;
                var libraries = await management.LibrariesAsync(closing.Token);
                var scans = await management.ActiveScansAsync(closing.Token);
                dispatch(() => ShowStorage(libraries, scans));
            }
        }
        catch (OperationCanceledException) { }
        catch (AureliaApiException) { }
    });

    public void Dispose()
    {
        closing.Cancel();
        closing.Dispose();
    }

    private async Task LoadAsync(CancellationToken token)
    {
        var status = await management.StatusAsync(token);
        settings = await management.SettingsAsync(token);
        ServerName = settings.ServerName;
        LanAccessEnabled = settings.LanAccessEnabled;
        ConfirmDisconnect = false;
        Version = status.Version;
        StateText = status.State == "running" ? "Running" : "Starting";
        Attention = string.Join(" ", status.Readiness.Components.Where(component => component.State == "degraded").Select(component => component.Id switch
        {
            "media" => "Some storage locations are not connected.",
            "storage" => "The server's disk is almost full.",
            "metadata" => "Movie and show details are waiting for their provider.",
            _ => $"The {component.Id} needs attention.",
        }));
        Addresses = settings.LanAccessEnabled
            ? string.Join("\n", status.NetworkAddresses.Select(address => address.Contains(':', StringComparison.Ordinal)
                ? $"https://[{address}]:{settings.LanHttpsPort}" : $"https://{address}:{settings.LanHttpsPort}"))
            : "Only this computer";
        OnPublicNetwork = settings.LanAccessEnabled && publicNetwork();
        Changed(nameof(HasNetworkChange), nameof(TurnsNetworkOff), nameof(NetworkActive));
        await LoadStorageAsync(token);
        await LoadDevicesAsync(token);
    }

    private async Task LoadStorageAsync(CancellationToken token) =>
        ShowStorage(await management.LibrariesAsync(token), await management.ActiveScansAsync(token));

    private void ShowStorage(IReadOnlyList<LibrarySummary> libraries, IReadOnlyList<LibraryScanSummary> scans)
    {
        Maintenance.Show(libraries);
        Storage.Clear();
        foreach (var library in libraries.OrderBy(value => value.Name, StringComparer.CurrentCultureIgnoreCase))
            Storage.Add(new StorageRow(library, scans.FirstOrDefault(scan => scan.LibraryId == library.Id)));
        Changed(nameof(HasStorage));
    }

    private async Task LoadDevicesAsync(CancellationToken token)
    {
        var devices = await management.DevicesAsync(token);
        Devices.Clear();
        foreach (var device in devices.Where(device => device.RevokedAt is null).OrderByDescending(device => device.IsCurrent)
                     .ThenByDescending(device => device.LastSeenAt))
            Devices.Add(new DeviceRow(device));
    }

    /// <summary>Waits for the restart the trial causes, so the confirmation reaches the restarted server.</summary>
    private async Task WaitForServerAsync(CancellationToken token)
    {
        var started = DateTimeOffset.UtcNow;
        var deadline = started.AddSeconds(45);
        while (host.State != LocalServerState.Running || !restartSeen && DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(10))
        {
            if (DateTimeOffset.UtcNow > deadline || host.State == LocalServerState.Failed)
                throw new AureliaApiException(503, "server_unavailable", host.Message ?? "The server did not come back in time.");
            await Task.Delay(200, token);
        }
    }

    private async Task RunAsync(Func<CancellationToken, Task> operation, bool wrongPassword = false)
    {
        if (IsBusy) return;
        IsBusy = true;
        Error = null;
        try
        {
            await operation(closing.Token);
        }
        catch (OperationCanceledException) when (closing.IsCancellationRequested) { }
        catch (AureliaApiException error)
        {
            if (error.Code == "management_locked") IsLocked = true;
            Error = error.Code switch
            {
                "management_locked" => "Enter the Server Password again to continue.",
                "invalid_profile_pin" => "That PIN is not correct.",
                _ when wrongPassword && error.Status is 401 or 403 => "The Server Password is not correct.",
                _ => error.Message,
            };
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void Changed(params string[] names)
    {
        foreach (var name in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string name = "", string[]? also = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Changed(name);
        if (also is not null) Changed(also);
    }
}
