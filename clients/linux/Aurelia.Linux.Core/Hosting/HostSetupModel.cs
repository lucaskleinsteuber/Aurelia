using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;

namespace Aurelia.Linux.Core.Hosting;

public enum HostPhase
{
    Starting,
    Failed,
    PortInUse,
    OwnerSetup,
    SignIn,
    ResetPin,
}

/// <summary>
/// "Set Up This PC", as the Mac app's NativeHostSetupView: start the server that comes with Aurelia,
/// create its owner with a Server Password, or sign in again ("Welcome Back") to a server set up
/// earlier. The profile picker then asks for the owner's PIN, and a new server offers its first
/// storage locations. A forgotten owner PIN is reset here with the Server Password.
/// </summary>
public sealed class HostSetupModel : ObservableObject
{
    public const int MinimumPasswordLength = 12;

    private readonly ILocalServerHost host;
    private readonly AppSession session;
    private readonly AppFlow flow;
    private readonly ICredentialStore credentials;
    private readonly Action<Action> dispatch;
    private HostPhase phase = HostPhase.Starting;
    private bool isBusy;
    private string? error;
    private string serverName;
    private string ownerName;
    private int httpsPort;
    private string statusTitle = "Starting Your Server";
    private string? statusMessage;

    public HostSetupModel(ILocalServerHost host, AppSession session, AppFlow flow, ICredentialStore credentials, Action<Action> dispatch)
    {
        this.host = host;
        this.session = session;
        this.flow = flow;
        this.credentials = credentials;
        this.dispatch = dispatch;
        serverName = host.Settings.ServerName;
        httpsPort = host.Settings.LanHttpsPort;
        var account = Environment.UserName.Trim();
        ownerName = account.Length >= 3 ? account : "owner";
        host.Changed += () => dispatch(HostChanged);
        session.LocalSignInNeeded += () =>
        {
            Phase = HostPhase.SignIn;
            flow.Show(AppScreen.HostSetup);
        };
    }

    public ILocalServerHost Host => host;

    public HostPhase Phase
    {
        get => phase;
        private set => SetProperty(ref phase, value);
    }

    public bool IsBusy
    {
        get => isBusy;
        private set => SetProperty(ref isBusy, value);
    }

    public string? Error
    {
        get => error;
        private set => SetProperty(ref error, value);
    }

    public string ServerName
    {
        get => serverName;
        set => SetProperty(ref serverName, value);
    }

    public string OwnerName
    {
        get => ownerName;
        set => SetProperty(ref ownerName, value);
    }

    public int HttpsPort
    {
        get => httpsPort;
        set => SetProperty(ref httpsPort, value);
    }

    public string StatusTitle
    {
        get => statusTitle;
        private set => SetProperty(ref statusTitle, value);
    }

    public string? StatusMessage
    {
        get => statusMessage;
        private set => SetProperty(ref statusMessage, value);
    }

    /// <summary>Starts this computer's server; the screens follow its state.</summary>
    public async Task StartAsync()
    {
        Error = null;
        StatusTitle = "Starting Your Server";
        StatusMessage = null;
        Phase = HostPhase.Starting;
        flow.Show(AppScreen.HostSetup);
        await host.StartAsync();
        dispatch(HostChanged);
    }

    /// <summary>"Try Again" after a failure, which also resets the automatic recovery.</summary>
    public async Task RetryAsync()
    {
        Error = null;
        StatusTitle = "Starting Your Server";
        Phase = HostPhase.Starting;
        await host.RestartAsync();
        dispatch(HostChanged);
    }

    public Task SetUpAsync(string password)
    {
        if (password.Length < MinimumPasswordLength) return Fail("Use at least 12 characters for the Server Password.");
        if (ServerName.Trim().Length is 0 or > 128) return Fail("Enter a server name.");
        if (OwnerName.Trim().Length < 3) return Fail("Enter an owner name with at least three characters.");
        return RunAsync(async () =>
        {
            StatusTitle = "Setting Up Your Server";
            var owner = await host.SetUpOwnerAsync(ServerName, OwnerName, password, HttpsPort, session.DeviceName, CancellationToken.None);
            // A new server offers its first storage locations once the owner's profile is open.
            session.NeedsInitialLibrarySetup = true;
            await ConnectAsync(owner);
        });
    }

    /// <summary>"Welcome Back": signs in to the server already stored on this computer.</summary>
    public Task SignInAsync(string password) => RunAsync(async () =>
    {
        var owner = await host.SignInAsync(OwnerName, password, session.DeviceName, CancellationToken.None);
        await ConnectAsync(owner);
    }, failure => failure is AureliaApiException { Status: 400 or 401 } ? "The owner name or Server Password is not correct." : failure.Message);

    public void BeginPinReset()
    {
        Error = null;
        Phase = HostPhase.ResetPin;
    }

    public void CancelPinReset()
    {
        Error = null;
        flow.Show(AppScreen.ProfilePicker);
    }

    /// <summary>A forgotten owner PIN: the Server Password sets a new one through the private host channel.</summary>
    public Task ResetPinAsync(string password, string pin, string confirmation)
    {
        if (!ProfilePin.IsValid(pin)) return Fail("Choose a PIN with four to eight digits.");
        if (pin != confirmation) return Fail("The PINs do not match.");
        return RunAsync(async () =>
        {
            await host.ResetOwnerPinAsync(password, pin, CancellationToken.None);
            flow.Show(AppScreen.ProfilePicker);
        }, failure => failure is AureliaApiException { Status: 401 or 403 } ? "The Server Password is not correct." : failure.Message);
    }

    /// <summary>Stops this computer's server and connects to another one instead.</summary>
    public async Task UseAnotherServerAsync()
    {
        await host.StopAsync();
        if (session.Server is { LocallyManaged: true }) await session.ForgetLocalServerAsync();
        flow.ChooseMode(OperatingMode.Client);
    }

    /// <summary>Follows the server: setup when it is new, the profiles once it runs, help when it fails.</summary>
    private void HostChanged()
    {
        if (flow.Mode != OperatingMode.Host) return;
        if (session.NetworkConfirmationPending) return;
        var interrupted = flow.Screen is not (AppScreen.HostSetup or AppScreen.Starting);
        switch (host.State)
        {
            case LocalServerState.Starting or LocalServerState.Restarting:
                if (interrupted) session.ServerInterrupted();
                StatusTitle = host.State == LocalServerState.Restarting ? "Restarting Your Server" : "Starting Your Server";
                StatusMessage = host.Message;
                Phase = HostPhase.Starting;
                flow.Show(AppScreen.HostSetup);
                break;
            case LocalServerState.Failed:
                if (IsBusy) return;
                if (interrupted) session.ServerInterrupted();
                StatusMessage = host.Message ?? "The server could not start.";
                Phase = HostPhase.Failed;
                flow.Show(AppScreen.HostSetup);
                break;
            case LocalServerState.PortInUse:
                StatusMessage = host.Message;
                Phase = HostPhase.PortInUse;
                flow.Show(AppScreen.HostSetup);
                break;
            case LocalServerState.SetupRequired when !IsBusy:
                ServerName = host.Settings.ServerName;
                HttpsPort = host.Settings.LanHttpsPort;
                Phase = HostPhase.OwnerSetup;
                flow.Show(AppScreen.HostSetup);
                break;
            case LocalServerState.Running when !IsBusy && !interrupted && Phase is HostPhase.Starting or HostPhase.Failed:
                _ = OpenSavedAsync();
                break;
        }
    }

    /// <summary>A server set up earlier: its saved connection leads to the profiles, otherwise "Welcome Back".</summary>
    private Task OpenSavedAsync() => RunAsync(async () =>
    {
        StoredServer? saved = session.Server;
        if (saved is null)
        {
            try
            {
                saved = await credentials.LoadAsync(CancellationToken.None);
            }
            catch (CredentialStoreUnavailableException failure)
            {
                Error = failure.Message;
            }
        }
        if (saved is not { LocallyManaged: true } || saved.ServerId != host.Info?.ServerId)
        {
            Phase = HostPhase.SignIn;
            return;
        }
        await session.CompletePairingAsync(saved with { Address = host.SecureAddress }, host.Info?.Capabilities);
    });

    /// <summary>Reads the server's key over HTTPS on this computer and keeps the owner's device credential with it.</summary>
    private async Task ConnectAsync(AuthenticationResponse owner)
    {
        InspectedServer? inspected = null;
        for (var attempt = 0; attempt < 50 && inspected is null; attempt++)
        {
            try
            {
                inspected = await session.Api.InspectAsync(host.SecureAddress, CancellationToken.None, TimeSpan.FromSeconds(3));
            }
            catch (AureliaApiException) when (attempt < 49)
            {
                await Task.Delay(200);
            }
        }
        var stored = new StoredServer(inspected!.Info.ServerId, inspected.Info.Name, inspected.Address, inspected.Fingerprint,
            owner.Token, owner.SessionId, owner.ExpiresAt, owner.User, LocallyManaged: true);
        await session.CompletePairingAsync(stored, inspected.Info.Capabilities);
    }

    private Task Fail(string message)
    {
        Error = message;
        return Task.CompletedTask;
    }

    private async Task RunAsync(Func<Task> operation, Func<Exception, string>? describe = null)
    {
        if (IsBusy) return;
        IsBusy = true;
        Error = null;
        try
        {
            await operation();
        }
        catch (Exception failure) when (failure is AureliaApiException or CredentialStoreUnavailableException)
        {
            Error = describe?.Invoke(failure) ?? failure.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }
}
