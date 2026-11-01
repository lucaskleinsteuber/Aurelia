using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Library;
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
    private LibraryStore? library;
    private IReadOnlyList<string> capabilities = [];
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

    /// <summary>A problem to show on the current screen, or null.</summary>
    public string? Message
    {
        get => message;
        set => SetProperty(ref message, value);
    }

    /// <summary>Reads the saved pairing and reaches its server; without one, shows the welcome choice.</summary>
    public async Task StartAsync()
    {
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
        if (Server is not { } saved) return;
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
                flow.Show(AppScreen.ServerUnreachable);
                return;
            }
            Capabilities = reached.Info.Capabilities ?? [];
            if (reached.Server != saved) await SaveAsync(reached.Server);
            Status = ConnectionStatus.Loading;
            flow.Show(AppScreen.ProfilePicker);
        }
        catch (OperationCanceledException) when (attempt.IsCancellationRequested)
        {
            flow.Show(AppScreen.ServerUnreachable);
        }
        catch (AureliaApiException error)
        {
            Message = error.Message;
            flow.Show(AppScreen.ServerUnreachable);
        }
        finally
        {
            if (reaching == attempt) reaching = null;
            Status = ConnectionStatus.Idle;
        }
    }

    /// <summary>"Stop Waiting": gives up on waking the server for now.</summary>
    public void StopWaiting() => reaching?.Cancel();

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
        flow.Show(AppScreen.Library);
    }

    /// <summary>Ends the open profile on the server and returns to "Who's watching?".</summary>
    public async Task SwitchProfileAsync()
    {
        await EndProfileAsync();
        flow.Show(AppScreen.ProfilePicker);
    }

    /// <summary>
    /// The server no longer accepts a credential. A profile problem returns to the picker; a revoked
    /// device must be paired again, but the saved connection stays until the person removes it.
    /// </summary>
    public void HandleSessionFailure(AureliaApiException error)
    {
        if (error.Code is "device_session_revoked" || (error.IsAuthenticationFailure && Profile is null))
        {
            CloseLibrary();
            Profile = null;
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
        flow.Show(AppScreen.Connection);
    }

    private async Task StartLibraryAsync(LibraryStore store, CancellationToken cancellation)
    {
        await store.RefreshAsync();
        if (!cancellation.IsCancellationRequested) await new LibrarySync(store, Preferences.Store, time).RunAsync(cancellation);
    }

    private void CloseLibrary()
    {
        syncing?.Cancel();
        syncing = null;
        Library = null;
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

    /// <summary>True when the open profile may use owner or administrator screens.</summary>
    public bool CanManageMedia => Profile?.User.Role is UserRole.Owner or UserRole.Admin;
}
