using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Management;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Flow;

/// <summary>
/// The app's connection to its server, as the Mac app's AppModel keeps it: the saved pairing,
/// waking and reaching the server at start, pairing a new server, the profile picker, the open
/// watching profile with its timeout, switching profiles and disconnecting. It moves
/// <see cref="AppFlow"/> to the matching screen. Call it from the interface thread.
/// </summary>
public sealed class AppSession : ObservableObject
{
    /// <summary>A profile session ends after twelve hours at the latest, as on the Mac.</summary>
    public static readonly TimeSpan MaximumProfileSession = TimeSpan.FromHours(12);

    private readonly AppFlow flow;
    private readonly ICredentialStore credentials;
    private readonly ServerWakeUp wakeUp;
    private readonly TimeProvider time;
    private CancellationTokenSource? reaching;
    private CancellationTokenSource? profileTimer;
    private CancellationTokenSource? syncing;
    private CancellationTokenSource? networkTimer;
    private LibraryStore? library;
    private IReadOnlyList<string> capabilities = [];
    private bool isResting;
    private StoredServer? server;
    private ProfileSession? profile;
    private ConnectionStatus status;
    private string? message;

    public AppSession(AppFlow flow, AureliaApi api, ICredentialStore credentials, ServerWakeUp wakeUp, string deviceName, TimeProvider? time = null,
        GeneralPreferences? preferences = null, ArtworkCache? artwork = null)
    {
        Preferences = preferences ?? new GeneralPreferences(new MemorySettingsStore());
        Artwork = artwork ?? new ArtworkCache(null);
        this.flow = flow;
        Api = api;
        this.credentials = credentials;
        this.wakeUp = wakeUp;
        DeviceName = deviceName;
        this.time = time ?? TimeProvider.System;
    }

    public AureliaApi Api { get; }

    public string DeviceName { get; }

    public GeneralPreferences Preferences { get; }

    public ArtworkCache Artwork { get; }

    /// <summary>Expected restart during a network trial: retain the settings editor until confirmation or rollback.</summary>
    public bool NetworkConfirmationPending { get; private set; }

    public void BeginNetworkConfirmation(DateTimeOffset deadline)
    {
        networkTimer?.Cancel();
        var timer = new CancellationTokenSource();
        networkTimer = timer;
        NetworkConfirmationPending = true;
        syncing?.Cancel();
        syncing = null;
        profileTimer?.Cancel();
        _ = ExpireNetworkTrialAsync(deadline, timer.Token);
    }

    public async Task AcceptConfirmedNetworkAsync(ConfirmedNetwork confirmed)
    {
        if (!NetworkConfirmationPending || Server is not { } previous || Profile is not { } owner
            || previous.ServerId != confirmed.Server.ServerId || previous.SessionId != confirmed.Server.SessionId
            || !ServerIdentity.Matches(previous.Fingerprint, confirmed.Server.Fingerprint) || owner.User.Id != confirmed.Profile.User.Id)
            throw AureliaApiException.IdentityMismatch();
        networkTimer?.Cancel();
        NetworkConfirmationPending = false;
        CloseLibrary();
        await SaveAsync(confirmed.Server);
        OpenProfile(confirmed.Profile);
    }

    private async Task ExpireNetworkTrialAsync(DateTimeOffset deadline, CancellationToken cancellation)
    {
        try
        {
            // The host checks its journal once a second; leave it time to restore and restart.
            await Task.Delay(TimeSpan.FromMilliseconds(Math.Max(0, (deadline - time.GetUtcNow()).TotalMilliseconds)) + TimeSpan.FromSeconds(2), time, cancellation);
            NetworkConfirmationPending = false;
            ServerInterrupted();
            Message = "The network trial ended. The previous settings return automatically; open your profile again.";
            await ReachServerAsync();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
    }

    /// <summary>The features the server reported (server/info capabilities).</summary>
    public IReadOnlyList<string> Capabilities
    {
        get => capabilities;
        private set => SetProperty(ref capabilities, value);
    }

    /// <summary>The open profile's library, kept current by the sync loop; null without an open profile.</summary>
    public LibraryStore? Library
    {
        get => library;
        private set => SetProperty(ref library, value);
    }

    public StoredServer? Server
    {
        get => server;
        private set => SetProperty(ref server, value);
    }

    public ProfileSession? Profile
    {
        get => profile;
        private set => SetProperty(ref profile, value);
    }

    public ConnectionStatus Status
    {
        get => status;
        private set => SetProperty(ref status, value);
    }

    /// <summary>Aurelia let go of the server because nobody used it (see <see cref="RestAsync"/>).</summary>
    public bool IsResting
    {
        get => isResting;
        private set => SetProperty(ref isResting, value);
    }

    /// <summary>True when the saved server runs on another computer, the only case in which Aurelia rests.</summary>
    public bool ConnectedElsewhere => Server is { } saved && !saved.LocallyManaged && !ServerAddress.IsLoopback(saved.Address);

    /// <summary>A problem to show on the current screen, or null.</summary>
    public string? Message
    {
        get => message;
        set => SetProperty(ref message, value);
    }

    /// <summary>
    /// Set after this computer's new server was set up: once the owner's profile is open, Aurelia asks
    /// for the first storage locations, as the Mac app's InitialLibrarySetupView.
    /// </summary>
    public bool NeedsInitialLibrarySetup { get; set; }

    /// <summary>This computer's own server no longer accepts the saved owner credential.</summary>
    public event Action? LocalSignInNeeded;

    /// <summary>
    /// Reads the saved pairing and reaches its server; without one, shows the welcome choice. When this
    /// computer hosts the server, <paramref name="startHosting"/> starts it and the host setup takes over.
    /// </summary>
    public async Task StartAsync(Func<Task>? startHosting = null)
    {
        if (flow.Mode == OperatingMode.Host && startHosting is not null)
        {
            try
            {
                if (await credentials.LoadAsync(CancellationToken.None) is { LocallyManaged: true } local) Server = local;
            }
            catch (CredentialStoreUnavailableException error)
            {
                Message = error.Message;
            }
            await startHosting();
            return;
        }
        StoredServer? saved;
        try
        {
            saved = await credentials.LoadAsync(CancellationToken.None);
        }
        catch (CredentialStoreUnavailableException error)
        {
            Message = error.Message;
            saved = null;
        }
        if (saved is null)
        {
            flow.FinishStarting();
            return;
        }
        Server = saved;
        if (flow.Mode is null) flow.ChooseMode(OperatingMode.Client);
        await ReachServerAsync();
    }

    /// <summary>Wakes and reaches the saved server, then opens the profile picker.</summary>
    public async Task ReachServerAsync()
    {
        if (IsOffline || Server is not { } saved) return;
        reaching?.Cancel();
        var attempt = new CancellationTokenSource();
        reaching = attempt;
        Message = null;
        flow.Show(AppScreen.Starting);
        try
        {
            var reached = await wakeUp.ReachAsync(saved, value => Status = value, attempt.Token);
            if (reached is null)
            {
                ShowUnreachable();
                return;
            }
            Capabilities = reached.Info.Capabilities ?? [];
            if (reached.Server != saved) await SaveAsync(reached.Server);
            Status = ConnectionStatus.Loading;
            flow.Show(AppScreen.ProfilePicker);
        }
        catch (OperationCanceledException) when (attempt.IsCancellationRequested)
        {
            ShowUnreachable();
        }
        catch (AureliaApiException error)
        {
            Message = error.Message;
            ShowUnreachable();
        }
        finally
        {
            if (reaching == attempt) reaching = null;
            Status = ConnectionStatus.Idle;
        }
    }

    /// <summary>"Stop Waiting": gives up on waking the server for now.</summary>
    public void StopWaiting() => reaching?.Cancel();

    /// <summary>The offline mode shows: no wake packets, reconnects or "not answering" until it is left.</summary>
    public bool IsOffline { get; private set; }

    /// <summary>A profile opened with the server, with the PIN it was opened with, so it can be remembered for the offline mode.</summary>
    public event Action<WatchingProfile, string?>? ProfileUnlocked;

    /// <summary>This computer left a server; its offline cards go too.</summary>
    public event Action<Guid>? ServerForgotten;

    internal void NotifyUnlocked(WatchingProfile profile, string? pin) => ProfileUnlocked?.Invoke(profile, pin);

    /// <summary>Stops looking for the server and shows the downloads on this computer.</summary>
    public void EnterOffline()
    {
        IsOffline = true;
        reaching?.Cancel();
        CloseLibrary();
        flow.Show(AppScreen.Offline);
    }

    /// <summary>Leaves the offline mode and looks for the server again.</summary>
    public async Task LeaveOfflineAsync()
    {
        if (!IsOffline) return;
        IsOffline = false;
        await ReachServerAsync();
    }

    private void ShowUnreachable()
    {
        if (!IsOffline) flow.Show(AppScreen.ServerUnreachable);
    }

    /// <summary>Saves a new pairing in the keyring and opens its profile picker.</summary>
    public async Task CompletePairingAsync(StoredServer paired, IReadOnlyList<string>? serverCapabilities = null)
    {
        if (serverCapabilities is not null) Capabilities = serverCapabilities;
        await SaveAsync(paired);
        Message = null;
        flow.Show(AppScreen.ProfilePicker);
    }

    /// <summary>A profile was opened in the picker: show the library until the session ends.</summary>
    public void OpenProfile(ProfileSession session)
    {
        Profile = session;
        if (Server is { } saved)
        {
            var store = new LibraryStore(new LibraryClient(Api, saved, session, Capabilities), Artwork, Preferences, HandleSessionFailure);
            Library = store;
            syncing?.Cancel();
            var sync = new CancellationTokenSource();
            syncing = sync;
            _ = StartLibraryAsync(store, sync.Token);
        }
        profileTimer?.Cancel();
        var timer = new CancellationTokenSource();
        profileTimer = timer;
        var remaining = session.ExpiresAt - time.GetUtcNow();
        if (remaining <= TimeSpan.Zero || remaining > MaximumProfileSession) remaining = MaximumProfileSession;
        _ = ExpireProfileAsync(remaining, timer.Token);
        flow.Show(NeedsInitialLibrarySetup && session.User.Role == UserRole.Owner ? AppScreen.InitialLibrarySetup : AppScreen.Library);
    }

    /// <summary>The open profile's name or picture changed on the server: show the new one everywhere.</summary>
    public void UpdateProfileUser(UserSummary user)
    {
        if (Profile is { } open && open.User.Id == user.Id) Profile = open with { User = user };
    }

    /// <summary>The first storage locations are added, or skipped for now: show the library.</summary>
    public void CompleteInitialLibrarySetup()
    {
        NeedsInitialLibrarySetup = false;
        if (Profile is not null) flow.Show(AppScreen.Library);
    }

    /// <summary>This computer's server restarted or stopped; its profile sessions ended with it.</summary>
    public void ServerInterrupted()
    {
        if (NetworkConfirmationPending) return;
        CloseLibrary();
        profileTimer?.Cancel();
        profileTimer = null;
        Profile = null;
    }

    /// <summary>Forgets the connection to this computer's own server, before connecting elsewhere.</summary>
    public async Task ForgetLocalServerAsync()
    {
        var saved = Server;
        CancelNetworkConfirmation();
        ServerInterrupted();
        try
        {
            await credentials.DeleteAsync(CancellationToken.None);
        }
        catch (CredentialStoreUnavailableException error)
        {
            Message = error.Message;
        }
        Server = null;
        if (saved is not null) ServerForgotten?.Invoke(saved.ServerId);
    }

    /// <summary>Ends the open profile on the server and returns to "Who's watching?".</summary>
    public async Task SwitchProfileAsync()
    {
        CancelNetworkConfirmation();
        await EndProfileAsync();
        flow.Show(AppScreen.ProfilePicker);
    }

    /// <summary>
    /// The server no longer accepts a credential. A profile problem returns to the picker; a revoked
    /// device must be paired again, but the saved connection stays until the person removes it.
    /// </summary>
    public void HandleSessionFailure(AureliaApiException error)
    {
        if (NetworkConfirmationPending) return;
        if (error.Code is "device_session_revoked" || (error.IsAuthenticationFailure && Profile is null))
        {
            CloseLibrary();
            Profile = null;
            if (Server is { LocallyManaged: true })
            {
                // This computer's own server: sign in again with the Server Password.
                LocalSignInNeeded?.Invoke();
                return;
            }
            Message = "This computer is no longer paired with the server. Pair it again.";
            flow.Show(AppScreen.Connection);
            return;
        }
        if (error.IsAuthenticationFailure || error.Code is "profile_session_expired" or "profile_session_revoked")
        {
            CloseLibrary();
            Profile = null;
            flow.Show(AppScreen.ProfilePicker);
        }
    }

    /// <summary>Forgets the server: removes the pairing here and, when it answers, on the server too.</summary>
    public async Task DisconnectAsync()
    {
        CancelNetworkConfirmation();
        var saved = Server;
        await EndProfileAsync();
        try
        {
            await credentials.DeleteAsync(CancellationToken.None);
        }
        catch (CredentialStoreUnavailableException error)
        {
            Message = error.Message;
        }
        if (saved is not null)
        {
            try
            {
                await Api.DisconnectDeviceAsync(saved, CancellationToken.None);
            }
            catch (AureliaApiException)
            {
                // The pairing is gone here; the server forgets an unused device on its own.
            }
        }
        Server = null;
        if (saved is not null) ServerForgotten?.Invoke(saved.ServerId);
        flow.Show(AppScreen.Connection);
    }

    /// <summary>
    /// Lets go of the server so it can sleep, as the Mac app does: the sync stops and idle connections
    /// close. The profile stays open; using Aurelia again wakes the server and continues.
    /// </summary>
    public void Rest()
    {
        if (IsResting) return;
        syncing?.Cancel();
        syncing = null;
        Api.DropConnections();
        IsResting = true;
    }

    /// <summary>Wakes and reaches the server after a rest, then reloads the library and resumes its sync.</summary>
    public async Task ResumeFromRestAsync()
    {
        if (!IsResting || Server is not { } saved) return;
        IsResting = false;
        Status = ConnectionStatus.Connecting;
        var reached = await wakeUp.ReachAsync(saved, value => Status = value, CancellationToken.None);
        Status = ConnectionStatus.Idle;
        if (reached is null)
        {
            CloseLibrary();
            ShowUnreachable();
            return;
        }
        if (Profile is { } open && open.ExpiresAt > time.GetUtcNow()) OpenProfile(open);
        else await SwitchProfileAsync();
    }

    private async Task StartLibraryAsync(LibraryStore store, CancellationToken cancellation)
    {
        await store.RefreshAsync();
        if (!cancellation.IsCancellationRequested)
            await Task.WhenAll(new LibrarySync(store, Preferences.Store, time).RunAsync(cancellation),
                new RecommendationRefresh(store, time).RunAsync(cancellation));
    }

    private void CloseLibrary()
    {
        syncing?.Cancel();
        syncing = null;
        Library = null;
    }

    private void CancelNetworkConfirmation()
    {
        networkTimer?.Cancel();
        networkTimer = null;
        NetworkConfirmationPending = false;
    }

    private async Task EndProfileAsync()
    {
        CloseLibrary();
        profileTimer?.Cancel();
        profileTimer = null;
        if (Profile is { } open && Server is { } saved)
        {
            try
            {
                await Api.EndProfileAsync(saved, open, CancellationToken.None);
            }
            catch (AureliaApiException)
            {
                // The session expires on the server anyway.
            }
        }
        Profile = null;
    }

    private async Task ExpireProfileAsync(TimeSpan after, CancellationToken cancellation)
    {
        try
        {
            await Task.Delay(after, time, cancellation);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        CloseLibrary();
        Profile = null;
        flow.Show(AppScreen.ProfilePicker);
    }

    private async Task SaveAsync(StoredServer updated)
    {
        Server = updated;
        try
        {
            await credentials.SaveAsync(updated, CancellationToken.None);
        }
        catch (CredentialStoreUnavailableException error)
        {
            Message = error.Message;
        }
    }

    /// <summary>
    /// Downloads that may play while the server does not answer: only those of a profile that is
    /// still open here, because its PIN and age restrictions were checked when it was opened.
    /// Without an open profile nothing is offered.
    /// </summary>
    public IReadOnlyList<Playback.OfflineTitle> OfflineTitlesForOpenProfile(Playback.OfflineDownloads? downloads) =>
        downloads is not null && Server is { } saved && Profile is { } open && open.ExpiresAt > time.GetUtcNow()
            ? downloads.For(saved.ServerId, open.User.Id)
            : [];

    /// <summary>A library client for the open profile, for playing a download while the library is closed.</summary>
    public LibraryClient? OfflineClient() =>
        Library?.Client ?? (Server is { } saved && Profile is { } open && open.ExpiresAt > time.GetUtcNow()
            ? new LibraryClient(Api, saved, open, Capabilities)
            : null);

    /// <summary>True when the open profile may use owner or administrator screens.</summary>
    public bool CanManageMedia => Profile?.User.Role is UserRole.Owner or UserRole.Admin;
}
