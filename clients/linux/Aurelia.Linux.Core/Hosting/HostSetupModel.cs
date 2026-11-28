using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Moving;

namespace Aurelia.Linux.Core.Hosting;

public enum HostPhase
{
    Starting,
    Failed,
    PortInUse,
    OwnerSetup,
    SignIn,
    ResetPin,

    /// <summary>"Move from another Aurelia server": over the network or with a moving file.</summary>
    MoveStart,

    /// <summary>The data of the old server arrives.</summary>
    MoveProgress,

    /// <summary>Each storage location of the old server gets its folder on this computer.</summary>
    MoveLocations,

    /// <summary>The moved data is applied and the server restarts with the old server's identity.</summary>
    MoveApplying,
}

/// <summary>
/// "Set Up This PC", as the Mac app's NativeHostSetupView: start the server that comes with Aurelia,
/// create its owner with a Server Password, or sign in again ("Welcome Back") to a server set up
/// earlier. The profile picker then asks for the owner's PIN, and a new server offers its first
/// storage locations. A forgotten owner PIN is reset here with the Server Password. Instead of a new
/// owner, a new server can take over another Aurelia server ("Move from another Aurelia server",
/// docs/SERVER_MOVE.md): its data arrives over the network or from a moving file, each storage
/// location gets its folder on this computer, and the server restarts with the old one's identity.
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
    private readonly Func<IReadOnlyList<DiscoveredServer>> nearby;
    private readonly Dictionary<Guid, MoveChoice> moveChoices = [];
    private readonly Dictionary<Guid, string> movePreviews = [];
    private IReadOnlyList<SetupMoveLocation> moveLocations = [];
    private string? moveSource;
    private double? moveFraction;
    private string moveProgress = "";
    private bool movedIn;
    private int moveGeneration;

    /// <param name="nearby">Aurelia servers announced on the network, to pick the old server from.</param>
    public HostSetupModel(ILocalServerHost host, AppSession session, AppFlow flow, ICredentialStore credentials, Action<Action> dispatch,
        Func<IReadOnlyList<DiscoveredServer>>? nearby = null)
    {
        this.host = host;
        this.session = session;
        this.flow = flow;
        this.credentials = credentials;
        this.dispatch = dispatch;
        this.nearby = nearby ?? (() => []);
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

    /// <summary>Whether this computer's server can take over another Aurelia server.</summary>
    public bool CanMove => host.SetupMove is not null;

    /// <summary>Aurelia servers announced nearby, to pick the old server from; this computer's own is left out.</summary>
    public IReadOnlyList<DiscoveredServer> NearbyServers =>
        [.. nearby().Where(server => server.ServerId != host.Info?.ServerId && !ServerAddress.IsLoopback(server.Address))];

    /// <summary>The old server's name while its data arrives.</summary>
    public string? MoveSource
    {
        get => moveSource;
        private set => SetProperty(ref moveSource, value);
    }

    /// <summary>How much of the old server's data arrived, or null while its size is unknown.</summary>
    public double? MoveFraction
    {
        get => moveFraction;
        private set => SetProperty(ref moveFraction, value);
    }

    public string MoveProgress
    {
        get => moveProgress;
        private set => SetProperty(ref moveProgress, value);
    }

    /// <summary>The old server's storage locations, to map to folders on this computer.</summary>
    public IReadOnlyList<SetupMoveLocation> MoveLocations
    {
        get => moveLocations;
        private set => SetProperty(ref moveLocations, value);
    }

    public IReadOnlyDictionary<Guid, MoveChoice> MoveChoices => moveChoices;

    /// <summary>"412 of 415 sample files found" for a folder previewed for a location.</summary>
    public IReadOnlyDictionary<Guid, string> MovePreviews => movePreviews;

    /// <summary>The move finished: "Welcome Back" asks for the moved server's owner and Server Password.</summary>
    public bool MovedIn
    {
        get => movedIn;
        private set => SetProperty(ref movedIn, value);
    }

    /// <summary>How often the setup move is asked for its state.</summary>
    internal TimeSpan MovePollInterval { get; set; } = TimeSpan.FromSeconds(1);

    /// <summary>How many "done" answers without a restart of the host before this app restarts the server itself.</summary>
    internal const int DoneBeforeRestart = 10;

    /// <summary>"Move from Another Aurelia Server": picks up a move already under way, or asks how the data comes.</summary>
    public Task BeginMoveAsync()
    {
        if (host.SetupMove is not { } channel) return Fail("This server can't take over another Aurelia server. Update Aurelia first.");
        return RunAsync(async () =>
        {
            var current = await channel.StatusAsync(CancellationToken.None);
            if (current.State is "fetching" or "received" or "applying")
            {
                _ = FollowMoveAsync(current);
                return;
            }
            Phase = HostPhase.MoveStart;
        }, ServerMoveText.Problem);
    }

    /// <summary>Over the network: the old server's address (picked nearby or typed) and the move code it shows.</summary>
    public Task StartNetworkMoveAsync(string address, string code)
    {
        if (host.SetupMove is not { } channel) return Fail("This server can't take over another Aurelia server. Update Aurelia first.");
        if (!ServerAddress.TryNormalize(address, out var old)) return Fail("Enter the old server's address, such as 192.168.1.20.");
        if (!ServerMoveText.IsCompleteCode(code)) return Fail("Enter the 12-character move code the old server shows.");
        return RunAsync(async () =>
        {
            StatusTitle = "Contacting the Old Server";
            await channel.StartNetworkAsync(old, ServerMoveText.FormatCode(code), CancellationToken.None);
            _ = FollowMoveAsync(null);
        }, ServerMoveText.Problem);
    }

    /// <summary>With a moving file: uploads it to this computer's server and opens it with its passphrase.</summary>
    public Task StartFileMoveAsync(Stream file, string passphrase)
    {
        if (host.SetupMove is not { } channel) return Fail("This server can't take over another Aurelia server. Update Aurelia first.");
        if (passphrase.Length == 0) return Fail("Enter the moving file's passphrase.");
        return RunAsync(async () =>
        {
            StatusTitle = "Opening the Moving File";
            try
            {
                await channel.OpenFileAsync(file, passphrase, CancellationToken.None);
            }
            catch (IOException)
            {
                throw new AureliaApiException(0, "file_unreadable", "The moving file couldn't be read. Choose it again.");
            }
            _ = FollowMoveAsync(null);
        }, ServerMoveText.Problem);
    }

    /// <summary>Chooses a location's folder: a suggestion, another folder, or Later.</summary>
    public void ChooseMoveFolder(Guid locationId, MoveChoice choice)
    {
        moveChoices[locationId] = choice;
        if (choice.Kind != MoveChoiceKind.Folder) movePreviews.Remove(locationId);
        OnPropertyChanged(nameof(MoveChoices));
    }

    /// <summary>Compares another folder with a location's sample files and chooses it.</summary>
    public async Task PreviewMoveFolderAsync(Guid locationId, string path)
    {
        if (host.SetupMove is not { } channel) return;
        var folder = path.Trim();
        if (folder.Length == 0)
        {
            Error = "Choose a folder first.";
            return;
        }
        ChooseMoveFolder(locationId, new MoveChoice(MoveChoiceKind.Folder, folder));
        movePreviews[locationId] = "Comparing…";
        OnPropertyChanged(nameof(MovePreviews));
        var sampled = MoveLocations.FirstOrDefault(location => location.Id == locationId)?.Sampled ?? 0;
        try
        {
            var match = await channel.PreviewAsync(locationId, folder, CancellationToken.None);
            movePreviews[locationId] = ServerMoveText.MatchText(match.Matched, match.Sampled > 0 ? match.Sampled : sampled);
        }
        catch (AureliaApiException failure)
        {
            movePreviews[locationId] = ServerMoveText.Problem(failure);
        }
        OnPropertyChanged(nameof(MovePreviews));
    }

    /// <summary>The mapping that "Finish Move" sends, or the problem to fix first.</summary>
    public (FinishMoveRequest? Request, string? Problem) MoveMappings() => ServerMoveText.Mappings(MoveLocations, moveChoices);

    /// <summary>Applies the moved data with the chosen folders, then waits for the server to restart with the old identity.</summary>
    public Task FinishMoveAsync()
    {
        if (host.SetupMove is not { } channel) return Task.CompletedTask;
        var (request, problem) = MoveMappings();
        if (request is null) return Fail(problem!);
        return RunAsync(async () =>
        {
            await channel.FinishAsync(request, CancellationToken.None);
            MovedIn = true;
            StatusTitle = "Moving In";
            StatusMessage = "Aurelia applies the moved data. The server restarts in a moment.";
            Phase = HostPhase.MoveApplying;
            _ = WaitForMovedServerAsync(channel, ++moveGeneration);
        }, ServerMoveText.Problem);
    }

    /// <summary>Discards the staged data and returns to "Set Up This PC".</summary>
    public async Task CancelMoveAsync()
    {
        moveGeneration++;
        if (host.SetupMove is { } channel)
        {
            try
            {
                await channel.DiscardAsync(CancellationToken.None);
            }
            catch (AureliaApiException)
            {
                // Nothing was staged, or the server is restarting; the setup starts fresh either way.
            }
        }
        Error = null;
        moveChoices.Clear();
        movePreviews.Clear();
        MoveLocations = [];
        Phase = HostPhase.OwnerSetup;
    }

    /// <summary>Follows the staged move until it needs the person (its folders), fails, or is applied.</summary>
    private async Task FollowMoveAsync(SetupMoveStatus? first)
    {
        if (host.SetupMove is not { } channel) return;
        var generation = ++moveGeneration;
        StatusTitle = "Moving In";
        MoveFraction = null;
        MoveProgress = "Waiting for the old server…";
        Phase = HostPhase.MoveProgress;
        var status = first;
        // Right after it was asked to start, the server may still report nothing staged for a moment.
        var idle = 0;
        while (generation == moveGeneration && Phase == HostPhase.MoveProgress)
        {
            if (status is null)
            {
                await Task.Delay(MovePollInterval);
                if (generation != moveGeneration || Phase != HostPhase.MoveProgress) return;
                try
                {
                    status = await channel.StatusAsync(CancellationToken.None);
                }
                catch (AureliaApiException failure) when (failure.Code == "server_unavailable")
                {
                    MoveProgress = "Waiting for the server…";
                    continue;
                }
                catch (AureliaApiException failure)
                {
                    Error = ServerMoveText.Problem(failure);
                    Phase = HostPhase.MoveStart;
                    return;
                }
            }
            switch (status.State)
            {
                case "fetching":
                    MoveSource = status.Source?.Name;
                    (MoveFraction, MoveProgress) = ServerMoveText.Progress(status.Progress);
                    StatusMessage = $"Receiving the data from {SourceName()}. Keep both servers on.";
                    break;
                case "received":
                    MoveSource = status.Source?.Name;
                    ShowLocations(status.Locations ?? []);
                    return;
                case "applying" or "done":
                    MovedIn = true;
                    StatusMessage = "Aurelia applies the moved data. The server restarts in a moment.";
                    Phase = HostPhase.MoveApplying;
                    _ = WaitForMovedServerAsync(channel, ++moveGeneration);
                    return;
                case "failed":
                    Error = status.Error is { Length: > 0 } reason ? reason : "The data couldn't be received. Nothing changed on either server.";
                    Phase = HostPhase.MoveStart;
                    return;
                default:
                    if (++idle > 3)
                    {
                        Error = "The move stopped. Start it again.";
                        Phase = HostPhase.MoveStart;
                        return;
                    }
                    break;
            }
            status = null;
        }
    }

    private void ShowLocations(IReadOnlyList<SetupMoveLocation> locations)
    {
        moveChoices.Clear();
        movePreviews.Clear();
        foreach (var location in locations) moveChoices[location.Id] = ServerMoveText.InitialChoice(location);
        MoveLocations = locations;
        StatusTitle = "Where Are Your Media Files Now?";
        StatusMessage = $"The data from {SourceName()} arrived. For each storage location, choose the folder on this PC that holds the same files.";
        Phase = HostPhase.MoveLocations;
    }

    private string SourceName() => MoveSource is { Length: > 0 } name ? $"“{name}”" : "the old server";

    /// <summary>
    /// Waits while the moved data is applied. The server hands this app the prepared restore on its
    /// control channel, as for a restore, and the host restores and starts it again. Should the
    /// server report "done" for ten seconds while still waiting for setup, this app restarts it
    /// itself. The screens then follow the host: "Welcome Back" signs in with the moved server's owner.
    /// </summary>
    private async Task WaitForMovedServerAsync(ISetupMoveChannel channel, int generation)
    {
        var done = 0;
        for (var round = 0; round < 600 && generation == moveGeneration && Phase == HostPhase.MoveApplying; round++)
        {
            await Task.Delay(MovePollInterval);
            if (generation != moveGeneration || Phase != HostPhase.MoveApplying) return;
            if (host.State != LocalServerState.SetupRequired) continue;
            try
            {
                var status = await channel.StatusAsync(CancellationToken.None);
                if (status.State == "failed")
                {
                    Error = status.Error is { Length: > 0 } reason ? reason : "The moved data couldn't be applied. Nothing changed; start again.";
                    Phase = HostPhase.MoveStart;
                    return;
                }
                done = status.State == "done" ? done + 1 : 0;
            }
            catch (AureliaApiException)
            {
                // Restarting: the next round looks again.
                done = 0;
            }
            if (done < DoneBeforeRestart) continue;
            await host.RestartAsync();
            return;
        }
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
            session.FreshServerPassword = password;
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
            // A move in progress keeps its screen; the server answers it again once it is back.
            case LocalServerState.SetupRequired when !IsBusy && Phase is not (HostPhase.MoveStart or HostPhase.MoveProgress or HostPhase.MoveLocations):
                if (MovedIn)
                {
                    // The server came back without an owner: the moved data did not take.
                    MovedIn = false;
                    Error = "The moved data couldn't be applied. Set up this PC, or move again.";
                }
                ServerName = host.Settings.ServerName;
                HttpsPort = host.Settings.LanHttpsPort;
                Phase = HostPhase.OwnerSetup;
                flow.Show(AppScreen.HostSetup);
                break;
            // Also the moved server once it runs with the old server's identity: "Welcome Back" signs in.
            case LocalServerState.Running when !IsBusy && !interrupted && Phase is HostPhase.Starting or HostPhase.Failed or HostPhase.MoveApplying:
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
        await session.CompletePairingAsync(saved with { Address = host.SecureAddress, PowerSavingEnabled = host.Info?.PowerSavingEnabled ?? false }, host.Info?.Capabilities);
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
            owner.Token, owner.SessionId, owner.ExpiresAt, owner.User, LocallyManaged: true, PowerSavingEnabled: inspected.Info.PowerSavingEnabled);
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
