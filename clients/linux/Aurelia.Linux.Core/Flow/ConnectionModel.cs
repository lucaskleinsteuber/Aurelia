using System.Collections.ObjectModel;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;

namespace Aurelia.Linux.Core.Flow;

/// <summary>
/// The connection screen, as on the Mac: servers nearby or a typed address; then the server's
/// key fingerprint to compare with the one shown on the server, and the eight-digit pairing code.
/// </summary>
public sealed class ConnectionModel : ObservableObject, IDisposable
{
    private readonly AppSession session;
    private readonly IServerDiscovery discovery;
    private readonly Action<Action> post;
    private InspectedServer? inspected;
    private string address = "";
    private string code = "";
    private bool fingerprintsMatch;
    private bool isBusy;
    private string? error;
    private bool showsAdvanced;

    public ConnectionModel(AppSession session, IServerDiscovery discovery, Action<Action> post)
    {
        this.session = session;
        this.discovery = discovery;
        this.post = post;
        error = session.Message;
        discovery.Changed += OnDiscovered;
        discovery.Start();
    }

    public ObservableCollection<DiscoveredServer> Nearby { get; } = [];

    /// <summary>The server being verified; null while choosing a server.</summary>
    public InspectedServer? Inspected
    {
        get => inspected;
        private set
        {
            if (!SetProperty(ref inspected, value)) return;
            OnPropertyChanged(nameof(IsVerifying));
            OnPropertyChanged(nameof(DisplayFingerprint));
            OnPropertyChanged(nameof(CanPair));
        }
    }

    public bool IsVerifying => Inspected is not null;

    /// <summary>
    /// Always computed from the key this computer saw in the TLS handshake, never the text the
    /// server sends: a server in the middle could otherwise show the real server's fingerprint.
    /// </summary>
    public string DisplayFingerprint => Inspected is { } server ? ServerIdentity.Display(server.Fingerprint) : "";

    public string Address
    {
        get => address;
        set => SetProperty(ref address, value);
    }

    public string Code
    {
        get => code;
        set
        {
            var digits = new string((value ?? "").Where(char.IsAsciiDigit).Take(8).ToArray());
            if (SetProperty(ref code, digits)) OnPropertyChanged(nameof(CanPair));
        }
    }

    public bool FingerprintsMatch
    {
        get => fingerprintsMatch;
        set
        {
            if (SetProperty(ref fingerprintsMatch, value)) OnPropertyChanged(nameof(CanPair));
        }
    }

    public bool ShowsAdvanced
    {
        get => showsAdvanced;
        set => SetProperty(ref showsAdvanced, value);
    }

    public bool IsBusy
    {
        get => isBusy;
        private set
        {
            if (SetProperty(ref isBusy, value)) OnPropertyChanged(nameof(CanPair));
        }
    }

    public string? Error
    {
        get => error;
        private set => SetProperty(ref error, value);
    }

    public bool CanPair => Inspected is not null && FingerprintsMatch && Code.Length == 8 && !IsBusy;

    public Task ChooseAsync(DiscoveredServer server) => InspectAsync(server.Address);

    /// <summary>"Connect" for a typed address.</summary>
    public Task ConnectAsync()
    {
        if (!ServerAddress.TryNormalize(Address, out var normalized))
        {
            Error = "Enter a server address such as 192.168.1.20.";
            return Task.CompletedTask;
        }
        return InspectAsync(normalized);
    }

    public async Task PairAsync()
    {
        if (!CanPair || Inspected is not { } server) return;
        IsBusy = true;
        Error = null;
        try
        {
            var paired = await session.Api.PairAsync(server, Code, session.DeviceName, CancellationToken.None);
            await session.CompletePairingAsync(paired, server.Info.Capabilities);
        }
        catch (AureliaApiException failure)
        {
            Error = failure.Code switch
            {
                "invalid_pairing_code" or "pairing_code_invalid" or "invalid_code" => "This pairing code is not valid or has expired. Create a new one on the server.",
                _ => failure.Message,
            };
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>Back from verifying to the list of servers.</summary>
    public void Back()
    {
        Inspected = null;
        Code = "";
        FingerprintsMatch = false;
        Error = null;
    }

    public void Dispose()
    {
        discovery.Changed -= OnDiscovered;
        discovery.Halt();
    }

    private async Task InspectAsync(Uri target)
    {
        IsBusy = true;
        Error = null;
        try
        {
            Inspected = await session.Api.InspectAsync(target, CancellationToken.None);
            FingerprintsMatch = false;
            Code = "";
        }
        catch (AureliaApiException failure)
        {
            Error = failure.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void OnDiscovered(IReadOnlyList<DiscoveredServer> servers) => post(() =>
    {
        Nearby.Clear();
        foreach (var server in servers) Nearby.Add(server);
    });
}
