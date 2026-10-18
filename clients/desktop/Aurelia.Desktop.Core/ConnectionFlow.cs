using System.ComponentModel;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

public enum ConnectionPhase { Starting, Connect, Trust, Pairing, Profiles, Pin, Connected }

/// <summary>
/// The way from an address to a chosen profile, like the Apple TV app: read the server's
/// identity, let the person compare it, pair with a code approved on the Mac, then choose a
/// profile and, where needed, enter its PIN. All state the screens show lives here.
/// </summary>
public sealed class ConnectionFlow : INotifyPropertyChanged, IDisposable
{
    private readonly IAureliaServerApi api;
    private readonly ConnectionStore store;
    private readonly IServerDiscovery discovery;
    private readonly string deviceName;
    private readonly Action<Action> dispatch;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    private CancellationTokenSource? work;
    private InspectedServer? inspected;
    private StoredConnection? connection;
    private DeviceAuthorizationStartResponse? pairing;

    public ConnectionFlow(IAureliaServerApi api, ConnectionStore store, IServerDiscovery discovery, string deviceName,
        Action<Action> dispatch, Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        this.api = api;
        this.store = store;
        this.discovery = discovery;
        this.deviceName = deviceName;
        this.dispatch = dispatch;
        this.delay = delay ?? Task.Delay;
        discovery.Changed += servers => dispatch(() => Servers = servers);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ConnectionPhase Phase { get; private set => Set(ref field, value, nameof(Phase), PhaseProperties); } = ConnectionPhase.Starting;
    public bool IsBusy { get; private set => Set(ref field, value); }
    public string? Error { get; private set => Set(ref field, value, nameof(Error), [nameof(HasError)]); }
    public bool HasError => Error is not null;
    public string Address { get; set => Set(ref field, value); } = "";
    public IReadOnlyList<DiscoveredServer> Servers { get; private set => Set(ref field, value, nameof(Servers), [nameof(HasServers)]); } = [];
    public bool HasServers => Servers.Count > 0;
    public string ServerName { get; private set => Set(ref field, value); } = "";
    public string FingerprintDisplay { get; private set => Set(ref field, value); } = "";
    public string PairingCode { get; private set => Set(ref field, value); } = "";
    public IReadOnlyList<WatchingProfile> Profiles { get; private set => Set(ref field, value); } = [];
    public WatchingProfile? SelectedProfile { get; private set => Set(ref field, value, nameof(SelectedProfile), [nameof(PinPrompt)]); }
    public ProfileSessionResponse? Session { get; private set => Set(ref field, value, nameof(Session), [nameof(SignedInName)]); }
    /// <summary>The paired server, once there is one.</summary>
    public StoredConnection? Connection => connection;
    public string SignedInName => Session?.User.Username ?? "";
    public string PinPrompt => SelectedProfile is null ? "" : $"Enter the PIN for {SelectedProfile.Name}";

    public bool ShowsStarting => Phase == ConnectionPhase.Starting;
    public bool ShowsConnect => Phase == ConnectionPhase.Connect;
    public bool ShowsTrust => Phase == ConnectionPhase.Trust;
    public bool ShowsPairing => Phase == ConnectionPhase.Pairing;
    public bool ShowsProfiles => Phase == ConnectionPhase.Profiles;
    public bool ShowsPin => Phase == ConnectionPhase.Pin;
    public bool ShowsLibrary => Phase == ConnectionPhase.Connected;
    public bool ShowsWelcome => Phase != ConnectionPhase.Connected;

    private static readonly string[] PhaseProperties =
        [nameof(ShowsStarting), nameof(ShowsConnect), nameof(ShowsTrust), nameof(ShowsPairing), nameof(ShowsProfiles),
         nameof(ShowsPin), nameof(ShowsLibrary), nameof(ShowsWelcome)];

    /// <summary>Opens the saved server's profiles, or the connect screen when there is none.</summary>
    public async Task StartAsync()
    {
        var saved = store.Load();
        if (saved is null)
        {
            ShowConnect();
            return;
        }
        connection = saved;
        ServerName = saved.ServerName;
        await RunAsync(async token =>
        {
            if (saved.PendingAcknowledgement is { } pending)
            {
                await api.AcknowledgePairingAsync(saved.Address, saved.Fingerprint, pending.Id, pending.Secret, token);
                connection = saved with { PendingAcknowledgement = null };
                store.Save(connection);
            }
            await api.ServerInfoAsync(connection, token);
            await LoadProfilesAsync(token);
        }, onFailure: error =>
        {
            if (error is AureliaApiException { IsAuthenticationFailure: true } or AureliaApiException { Code: "identity_mismatch" })
            {
                Forget();
                ShowConnect(error.Message);
            }
            else
            {
                // The saved server may simply be off; keep it and offer to try again.
                Profiles = [];
                Phase = ConnectionPhase.Profiles;
                Error = $"{saved.ServerName} could not be reached. {error.Message}";
            }
        });
    }

    /// <summary>Reads the identity of the typed or chosen server so the person can compare it.</summary>
    public Task ConnectAsync(DiscoveredServer? server = null)
    {
        if (server is not null) Address = server.Address.Authority;
        if (!ServerAddress.TryNormalize(Address, out var address))
        {
            Error = "Enter a server address such as 192.168.1.20.";
            return Task.CompletedTask;
        }
        return RunAsync(async token =>
        {
            var result = await api.InspectAsync(address, token);
            inspected = result;
            ServerName = result.Info.Name;
            FingerprintDisplay = ServerIdentity.Display(result.Fingerprint);
            Phase = ConnectionPhase.Trust;
        });
    }

    /// <summary>Starts pairing and waits until the code is approved on the Mac.</summary>
    public Task TrustAndPairAsync()
    {
        if (inspected is not { } server) return Task.CompletedTask;
        return RunAsync(async token =>
        {
            var started = await api.StartPairingAsync(server, deviceName, token);
            pairing = started;
            PairingCode = started.Code[..4] + " " + started.Code[4..];
            Phase = ConnectionPhase.Pairing;
            IsBusy = false;
            await WaitForApprovalAsync(server, started, token);
        }, onFailure: error =>
        {
            pairing = null;
            Phase = ConnectionPhase.Trust;
            Error = error.Message;
        });
    }

    public async Task CancelPairingAsync()
    {
        var pending = pairing;
        var server = inspected;
        CancelWork();
        pairing = null;
        ShowConnect();
        if (pending is not null && server is not null)
        {
            try { await api.CancelPairingAsync(server, pending.Id, pending.Secret, CancellationToken.None); }
            catch (AureliaApiException) { }
        }
    }

    public void Back()
    {
        CancelWork();
        Error = null;
        switch (Phase)
        {
            case ConnectionPhase.Trust:
                inspected = null;
                ShowConnect();
                break;
            case ConnectionPhase.Pin:
                SelectedProfile = null;
                Phase = ConnectionPhase.Profiles;
                break;
        }
    }

    public Task ChooseProfileAsync(WatchingProfile profile)
    {
        Error = null;
        if (profile.NeedsPinSetup)
        {
            Error = $"{profile.Name} needs a PIN first. Set it up in Aurelia on your Mac.";
            return Task.CompletedTask;
        }
        SelectedProfile = profile;
        if (profile.PinProtectionEnabled)
        {
            Phase = ConnectionPhase.Pin;
            return Task.CompletedTask;
        }
        return UnlockAsync(profile, pin: null);
    }

    public Task SubmitPinAsync(string pin)
    {
        if (SelectedProfile is not { } profile) return Task.CompletedTask;
        if (!ProfilePin.IsValid(pin))
        {
            Error = "Enter a PIN with four to eight digits.";
            return Task.CompletedTask;
        }
        return UnlockAsync(profile, pin);
    }

    public Task RefreshProfilesAsync() => connection is null ? Task.CompletedTask : RunAsync(LoadProfilesAsync);

    public async Task SwitchProfileAsync()
    {
        var current = Session;
        Session = null;
        SelectedProfile = null;
        if (current is not null && connection is not null)
        {
            try { await api.EndProfileAsync(connection, current, CancellationToken.None); }
            catch (AureliaApiException) { }
        }
        await RefreshProfilesAsync();
    }

    /// <summary>Removes this computer from the server and forgets it here.</summary>
    public async Task DisconnectAsync()
    {
        CancelWork();
        var current = connection;
        Forget();
        ShowConnect();
        if (current is not null)
        {
            try { await api.DisconnectDeviceAsync(current, CancellationToken.None); }
            catch (AureliaApiException) { }
        }
    }

    public void Dispose()
    {
        CancelWork();
        discovery.Dispose();
    }

    private Task UnlockAsync(WatchingProfile profile, string? pin)
    {
        if (connection is not { } current) return Task.CompletedTask;
        return RunAsync(async token =>
        {
            Session = await api.UnlockProfileAsync(current, profile.Id, pin, token);
            Phase = ConnectionPhase.Connected;
        }, onFailure: error =>
        {
            if (error is AureliaApiException { IsAuthenticationFailure: true, Code: not "invalid_profile_pin" })
            {
                Forget();
                ShowConnect(error.Message);
                return;
            }
            Error = error is AureliaApiException { Code: "invalid_profile_pin" }
                ? "That PIN is not correct."
                : error.Message;
        });
    }

    private async Task WaitForApprovalAsync(InspectedServer server, DeviceAuthorizationStartResponse started, CancellationToken token)
    {
        var wait = TimeSpan.FromSeconds(Math.Max(1, started.PollIntervalSeconds));
        while (true)
        {
            await delay(wait, token);
            if (started.ExpiresAt <= DateTimeOffset.UtcNow)
                throw new AureliaApiException(410, "pairing_expired", "The code expired. Start again for a new one.");
            DeviceAuthorizationStatusResponse status;
            try
            {
                status = await api.PairingStatusAsync(server, started.Id, started.Secret, token);
            }
            catch (AureliaApiException error) when (error.IsTransient)
            {
                wait = error.RetryAfter is { } retry && retry > wait ? retry : wait;
                continue;
            }
            wait = TimeSpan.FromSeconds(Math.Max(1, status.PollIntervalSeconds));
            switch (status.State)
            {
                case DeviceAuthorizationState.Pending:
                    continue;
                case DeviceAuthorizationState.Approved when status.Authentication is { } credential:
                    // Save before acknowledging: a lost acknowledgement must not lose the credential.
                    var paired = new StoredConnection(server.Info.ServerId, server.Info.Name, server.Address, server.Fingerprint,
                        credential.Token, credential.SessionId, new PendingPairing(started.Id, started.Secret));
                    store.Save(paired);
                    connection = paired;
                    await api.AcknowledgePairingAsync(server.Address, server.Fingerprint, started.Id, started.Secret, token);
                    connection = paired with { PendingAcknowledgement = null };
                    store.Save(connection);
                    pairing = null;
                    discovery.Halt();
                    await LoadProfilesAsync(token);
                    return;
                case DeviceAuthorizationState.Denied:
                    throw new AureliaApiException(403, "pairing_denied", "This computer was not approved on your Mac.");
                default:
                    throw new AureliaApiException(409, "pairing_expired", "The code is no longer valid. Start again for a new one.");
            }
        }
    }

    private async Task LoadProfilesAsync(CancellationToken token)
    {
        if (connection is not { } current) return;
        var picker = await api.ProfilesAsync(current, token);
        if (picker.ManagementSetupRequired)
            throw new AureliaApiException(409, "management_setup_required", "Finish setting up profiles in Aurelia on your Mac first.");
        Profiles = picker.Profiles;
        SelectedProfile = null;
        Error = null;
        Phase = ConnectionPhase.Profiles;
    }

    private void ShowConnect(string? error = null)
    {
        Phase = ConnectionPhase.Connect;
        Error = error;
        discovery.Start();
    }

    private void Forget()
    {
        store.Clear();
        connection = null;
        Session = null;
        SelectedProfile = null;
        Profiles = [];
    }

    private async Task RunAsync(Func<CancellationToken, Task> operation, Action<Exception>? onFailure = null)
    {
        CancelWork();
        var source = new CancellationTokenSource();
        work = source;
        IsBusy = true;
        Error = null;
        try
        {
            await operation(source.Token);
        }
        catch (OperationCanceledException) when (source.IsCancellationRequested)
        {
        }
        catch (Exception failure) when (failure is AureliaApiException or IOException or UnauthorizedAccessException
            or System.Security.Cryptography.CryptographicException)
        {
            // Storage problems become a readable message instead of ending the app.
            var error = failure as AureliaApiException
                ?? new AureliaApiException(0, "local_storage", "This computer could not save the connection. " + failure.Message);
            if (work == source)
            {
                if (onFailure is null) Error = error.Message;
                else onFailure(error);
            }
        }
        finally
        {
            if (work == source)
            {
                IsBusy = false;
                work = null;
            }
            source.Dispose();
        }
    }

    private void CancelWork()
    {
        var current = work;
        work = null;
        current?.Cancel();
        IsBusy = false;
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string name = "", string[]? also = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        if (also is null) return;
        foreach (var other in also) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(other));
    }
}
